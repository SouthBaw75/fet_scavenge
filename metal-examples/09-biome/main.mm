// 09 — BIOME (life simulator, vertical slice)
//
// Care for a colony of critters whose every trait is read from a real,
// inherited nucleotide genome. Watch them forage, rest, court, breed, sicken,
// and — across generations — EVOLVE.
//
//   * Diploid genome of A/C/G/T genes on chromosomes; traits translated from
//     the sequence; dominance read from the sequence; meiosis with crossing
//     over + point mutation; X/Y sex. See DESIGN.md.
//   * Procedural Verlet-spine bodies with a speed-scaled slither.
//   * Utility-AI needs: hunger / energy / reproduction urge.
//   * Food plants grow and regrow (carrying capacity); starvation, old age,
//     and a contagious sickness thin the herd; disease-resistance genes let
//     epidemics select the population.
//   * Click a critter to inspect its traits and genome.
//
// Controls:
//   Click        select / inspect a critter
//   F            scatter food   ·   Space pause   ·   [ ] slower/faster
//   K            cull selected  ·   I introduce a random critter  ·  R reset
//
// CPU fixed-timestep sim; instanced-quad rendering (SDF shapes + digit font).

#include "../common/app.h"
#include <simd/simd.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <random>
#include <string>
#include <vector>

// ---------------------------------------------------------------- Tuning ---

static const float kWorldW = 120.0f;
static const float kWorldH = 72.0f;
static const int kMaxCritters = 500;
static const int kMaxFood = 600;
static const int kMaxInstances = 32768;
static const int kMaxInFlight = 3;
static const int kSpineNodes = 6;

// Genome layout: kNumGenes autosomal loci spread across kChromosomes.
static const int kNumGenes = 8;
static const int kChromosomes = 2;
static const int kGenesPerChrom = kNumGenes / kChromosomes;   // 4
static const float kMutationRate = 0.04f;   // chance per gene per gamete

// Gene indices -> traits.
enum { GSize0 = 0, GSize1 = 1, GSpeed = 2, GMetab = 3,
       GColR = 4, GColG = 5, GColB = 6, GResist = 7 };

// --------------------------------------------------------------- Genetics ---
// A gene is 16 bases packed 2 bits each in a uint32 (A=0,C=1,G=2,T=3).

static inline int baseAt(uint32_t g, int i) { return (g >> (2 * i)) & 3; }

// Expression: GC content (0..1). C=1, G=2 are the "strong" bases.
static float geneExpression(uint32_t g) {
    int gc = 0;
    for (int i = 0; i < 16; i++) { int b = baseAt(g, i); if (b == 1 || b == 2) gc++; }
    return gc / 16.0f;
}
// Dominance: read from the high half of the strand (a different region than
// expression leans on), so dominance and value vary independently.
static float geneDominance(uint32_t g) {
    int d = 0;
    for (int i = 8; i < 16; i++) { int b = baseAt(g, i); if (b >= 2) d++; }
    return 0.15f + 0.85f * (d / 8.0f);
}
// A locus phenotype from its two alleles: dominance-weighted blend. One
// formula yields dominant/recessive AND incomplete/codominant behavior.
static float locusValue(uint32_t a, uint32_t b) {
    float ea = geneExpression(a), da = geneDominance(a);
    float eb = geneExpression(b), db = geneDominance(b);
    return (ea * da + eb * db) / (da + db + 1e-4f);
}

struct Genome {
    uint32_t hom[2][kNumGenes];   // two homologs
    int sexAllele[2];             // 0 = X, 1 = Y  (XX female, XY male)
};

static uint32_t randomGene(std::mt19937 &rng) {
    // 32 random bits = 16 random bases.
    return ((uint32_t)rng() ) ^ ((uint32_t)rng() << 1);
}

static Genome randomGenome(std::mt19937 &rng, int forcedSex /* -1 any */) {
    Genome g;
    for (int h = 0; h < 2; h++)
        for (int i = 0; i < kNumGenes; i++) g.hom[h][i] = randomGene(rng);
    std::uniform_real_distribution<float> u(0, 1);
    int sex = (forcedSex >= 0) ? forcedSex : (u(rng) < 0.5f ? 0 : 1);
    g.sexAllele[0] = 0;                    // one X always
    g.sexAllele[1] = (sex == 0) ? 0 : 1;   // female XX, male XY
    return g;
}

static bool isMale(const Genome &g) { return g.sexAllele[0] == 1 || g.sexAllele[1] == 1; }

// Build one gamete (a single strand of kNumGenes) via meiosis: per chromosome,
// copy one homolog up to a random crossover, the other after; then mutate.
static void makeGamete(const Genome &g, std::mt19937 &rng, uint32_t out[kNumGenes]) {
    std::uniform_int_distribution<int> coin(0, 1);
    for (int c = 0; c < kChromosomes; c++) {
        int base = c * kGenesPerChrom;
        int strand = coin(rng);
        std::uniform_int_distribution<int> cut(0, kGenesPerChrom);
        int cross = cut(rng);
        for (int i = 0; i < kGenesPerChrom; i++) {
            int src = (i < cross) ? strand : (1 - strand);
            out[base + i] = g.hom[src][base + i];
        }
    }
    // Point mutations: flip one random base of a gene.
    std::uniform_real_distribution<float> u(0, 1);
    std::uniform_int_distribution<int> pos(0, 15);
    std::uniform_int_distribution<int> nb(0, 3);
    for (int i = 0; i < kNumGenes; i++) {
        if (u(rng) < kMutationRate) {
            int p = pos(rng);
            uint32_t mask = ~(3u << (2 * p));
            out[i] = (out[i] & mask) | ((uint32_t)nb(rng) << (2 * p));
        }
    }
}

// Fertilization: gamete from mother + gamete from father; father's sex strand
// decides the child's sex.
static Genome breed(const Genome &mom, const Genome &dad, std::mt19937 &rng) {
    Genome kid;
    makeGamete(mom, rng, kid.hom[0]);
    makeGamete(dad, rng, kid.hom[1]);
    std::uniform_int_distribution<int> coin(0, 1);
    kid.sexAllele[0] = 0;                                  // X from mother
    kid.sexAllele[1] = coin(rng) ? dad.sexAllele[1] : dad.sexAllele[0]; // X or Y from father
    // Guard: mother contributes only X (already 0); ensure male marker only
    // comes from the father strand above.
    return kid;
}

// Phenotype: the visible, playable traits translated from the genome.
struct Phenotype {
    float size;        // body scale
    float speed;       // move speed
    float metabolism;  // energy burn + hunger rate
    float sensory;     // perception radius
    float fertility;   // urge growth / litter viability
    float resistance;  // disease resistance
    float lifespan;    // seconds
    simd_float3 color; // coat color
};

static Phenotype phenotypeOf(const Genome &g) {
    auto L = [&](int i) { return locusValue(g.hom[0][i], g.hom[1][i]); };
    Phenotype p;
    float sz = (L(GSize0) + L(GSize1)) * 0.5f;
    p.size = 0.6f + 1.1f * sz;
    // Pleiotropy: bigger critters are slower and burn more energy.
    p.speed = (6.0f + 10.0f * L(GSpeed)) * (1.25f - 0.5f * sz);
    p.metabolism = (0.5f + 1.2f * L(GMetab)) * (0.7f + 0.6f * sz);
    p.sensory = 8.0f + 20.0f * L(GSpeed) * 0.5f + 6.0f;
    p.fertility = 0.4f + 0.9f * (1.0f - L(GMetab) * 0.4f);
    p.resistance = L(GResist);
    p.lifespan = 55.0f + 70.0f * (1.0f - L(GMetab)) + 20.0f * (1.0f - sz);
    p.color = simd_make_float3(0.35f + 0.6f * L(GColR),
                               0.35f + 0.6f * L(GColG),
                               0.35f + 0.6f * L(GColB));
    return p;
}

// ------------------------------------------------------------------ World ---

enum { AWander = 0, AForage = 1, ARest = 2, AMate = 3 };

struct Critter {
    uint32_t id;
    Genome genome;
    Phenotype ph;
    bool male;
    simd_float2 pos, vel;
    float heading;
    simd_float2 spine[kSpineNodes];
    float age, maturity;
    float energy;      // 0..1
    float hunger;      // 0..1 (1 = starving)
    float urge;        // 0..1 reproduction
    float health;      // 0..1
    float sick;        // 0..1 infection load, 0 = healthy
    int action;
    int targetFood;
    uint32_t targetMate;
    bool pregnant;
    float gestation;
    Genome unborn;     // offspring genome fixed at conception
    float phase;       // slither phase
    int generation;
    bool alive;
};

struct Food {
    simd_float2 pos;
    float growth;      // 0..1
    bool alive;
};

// -------------------------------------------------------------- Instances ---

struct InstC {
    float cx, cy, hx, hy, rot, shape;
    float r, g, b, a;
    float p0, p1, p2, p3;
};

static const char *kShaderSource = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct Uni {
    float2 scale;
    float2 offset;
    float2 resolution;
    float time;
    float pad;
};

float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}
float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1,0)), f.x),
               mix(hash21(i + float2(0,1)), hash21(i + float2(1,1)), f.x), f.y);
}
float fbm(float2 p) { float v=0,a=0.5; for(int i=0;i<4;i++){v+=a*vnoise(p);p*=2.03;a*=0.5;} return v; }
float3 gammaOut(float3 c) { return pow(max(c,0.0), float3(0.4545)); }

// ---- ground ----
struct FSOut { float4 position [[position]]; float2 uv; };
vertex FSOut fs_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid<<1)&2, vid&2);
    FSOut o; o.position = float4(p*2.0-1.0, 0.0, 1.0); o.uv = float2(p.x, 1.0-p.y); return o;
}
fragment float4 ground_fragment(FSOut in [[stage_in]], constant Uni &u [[buffer(0)]]) {
    float2 ndc = float2(in.uv.x*2.0-1.0, 1.0-in.uv.y*2.0);
    float2 w = (ndc - u.offset) / u.scale;
    float n = fbm(w * 0.08);
    float3 col = mix(float3(0.14,0.26,0.12), float3(0.20,0.34,0.15), n);
    col *= 0.9 + 0.15 * fbm(w * 0.6 + 5.0);
    float2 bd = max(float2(0.0)-w, w-float2(120.0,72.0));
    col *= 1.0 / (1.0 + max(max(bd.x,bd.y),0.0)*0.15);
    return float4(gammaOut(col), 1.0);
}

// ---- instanced entities ----
struct EInst {
    packed_float2 center; packed_float2 half2; float rot; float shape;
    packed_float4 color; packed_float4 params;
};
struct EOut {
    float4 position [[position]]; float2 lp; float4 color; float4 params; float shape;
};
constant float2 kCorners[6] = {
    float2(-1,-1), float2(1,-1), float2(1,1), float2(-1,-1), float2(1,1), float2(-1,1),
};
vertex EOut entity_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device EInst *insts [[buffer(0)]],
                          constant Uni &u [[buffer(1)]]) {
    EInst it = insts[iid];
    float2 lp = kCorners[vid];
    float2 p = lp * float2(it.half2);
    float cs = cos(it.rot), sn = sin(it.rot);
    float2 world = float2(it.center) + float2(p.x*cs - p.y*sn, p.x*sn + p.y*cs);
    EOut o;
    o.position = float4(world * u.scale + u.offset, 0.0, 1.0);
    o.lp = lp; o.color = float4(it.color); o.params = float4(it.params); o.shape = it.shape;
    return o;
}

constant ushort kDigit[10][7] = {
    {0x0E,0x11,0x13,0x15,0x19,0x11,0x0E},{0x04,0x0C,0x04,0x04,0x04,0x04,0x0E},
    {0x0E,0x11,0x01,0x06,0x08,0x10,0x1F},{0x1F,0x02,0x04,0x02,0x01,0x11,0x0E},
    {0x02,0x06,0x0A,0x12,0x1F,0x02,0x02},{0x1F,0x10,0x1E,0x01,0x01,0x11,0x0E},
    {0x06,0x08,0x10,0x1E,0x11,0x11,0x0E},{0x1F,0x01,0x02,0x04,0x08,0x08,0x08},
    {0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E},{0x0E,0x11,0x11,0x0F,0x01,0x02,0x0C},
};

fragment float4 entity_fragment(EOut in [[stage_in]]) {
    float2 p = in.lp;
    int shape = int(in.shape + 0.5);
    float a = 0.0;
    if (shape == 0) {                       // soft body blob
        float r = length(p); a = smoothstep(1.0, 0.15, r);
    } else if (shape == 1) {                // selection ring
        float r = length(p); float aa = fwidth(r);
        a = smoothstep(2.5*aa, 0.0, abs(r-0.9));
    } else if (shape == 2) {                // plant: little tri-leaf
        float d = min(min(length(p-float2(0,0.4)), length(p-float2(0.42,-0.2))),
                      length(p-float2(-0.42,-0.2)));
        a = smoothstep(0.55, 0.15, d);
    } else if (shape == 3) {                // eye
        float r = length(p);
        float3 c = (r < 0.45) ? float3(0.05) : float3(0.98);
        float av = smoothstep(1.0, 0.7, r);
        return float4(gammaOut(c) * av, av);
    } else if (shape == 4) {                // solid rect (bars, panels, ticks)
        return float4(gammaOut(in.color.rgb) * in.color.a, in.color.a);
    } else if (shape == 5) {                // digit (params.x = value 0..9)
        int d = clamp(int(in.params.x + 0.5), 0, 9);
        int cx = clamp(int((p.x*0.5+0.5)*5.0), 0, 4);
        int cy = clamp(int((1.0-(p.y*0.5+0.5))*7.0), 0, 6);
        uint bit = (uint(kDigit[d][cy]) >> uint(4-cx)) & 1u;
        if (bit == 0u) discard_fragment();
        return float4(gammaOut(in.color.rgb), in.color.a);
    } else if (shape == 6) {                // rounded HUD panel
        float2 q = abs(p) - float2(0.86,0.86);
        float dd = length(max(q,0.0)) - 0.12;
        float aa = fwidth(dd);
        a = smoothstep(aa,-aa,dd);
        return float4(gammaOut(in.color.rgb)*in.color.a*a, in.color.a*a);
    } else if (shape == 7) {                // heart / sick pip (small diamond)
        float d = abs(p.x)+abs(p.y); a = smoothstep(1.0,0.4,d);
    }
    return float4(gammaOut(in.color.rgb) * a, a * in.color.a);
}

// HUD instances positioned directly in NDC.
vertex EOut hud_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                       const device EInst *insts [[buffer(0)]],
                       constant Uni &u [[buffer(1)]]) {
    EInst it = insts[iid];
    float2 lp = kCorners[vid];
    EOut o;
    o.position = float4(float2(it.center) + lp * float2(it.half2), 0.0, 1.0);
    o.lp = lp; o.color = float4(it.color); o.params = float4(it.params); o.shape = it.shape;
    return o;
}
)METAL";

// --------------------------------------------------------------- Renderer ---

@interface BiomeRenderer : NSObject <MTKViewDelegate>
- (instancetype)initWithView:(MTKView *)view;
@end

@implementation BiomeRenderer {
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _groundPipeline;
    id<MTLRenderPipelineState> _entityPipeline;
    id<MTLRenderPipelineState> _hudPipeline;
    id<MTLBuffer> _instBuffers[kMaxInFlight];
    id<MTLBuffer> _hudBuffers[kMaxInFlight];
    int _frameIndex;
    dispatch_semaphore_t _frameSemaphore;
    std::vector<InstC> _scratch;
    std::vector<InstC> _hud;

    std::vector<Critter> _critters;
    std::vector<Food> _food;
    std::mt19937 _rng;
    uint32_t _nextId;
    int _generation;
    int _births, _deaths;
    uint32_t _selected;
    bool _paused;
    float _timeScale;
    float _foodTimer;

    simd_float2 _uScale, _uOffset;
    double _startTime, _lastFrameTime, _simAccum;
    float _smoothedFPS;
}

- (instancetype)initWithView:(MTKView *)view {
    if (!(self = [super init])) return nil;
    id<MTLDevice> device = view.device;
    _queue = [device newCommandQueue];

    id<MTLLibrary> lib = CompileLibrary(device, kShaderSource);
    if (!lib) return nil;
    NSError *err = nil;
    id<MTLFunction> fsv = [lib newFunctionWithName:@"fs_vertex"];

    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    d.vertexFunction = fsv;
    d.fragmentFunction = [lib newFunctionWithName:@"ground_fragment"];
    _groundPipeline = [device newRenderPipelineStateWithDescriptor:d error:&err];
    if (!_groundPipeline) { fprintf(stderr,"ground: %s\n", err.localizedDescription.UTF8String); return nil; }

    d.colorAttachments[0].blendingEnabled = YES;
    d.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    d.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    d.vertexFunction = [lib newFunctionWithName:@"entity_vertex"];
    d.fragmentFunction = [lib newFunctionWithName:@"entity_fragment"];
    _entityPipeline = [device newRenderPipelineStateWithDescriptor:d error:&err];
    if (!_entityPipeline) { fprintf(stderr,"entity: %s\n", err.localizedDescription.UTF8String); return nil; }

    d.vertexFunction = [lib newFunctionWithName:@"hud_vertex"];
    _hudPipeline = [device newRenderPipelineStateWithDescriptor:d error:&err];
    if (!_hudPipeline) { fprintf(stderr,"hud: %s\n", err.localizedDescription.UTF8String); return nil; }

    for (int i = 0; i < kMaxInFlight; i++) {
        _instBuffers[i] = [device newBufferWithLength:kMaxInstances*sizeof(InstC)
                                              options:MTLResourceStorageModeShared];
        _hudBuffers[i] = [device newBufferWithLength:2048*sizeof(InstC)
                                             options:MTLResourceStorageModeShared];
    }
    _frameIndex = 0;
    _frameSemaphore = dispatch_semaphore_create(kMaxInFlight);
    _scratch.reserve(kMaxInstances);
    _hud.reserve(2048);
    // Reserve to the hard caps so births/food never reallocate the vectors
    // mid-simulation (which would invalidate the references we hold).
    _critters.reserve(kMaxCritters);
    _food.reserve(kMaxFood);

    _rng.seed(0xB10E);
    _nextId = 1;
    _selected = 0;
    _paused = NO;
    _timeScale = 1.0f;
    [self resetColony];

    __unsafe_unretained BiomeRenderer *weakSelf = self;
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                          handler:^NSEvent *(NSEvent *e) {
        if (e.modifierFlags & NSEventModifierFlagCommand) return e;
        unsigned short c = e.keyCode;
        if (c == 49) { weakSelf->_paused = !weakSelf->_paused; return nil; }  // space
        if (c == 3)  { [weakSelf scatterFood:60]; return nil; }               // F
        if (c == 40) { [weakSelf cullSelected]; return nil; }                 // K
        if (c == 34) { [weakSelf introduceRandom]; return nil; }              // I
        if (c == 15) { [weakSelf resetColony]; return nil; }                  // R
        if (c == 33) { weakSelf->_timeScale = std::max(weakSelf->_timeScale*0.5f, 0.25f); return nil; } // [
        if (c == 30) { weakSelf->_timeScale = std::min(weakSelf->_timeScale*2.0f, 8.0f); return nil; }  // ]
        return e;
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                          handler:^NSEvent *(NSEvent *e) {
        if (!e.window) return e;
        MTKView *v = (MTKView *)e.window.contentView;
        if (![v isKindOfClass:[MTKView class]] || weakSelf->_uScale.x == 0) return e;
        NSPoint pt = [v convertPoint:e.locationInWindow fromView:nil];
        simd_float2 ndc = simd_make_float2((float)(pt.x/v.bounds.size.width)*2.0f-1.0f,
                                           (float)(pt.y/v.bounds.size.height)*2.0f-1.0f);
        simd_float2 world = (ndc - weakSelf->_uOffset) / weakSelf->_uScale;
        [weakSelf selectAt:world];
        return e;
    }];

    printf("BIOME v1 — Click a critter to inspect. F food · Space pause · [ ] speed\n"
           "         K cull · I introduce · R reset.\n");

    _startTime = CACurrentMediaTime();
    _lastFrameTime = _startTime;
    _simAccum = 0;
    _smoothedFPS = 60;
    return self;
}

// ------------------------------------------------------------------ Setup ---

- (simd_float2)randomPos {
    std::uniform_real_distribution<float> ux(4, kWorldW-4), uy(4, kWorldH-4);
    return simd_make_float2(ux(_rng), uy(_rng));
}

- (void)spawnCritter:(Genome)g at:(simd_float2)pos gen:(int)gen {
    if ((int)_critters.size() >= kMaxCritters) return;
    Critter c = {};
    c.id = _nextId++;
    c.genome = g;
    c.ph = phenotypeOf(g);
    c.male = isMale(g);
    c.pos = pos;
    c.vel = simd_make_float2(0,0);
    std::uniform_real_distribution<float> u(0,1);
    c.heading = u(_rng) * 6.28f;
    for (int i = 0; i < kSpineNodes; i++) c.spine[i] = pos;
    c.age = (gen == 0) ? u(_rng) * 20.0f : 0.0f;   // seed colony has mixed ages
    c.maturity = 14.0f;
    c.energy = 0.7f + 0.3f * u(_rng);
    c.hunger = 0.2f * u(_rng);
    c.urge = 0;
    c.health = 1.0f;
    c.sick = 0;
    c.action = AWander;
    c.targetFood = -1;
    c.targetMate = 0;
    c.pregnant = false;
    c.phase = u(_rng) * 6.28f;
    c.generation = gen;
    c.alive = true;
    _critters.push_back(c);
}

- (void)scatterFood:(int)n {
    for (int i = 0; i < n && (int)_food.size() < kMaxFood; i++) {
        Food f;
        f.pos = [self randomPos];
        f.growth = 0.2f;
        f.alive = true;
        _food.push_back(f);
    }
}

- (void)introduceRandom {
    [self spawnCritter:randomGenome(_rng, -1) at:[self randomPos] gen:_generation];
}

- (void)resetColony {
    _critters.clear();
    _food.clear();
    _generation = 0;
    _births = _deaths = 0;
    _selected = 0;
    for (int i = 0; i < 24; i++)
        [self spawnCritter:randomGenome(_rng, i % 2) at:[self randomPos] gen:0];
    [self scatterFood:220];
}

- (void)selectAt:(simd_float2)world {
    uint32_t best = 0; float bestD = 3.0f;
    for (const Critter &c : _critters) {
        if (!c.alive) continue;
        float d = simd_distance(c.pos, world);
        if (d < bestD) { bestD = d; best = c.id; }
    }
    _selected = best;
}

- (void)cullSelected {
    for (Critter &c : _critters)
        if (c.id == _selected && c.alive) { c.alive = false; _deaths++; }
}

- (Critter *)critterById:(uint32_t)cid {
    for (Critter &c : _critters) if (c.id == cid && c.alive) return &c;
    return nullptr;
}

// -------------------------------------------------------------------- Sim ---

- (void)simStep:(float)dt {
    std::uniform_real_distribution<float> u(0,1);

    // Food regrows / seeds slowly toward a carrying capacity.
    for (Food &f : _food) if (f.alive) f.growth = std::min(f.growth + 0.20f * dt, 1.0f);
    _foodTimer -= dt;
    if (_foodTimer <= 0 && (int)_food.size() < 320) {
        _foodTimer = 0.5f;
        [self scatterFood:3];
    }

    for (size_t i = 0; i < _critters.size(); i++) {
        Critter &c = _critters[i];
        if (!c.alive) continue;
        const Phenotype &ph = c.ph;

        // --- needs ---
        c.age += dt;
        c.hunger = std::min(c.hunger + ph.metabolism * 0.05f * dt, 1.5f);
        float moving = simd_length(c.vel) / std::max(ph.speed, 0.1f);
        c.energy -= (0.01f + ph.metabolism * 0.012f + 0.02f * moving) * dt;
        if (c.hunger > 0.9f) c.energy -= (c.hunger - 0.9f) * 0.15f * dt;   // starving
        if (c.age > c.maturity && c.energy > 0.45f && !c.pregnant)
            c.urge = std::min(c.urge + ph.fertility * 0.06f * dt, 1.0f);

        // --- sickness ---
        if (c.sick > 0) {
            c.sick = std::min(c.sick + (0.12f - ph.resistance * 0.10f) * dt, 1.0f);
            c.health -= c.sick * 0.10f * dt;
            c.energy -= c.sick * 0.03f * dt;
            if (u(_rng) < ph.resistance * 0.4f * dt) c.sick = std::max(c.sick - 0.3f, 0.0f);
            if (c.sick <= 0.01f) c.sick = 0;
        }
        c.health = std::min(c.health + 0.02f * dt, 1.0f);

        // --- death ---
        if (c.age > ph.lifespan || c.energy <= 0 || c.health <= 0) {
            c.alive = false; _deaths++;
            if (c.id == _selected) _selected = 0;
            continue;
        }

        // --- utility AI: pick the most pressing drive ---
        float sForage = c.hunger;
        float sRest = (1.0f - c.energy) * 0.9f;
        float sMate = (c.age > c.maturity && c.energy > 0.5f && !c.pregnant) ? c.urge : 0.0f;
        float sWander = 0.15f;
        c.action = AWander;
        float best = sWander;
        if (sForage > best) { best = sForage; c.action = AForage; }
        if (sRest > best)   { best = sRest;   c.action = ARest; }
        if (sMate > best)   { best = sMate;   c.action = AMate; }

        // --- act ---
        simd_float2 desire = simd_make_float2(0,0);
        float wantSpeed = ph.speed;
        if (c.action == AForage) {
            int fi = c.targetFood;
            if (fi < 0 || fi >= (int)_food.size() || !_food[fi].alive) {
                fi = -1; float bd = ph.sensory;
                for (int k = 0; k < (int)_food.size(); k++) {
                    if (!_food[k].alive || _food[k].growth < 0.4f) continue;
                    float dd = simd_distance(_food[k].pos, c.pos);
                    if (dd < bd) { bd = dd; fi = k; }
                }
                c.targetFood = fi;
            }
            if (fi >= 0) {
                simd_float2 to = _food[fi].pos - c.pos;
                float dd = simd_length(to);
                if (dd < 1.0f + ph.size * 0.5f) {          // eat
                    c.hunger = std::max(c.hunger - _food[fi].growth * 0.9f, 0.0f);
                    c.energy = std::min(c.energy + _food[fi].growth * 0.5f, 1.0f);
                    _food[fi].alive = false;
                    c.targetFood = -1;
                } else desire = to / std::max(dd, 1e-3f);
            } else {   // wander to search
                c.heading += (u(_rng) - 0.5f) * 2.0f * dt;
                desire = simd_make_float2(cosf(c.heading), sinf(c.heading));
                wantSpeed *= 0.6f;
            }
        } else if (c.action == ARest) {
            wantSpeed = 0.0f;
            c.energy = std::min(c.energy + 0.06f * dt, 1.0f);
        } else if (c.action == AMate) {
            Critter *mate = [self critterById:c.targetMate];
            bool ok = mate && mate->male != c.male && mate->age > mate->maturity;
            if (!ok) {
                c.targetMate = 0; float bd = ph.sensory;
                for (Critter &o : _critters) {
                    if (!o.alive || o.id == c.id || o.male == c.male) continue;
                    if (o.age <= o.maturity || o.energy < 0.4f) continue;
                    float dd = simd_distance(o.pos, c.pos);
                    if (dd < bd) { bd = dd; c.targetMate = o.id; }
                }
                mate = [self critterById:c.targetMate];
            }
            if (mate) {
                simd_float2 to = mate->pos - c.pos;
                float dd = simd_length(to);
                if (dd < 1.4f + ph.size) {
                    // Conception: the female carries the offspring.
                    Critter *mom = c.male ? mate : &c;
                    Critter *dad = c.male ? &c : mate;
                    if (!mom->pregnant && mom->urge > 0.5f && dad->urge > 0.4f) {
                        mom->unborn = breed(mom->genome, dad->genome, _rng);
                        mom->pregnant = true;
                        mom->gestation = 6.0f;
                        mom->urge = 0; dad->urge = 0;
                        mom->energy -= 0.2f; dad->energy -= 0.1f;
                    }
                } else desire = to / std::max(dd, 1e-3f);
            } else { wantSpeed *= 0.6f; desire = simd_make_float2(cosf(c.heading), sinf(c.heading)); }
        } else {  // wander
            c.heading += (u(_rng) - 0.5f) * 1.5f * dt;
            desire = simd_make_float2(cosf(c.heading), sinf(c.heading));
            wantSpeed *= 0.5f;
        }

        // --- steer + integrate ---
        simd_float2 wantVel = (simd_length(desire) > 1e-3f)
            ? simd_normalize(desire) * wantSpeed : simd_make_float2(0,0);
        c.vel += (wantVel - c.vel) * std::min(4.0f * dt, 1.0f);
        if (simd_length(c.vel) > 0.05f) c.heading = atan2f(c.vel.y, c.vel.x);
        c.pos += c.vel * dt;
        // sickness saps mobility
        if (c.sick > 0) c.pos -= c.vel * dt * c.sick * 0.5f;
        c.pos.x = std::clamp(c.pos.x, 1.0f, kWorldW - 1.0f);
        c.pos.y = std::clamp(c.pos.y, 1.0f, kWorldH - 1.0f);
        c.phase += (0.5f + simd_length(c.vel) * 0.5f) * dt * 6.0f;

        // --- Verlet spine follows the head ---
        c.spine[0] = c.pos;
        float link = 0.42f * ph.size;
        for (int s = 1; s < kSpineNodes; s++) {
            simd_float2 dir = c.spine[s] - c.spine[s-1];
            float dl = simd_length(dir);
            if (dl > 1e-4f) c.spine[s] = c.spine[s-1] + dir / dl * link;
            // lateral slither offset
            simd_float2 perp = simd_make_float2(-sinf(c.heading), cosf(c.heading));
            c.spine[s] += perp * sinf(c.phase - s * 0.9f) * 0.06f * ph.size
                        * simd_length(c.vel) / std::max(ph.speed,1.0f);
        }

        // --- gestation / birth ---
        if (c.pregnant) {
            c.gestation -= dt;
            if (c.gestation <= 0) {
                int gen = c.generation + 1;
                [self spawnCritter:c.unborn at:(c.pos + simd_make_float2(u(_rng)-0.5f, u(_rng)-0.5f))
                               gen:gen];
                _births++;
                _generation = std::max(_generation, gen);
                c.pregnant = false;
            }
        }
    }

    // --- contagion: spread by proximity (cheap O(n^2) for the slice size) ---
    for (size_t i = 0; i < _critters.size(); i++) {
        Critter &a = _critters[i];
        if (!a.alive || a.sick < 0.2f) continue;
        for (size_t j = i+1; j < _critters.size(); j++) {
            Critter &b = _critters[j];
            if (!b.alive || b.sick > 0) continue;
            if (simd_distance(a.pos, b.pos) < 2.2f &&
                u(_rng) < (0.5f * (1.0f - b.ph.resistance)) * dt)
                b.sick = 0.2f;
        }
    }
    // rare spontaneous infection keeps disease in the ecosystem
    if (!_critters.empty() && u(_rng) < 0.02f * dt * _critters.size()) {
        Critter &c = _critters[_rng() % _critters.size()];
        if (c.alive && c.sick == 0) c.sick = 0.2f;
    }

    // compact dead
    _critters.erase(std::remove_if(_critters.begin(), _critters.end(),
                    [](const Critter &c){ return !c.alive; }), _critters.end());
    _food.erase(std::remove_if(_food.begin(), _food.end(),
                [](const Food &f){ return !f.alive; }), _food.end());
}

// ---------------------------------------------------------------- Render ---

- (void)push:(simd_float2)c half:(simd_float2)h rot:(float)rot shape:(float)s
       color:(simd_float4)col p:(simd_float4)pr {
    if ((int)_scratch.size() >= kMaxInstances) return;
    _scratch.push_back({c.x,c.y,h.x,h.y,rot,s, col.x,col.y,col.z,col.w, pr.x,pr.y,pr.z,pr.w});
}
- (void)hud:(float)cx cy:(float)cy hw:(float)hw hh:(float)hh shape:(float)s
      color:(simd_float4)col p0:(float)p0 {
    _hud.push_back({cx,cy,hw,hh,0,s, col.x,col.y,col.z,col.w, p0,0,0,0});
}

- (void)hudNumber:(int)value x:(float)x y:(float)y dw:(float)dw dh:(float)dh
              col:(simd_float4)col bw:(float)bw bh:(float)bh {
    char buf[12]; snprintf(buf, sizeof(buf), "%d", value);
    for (int i = 0; buf[i]; i++) {
        float cx = (x + i*(dw*2.0f+4.0f) + dw) / bw * 2.0f - 1.0f;
        float cy = (y + dh) / bh * 2.0f - 1.0f;
        [self hud:cx cy:cy hw:dw/bw hh:dh/bh shape:5 color:col p0:(float)(buf[i]-'0')];
    }
}

- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) return;

    double now = CACurrentMediaTime();
    float t = (float)(now - _startTime);
    float dtRaw = (float)(now - _lastFrameTime);
    _lastFrameTime = now;
    if (dtRaw > 0) _smoothedFPS += (1.0f/dtRaw - _smoothedFPS) * 0.05f;

    if (!_paused) {
        _simAccum += std::min(dtRaw * _timeScale, 0.5f);
        const double step = 1.0/60.0;
        int guard = 0;
        while (_simAccum >= step && guard++ < 40) { [self simStep:(float)step]; _simAccum -= step; }
    }

    float aspect = (float)(view.drawableSize.width / view.drawableSize.height);
    float s = std::min(2.0f*aspect/kWorldW, 2.0f/kWorldH) * 0.96f;
    _uScale = simd_make_float2(s/aspect, s);
    _uOffset = simd_make_float2(-kWorldW*0.5f*s/aspect, -kWorldH*0.5f*s);

    struct { simd_float2 scale, offset, resolution; float time, pad; } uni = {
        _uScale, _uOffset,
        simd_make_float2((float)view.drawableSize.width, (float)view.drawableSize.height), t, 0
    };

    dispatch_semaphore_wait(_frameSemaphore, DISPATCH_TIME_FOREVER);
    _scratch.clear();
    _hud.clear();

    // food
    for (const Food &f : _food) {
        if (!f.alive) continue;
        float g = f.growth;
        [self push:f.pos half:simd_make_float2(0.5f*g+0.2f, 0.5f*g+0.2f) rot:0 shape:2
              color:simd_make_float4(0.30f, 0.55f+0.25f*g, 0.18f, 1.0f) p:simd_make_float4(0,0,0,0)];
    }

    // critters: spine of soft blobs, head + eyes, status pips
    for (const Critter &c : _critters) {
        if (!c.alive) continue;
        simd_float4 col = simd_make_float4(c.ph.color, 1.0f);
        if (c.sick > 0)   col = col + (simd_make_float4(0.7f,0.85f,0.3f,0) - col) * (c.sick*0.6f);
        if (c.health < 0.5f) { float f = 0.6f + 0.4f*c.health; col.x*=f; col.y*=f; col.z*=f; }
        for (int sidx = kSpineNodes-1; sidx >= 0; sidx--) {
            float taper = 1.0f - sidx * 0.12f;
            float rr = c.ph.size * 0.55f * taper;
            simd_float4 sc = col; sc.w = 1.0f;
            [self push:c.spine[sidx] half:simd_make_float2(rr,rr) rot:0 shape:0
                  color:sc p:simd_make_float4(0,0,0,0)];
        }
        // head accent + eyes
        simd_float2 hd = c.pos;
        simd_float2 fwd = simd_make_float2(cosf(c.heading), sinf(c.heading));
        simd_float2 perp = simd_make_float2(-fwd.y, fwd.x);
        float er = 0.14f * c.ph.size;
        [self push:hd + fwd*0.18f*c.ph.size + perp*0.22f*c.ph.size
              half:simd_make_float2(er,er) rot:0 shape:3
              color:simd_make_float4(1,1,1,1) p:simd_make_float4(0,0,0,0)];
        [self push:hd + fwd*0.18f*c.ph.size - perp*0.22f*c.ph.size
              half:simd_make_float2(er,er) rot:0 shape:3
              color:simd_make_float4(1,1,1,1) p:simd_make_float4(0,0,0,0)];
        // sex tick + pregnancy/sick pips above the head
        simd_float2 top = c.pos + simd_make_float2(0, c.ph.size * 0.9f);
        if (c.pregnant)
            [self push:top half:simd_make_float2(0.18f,0.18f) rot:0 shape:7
                  color:simd_make_float4(1.0f,0.5f,0.7f,1) p:simd_make_float4(0,0,0,0)];
    }

    // selection ring + inspector
    Critter *sel = [self critterById:_selected];
    if (sel) {
        [self push:sel->pos half:simd_make_float2(sel->ph.size*1.3f, sel->ph.size*1.3f)
              rot:0 shape:1 color:simd_make_float4(1.0f,0.9f,0.2f,1.0f) p:simd_make_float4(0,0,0,0)];
    }

    id<MTLBuffer> ib = _instBuffers[_frameIndex];
    NSUInteger ic = _scratch.size();
    if (ic) memcpy([ib contents], _scratch.data(), ic*sizeof(InstC));

    // ---- HUD ----
    float bw = (float)view.bounds.size.width, bh = (float)view.bounds.size.height;
    [self buildHUD:sel bw:bw bh:bh];
    id<MTLBuffer> hb = _hudBuffers[_frameIndex];
    NSUInteger hc = _hud.size();
    if (hc) memcpy([hb contents], _hud.data(), hc*sizeof(InstC));

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:_groundPipeline];
    [enc setFragmentBytes:&uni length:sizeof(uni) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    if (ic) {
        [enc setRenderPipelineState:_entityPipeline];
        [enc setVertexBuffer:ib offset:0 atIndex:0];
        [enc setVertexBytes:&uni length:sizeof(uni) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:ic];
    }
    if (hc) {
        [enc setRenderPipelineState:_hudPipeline];
        [enc setVertexBuffer:hb offset:0 atIndex:0];
        [enc setVertexBytes:&uni length:sizeof(uni) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:hc];
    }
    [enc endEncoding];

    dispatch_semaphore_t sem = _frameSemaphore;
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> cb){ (void)cb; dispatch_semaphore_signal(sem); }];
    [cmd presentDrawable:drawable];
    [cmd commit];
    _frameIndex = (_frameIndex + 1) % kMaxInFlight;

    int males = 0, females = 0, sick = 0;
    for (const Critter &c : _critters) { if (c.male) males++; else females++; if (c.sick>0) sick++; }
    view.window.title = [NSString stringWithFormat:
        @"09 — BIOME ▸ pop %d (%dM/%dF) ▸ gen %d ▸ births %d deaths %d ▸ sick %d ▸ x%.2g%s ▸ %.0f fps",
        (int)_critters.size(), males, females, _generation, _births, _deaths, sick,
        _timeScale, _paused ? " PAUSED" : "", _smoothedFPS];
}

// ------------------------------------------------------------- Inspector ---

- (void)buildHUD:(Critter *)sel bw:(float)bw bh:(float)bh {
    auto rect = [&](float x, float y, float w, float h, simd_float4 col, float shape) {
        float cx = (x + w*0.5f)/bw*2.0f-1.0f, cy = (y + h*0.5f)/bh*2.0f-1.0f;
        [self hud:cx cy:cy hw:w/bw hh:h/bh shape:shape color:col p0:0];
    };
    if (!sel) return;
    float px = 16, py = 16, pw = 340, ph = 330;
    rect(px-8, py-8, pw+16, ph+16, simd_make_float4(0.05f,0.06f,0.08f,0.86f), 6);

    // trait bars
    struct { const char *n; float v; } bars[] = {
        {"size", (sel->ph.size-0.6f)/1.1f}, {"speed", sel->ph.speed/16.0f},
        {"metab", sel->ph.metabolism/1.7f}, {"sensory", (sel->ph.sensory-14.0f)/16.0f},
        {"fertility", sel->ph.fertility}, {"resist", sel->ph.resistance},
        {"energy", sel->energy}, {"hunger", sel->hunger}, {"health", sel->health},
    };
    float by = py + 46;
    for (auto &b : bars) {
        rect(px, by, 200, 12, simd_make_float4(0.15f,0.16f,0.18f,1.0f), 4);
        rect(px, by, 200*std::clamp(b.v,0.0f,1.0f), 12,
             simd_make_float4(0.35f,0.75f,0.95f,1.0f), 4);
        by += 20;
    }
    // sex + color swatch
    rect(px+220, py+46, 100, 60,
         simd_make_float4(sel->ph.color.x, sel->ph.color.y, sel->ph.color.z, 1.0f), 4);
    rect(px+220, py+112, 100, 16,
         sel->male ? simd_make_float4(0.4f,0.6f,1.0f,1.0f)
                   : simd_make_float4(1.0f,0.5f,0.7f,1.0f), 4);

    // genome strip: both homologs, each gene 16 bases as colored ticks
    // (A green, C blue, G yellow, T red). Two rows per gene = the pair.
    float gy = py + ph - 96;
    float tickW = (pw - 20) / (float)(kNumGenes * 16);
    simd_float4 baseCol[4] = {
        simd_make_float4(0.30f,0.85f,0.35f,1), simd_make_float4(0.30f,0.55f,0.95f,1),
        simd_make_float4(0.95f,0.85f,0.30f,1), simd_make_float4(0.95f,0.35f,0.30f,1),
    };
    for (int h = 0; h < 2; h++) {
        for (int g = 0; g < kNumGenes; g++) {
            uint32_t word = sel->genome.hom[h][g];
            for (int b = 0; b < 16; b++) {
                int base = (word >> (2*b)) & 3;
                float x = px + (g*16 + b) * tickW;
                rect(x, gy + h*40, tickW*0.9f, 32, baseCol[base], 4);
            }
        }
    }
    // header numbers: id and age
    [self hudNumber:(int)sel->id x:px y:py dw:6 dh:11 col:simd_make_float4(1,1,1,1) bw:bw bh:bh];
    [self hudNumber:(int)sel->age x:px+120 y:py dw:6 dh:11 col:simd_make_float4(0.8f,0.9f,1,1) bw:bw bh:bh];
    [self hudNumber:sel->generation x:px+220 y:py dw:6 dh:11 col:simd_make_float4(0.7f,1,0.7f,1) bw:bw bh:bh];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}
@end

int main() {
    return RunMetalApp(@"09 — BIOME", 1280, 800, ^(MTKView *view) {
        return (NSObject<MTKViewDelegate> *)[[BiomeRenderer alloc] initWithView:view];
    });
}
