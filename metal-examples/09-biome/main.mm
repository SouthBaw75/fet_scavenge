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
static const int kMaxPredators = 90;
static const int kMaxNests = 200;
static const float kNestRadius = 3.2f;   // shelter + build range
static const int kMaxWater = 12;
static const int kMaxRipples = 700;
static const int kMaxInstances = 32768;
static const int kMaxInFlight = 3;
static const int kSpineNodes = 6;

// Environmental selection. The climate drifts (gentle seasons + a slow
// random-walk trend) and imposes a survival cost on critters whose body size
// and coat darkness are ill-suited to it — cold favors large, dark bodies that
// retain heat (Bergmann's + Gloger's rules), heat favors small, pale ones. So
// the population's genome tracks the environment over generations: real,
// visible directional selection on top of drift and mutation.
static const float kSeasonSecs   = 120.0f;  // one seasonal cycle (sim seconds)
static const float kThermalCost  = 0.055f;  // energy/sec drain at full mismatch
static const int   kHistLen      = 120;     // trait-history samples (~sim minutes)
static const float kSampleSecs   = 1.0f;    // one history sample per sim second

// Genome layout: kNumGenes autosomal loci spread across kChromosomes. Related
// genes share a chromosome so they tend to inherit together (linkage).
static const int kNumGenes = 20;
static const int kChromosomes = 4;
static const int kGenesPerChrom = kNumGenes / kChromosomes;   // 5
static const float kMutationRate = 0.04f;   // chance per gene per gamete

// Gene indices -> traits. Genes on a chromosome inherit together (linkage);
// with 5 genes per chromosome the eye-color loci travel with the features set.
enum { GSize0 = 0, GSize1 = 1, GSpeed = 2, GMetab = 3,
       GColR  = 4, GColG  = 5, GColB  = 6, GResist = 7,
       GAspect = 8, GGirth = 9, GEye = 10, GSnout = 11,
       GSpikes = 12, GPattern = 13, GPatHue = 14, GFert = 15,
       GEyeR = 16, GEyeG = 17, GEyeB = 18, GEyeShine = 19 };

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

// Phenotype: the visible, playable traits translated from the genome. Many
// are small physical shifts that compound over generations so lineages
// visibly diverge in body plan and markings.
struct Phenotype {
    float size;        // body scale
    float speed;       // move speed
    float metabolism;  // energy burn + hunger rate
    float sensory;     // perception radius (tied to eye size)
    float fertility;   // urge growth / litter viability
    float resistance;  // disease resistance
    float lifespan;    // seconds
    // --- visible morphology ---
    float aspect;      // 0..1 body elongation (long+slender vs short+round)
    float girth;       // 0..1 belly fullness
    float eyeSize;     // eye radius fraction
    float snout;       // 0..1 head projection
    float spikes;      // 0..1 side-fin prominence
    float pattern;     // 0..1 banding strength
    simd_float3 color;  // primary coat color
    simd_float3 color2; // secondary (banding) color
    simd_float3 eyeColor; // heritable iris color
    float eyeShine;    // 0..1 iris brightness
};

// Perceived brightness of a coat color (Rec. 601 luma); 1-this is "darkness".
static inline float coatLuma(simd_float3 c) {
    return 0.299f * c.x + 0.587f * c.y + 0.114f * c.z;
}
// Colour vividness (saturation): how far the coat is from a drab gray. Vivid
// coats are attractive to mates but also easier for predators to spot.
static inline float coatVividness(simd_float3 c) {
    float mx = std::max(std::max(c.x, c.y), c.z);
    float mn = std::min(std::min(c.x, c.y), c.z);
    return std::clamp((mx - mn) * 1.6f, 0.0f, 1.0f);
}

// How well a phenotype suits the current climate, 0 (lethal mismatch) .. 1
// (ideal). want=1 in the cold (favor big + dark), want=0 in the heat.
static inline float adaptation(const Phenotype &p, float climate) {
    float want     = 0.5f - 0.5f * climate;                       // cold->1 hot->0
    float sizeNorm = std::clamp((p.size - 0.6f) / 1.1f, 0.0f, 1.0f);
    float dark     = 1.0f - coatLuma(p.color);
    float miss     = 0.6f * fabsf(sizeNorm - want) + 0.4f * fabsf(dark - want);
    return std::clamp(1.0f - miss, 0.0f, 1.0f);
}

static Phenotype phenotypeOf(const Genome &g) {
    auto L = [&](int i) { return locusValue(g.hom[0][i], g.hom[1][i]); };
    Phenotype p;
    float sz = (L(GSize0) + L(GSize1)) * 0.5f;
    p.size = 0.6f + 1.1f * sz;
    p.eyeSize = 0.09f + 0.15f * L(GEye);
    // Pleiotropy: bigger critters are slower and burn more energy; sharper
    // eyes see farther.
    p.speed = (6.0f + 10.0f * L(GSpeed)) * (1.25f - 0.5f * sz);
    p.metabolism = (0.5f + 1.2f * L(GMetab)) * (0.7f + 0.6f * sz);
    p.sensory = 10.0f + 62.0f * p.eyeSize;
    p.fertility = 0.4f + 0.9f * L(GFert);
    p.resistance = L(GResist);
    p.lifespan = 55.0f + 70.0f * (1.0f - L(GMetab)) + 20.0f * (1.0f - sz);
    p.color = simd_make_float3(0.35f + 0.6f * L(GColR),
                               0.35f + 0.6f * L(GColG),
                               0.35f + 0.6f * L(GColB));
    p.aspect = L(GAspect);
    p.girth = L(GGirth);
    p.snout = L(GSnout);
    p.spikes = L(GSpikes);
    p.pattern = L(GPattern);
    // Secondary color: a shift toward the complement, scaled by the hue gene,
    // so markings read distinct from the coat.
    float hue = L(GPatHue);
    simd_float3 comp = simd_make_float3(1.0f, 1.0f, 1.0f) - p.color;
    p.color2 = (p.color + (comp - p.color) * (0.35f + 0.55f * hue)) * 0.92f;
    // Heritable iris color (its own loci, so it recombines independently). The
    // channels are saturation-boosted around their mean so eyes read as vivid,
    // varied colors (blue, green, amber, red) rather than muddy grays.
    float er0 = L(GEyeR), eg0 = L(GEyeG), eb0 = L(GEyeB);
    float emean = (er0 + eg0 + eb0) / 3.0f;
    auto sat = [&](float v){ return std::clamp(emean + (v - emean) * 2.6f, 0.0f, 1.0f); };
    p.eyeColor = simd_make_float3(0.10f + 0.85f * sat(er0),
                                  0.10f + 0.85f * sat(eg0),
                                  0.10f + 0.85f * sat(eb0));
    p.eyeShine = L(GEyeShine);
    return p;
}

// ------------------------------------------------------------------ World ---

enum { AWander = 0, AForage = 1, ARest = 2, AMate = 3, AFlee = 4, ANest = 5, ADrink = 6 };

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
    float thirst;      // 0..1.5 (1 = parched)
    float urge;        // 0..1 reproduction
    float health;      // 0..1
    float sick;        // 0..1 infection load, 0 = healthy
    int action;
    int targetFood;
    uint32_t targetMate;
    bool pregnant;
    float gestation;
    Genome unborn;     // first offspring's genome, fixed at conception
    Genome mateGenome; // the father's genome, for meiosis of litter-mates
    float phase;       // slither phase
    int generation;
    bool sheltered;    // within a nest's radius this step
    bool alive;
};

// Mate attractiveness (sexual-selection signal): vivid colour + prominent fins
// + size, scaled by condition (energy·health) so it's an honest signal. Females
// prefer high-ornament males — which also makes those males more visible to
// predators, the classic survival-vs-display trade-off.
static inline float ornament(const Critter &c) {
    float vivid = coatVividness(c.ph.color);
    float sizeN = std::clamp((c.ph.size - 0.6f) / 1.1f, 0.0f, 1.0f);
    float condition = c.energy * c.health;
    return (0.42f*vivid + 0.30f*c.ph.spikes + 0.18f*sizeN + 0.10f)
         * (0.55f + 0.45f*condition);
}

struct Food {
    simd_float2 pos;
    float growth;      // 0..1
    bool alive;
};

// A simple hunting predator (not diploid — a lean agent). It preys on
// critters, and its numbers rise and fall with the prey supply, producing
// predator/prey population cycles. Prey coats that match the ground are harder
// for it to spot, so predation selects for camouflage.
struct Predator {
    simd_float2 pos, vel;
    float heading;
    simd_float2 spine[kSpineNodes];
    float age, lifespan;
    float energy;      // starves at 0
    float size;
    uint32_t targetPrey;
    float cooldown;    // brief pause after a kill
    float phase;
    bool alive;
};

// A nest: a built breeding site. A female returns to hers to give birth (pups
// start with an energy bonus scaled by nest quality) and it offers cover —
// prey near a nest are harder for predators to spot. Nests improve while
// tended and decay when abandoned.
struct Nest {
    simd_float2 pos;
    uint32_t owner;
    float quality;     // 0..1, built up over time
    bool alive;
};

// A pool of drinking water. Critters build up thirst and head to the nearest
// pool to drink; neglecting it dehydrates them.
struct Water {
    simd_float2 pos;
    float radius;
};

// An expanding ring left in the water as something moves across it (a wake).
struct Ripple {
    simd_float2 pos;
    float age, life;
};

// -------------------------------------------------------------- Instances ---

struct InstC {
    float cx, cy, hx, hy, rot, shape;
    float r, g, b, a;
    float p0, p1, p2, p3;
};

// ------------------------------------------------------------ HUD widgets ---
// Every control is a clickable rectangle rebuilt each frame; the mouse handler
// hit-tests these instead of the keyboard driving the sim.
enum {
    WA_None = 0, WA_Toggle, WA_Pause, WA_SpeedDn, WA_SpeedUp,
    WA_ClimateSlider, WA_Food, WA_FoodSlider, WA_Introduce, WA_Cull, WA_Reset,
    WA_TraitPick, WA_ExprSlider, WA_Splice, WA_ToggleGraph,
    WA_AddPredator, WA_CullPredators, WA_StartPopSlider, WA_LifespanSlider,
    WA_ClearColony, WA_ZoomIn, WA_ZoomOut, WA_ResetView, WA_BirthRateSlider,
};
struct UIWidget { float x, y, w, h; int act; float val; };

// Genes exposed in the splice lab (short label + locus).
struct TraitBtn { const char *name; int gene; };
static const TraitBtn kTraits[] = {
    {"SIZE", GSize0}, {"SPEED", GSpeed}, {"METAB", GMetab}, {"RESIST", GResist},
    {"EYES", GEye},   {"RED", GColR},    {"GREEN", GColG},  {"BLUE", GColB},
    {"FINS", GSpikes},{"BODY", GAspect},
};
static const int kNumTraitBtns = sizeof(kTraits) / sizeof(kTraits[0]);

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

    // Biome fields: large-scale moisture + elevation choose the ground type.
    float moist = fbm(w * 0.018 + 11.3);
    float elev  = fbm(w * 0.030 + 3.7);

    float3 grass = mix(float3(0.13,0.27,0.11), float3(0.22,0.37,0.16), moist);
    float3 dirt  = float3(0.32,0.25,0.15);
    float3 sand  = float3(0.44,0.39,0.25);
    float3 rock  = float3(0.30,0.30,0.32);

    float3 col = grass;
    col = mix(col, dirt, 1.0 - smoothstep(0.28, 0.46, moist));                 // dry -> dirt
    col = mix(col, sand, (1.0 - smoothstep(0.16,0.30,moist)) * smoothstep(0.35,0.52,elev)); // arid highs -> sand
    col = mix(col, rock, smoothstep(0.60, 0.80, elev));                        // high -> rock

    // Fine texture: speckle + a touch of high-frequency variation.
    col *= 0.90 + 0.18 * fbm(w * 0.75);
    col += 0.045 * (fbm(w * 2.3 + 7.0) - 0.5);

    // Relief shading — light from the upper-left over the elevation field.
    float e0 = fbm(w*0.05), ex = fbm((w+float2(1.6,0))*0.05), ey = fbm((w+float2(0,1.6))*0.05);
    float shade = clamp(0.85 + (-(ex-e0)*0.8 - (ey-e0)*0.6) * 4.0, 0.55, 1.35);
    col *= shade;

    // Climate: frosty-blue cold vs sun-baked warm; snow on higher ground when
    // it gets truly cold.
    float clim = clamp(u.pad, -1.0, 1.0);
    float3 cold = float3(0.14,0.20,0.26), warm = float3(0.34,0.29,0.14);
    col = mix(col, mix(cold, warm, clim*0.5+0.5), 0.24 * abs(clim));
    float snow = smoothstep(0.45, 0.9, -clim) * smoothstep(0.35, 0.65, elev);
    col = mix(col, float3(0.82,0.86,0.92), clamp(snow, 0.0, 0.85));

    // Darken beyond the world bounds.
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
// 5x7 uppercase font, A..Z, for HUD labels.
constant ushort kAlpha[26][7] = {
    {0x0E,0x11,0x11,0x1F,0x11,0x11,0x11},{0x1E,0x11,0x11,0x1E,0x11,0x11,0x1E}, // A B
    {0x0E,0x11,0x10,0x10,0x10,0x11,0x0E},{0x1E,0x11,0x11,0x11,0x11,0x11,0x1E}, // C D
    {0x1F,0x10,0x10,0x1E,0x10,0x10,0x1F},{0x1F,0x10,0x10,0x1E,0x10,0x10,0x10}, // E F
    {0x0E,0x11,0x10,0x17,0x11,0x11,0x0F},{0x11,0x11,0x11,0x1F,0x11,0x11,0x11}, // G H
    {0x0E,0x04,0x04,0x04,0x04,0x04,0x0E},{0x07,0x02,0x02,0x02,0x02,0x12,0x0C}, // I J
    {0x11,0x12,0x14,0x18,0x14,0x12,0x11},{0x10,0x10,0x10,0x10,0x10,0x10,0x1F}, // K L
    {0x11,0x1B,0x15,0x15,0x11,0x11,0x11},{0x11,0x11,0x19,0x15,0x13,0x11,0x11}, // M N
    {0x0E,0x11,0x11,0x11,0x11,0x11,0x0E},{0x1E,0x11,0x11,0x1E,0x10,0x10,0x10}, // O P
    {0x0E,0x11,0x11,0x11,0x15,0x12,0x0D},{0x1E,0x11,0x11,0x1E,0x14,0x12,0x11}, // Q R
    {0x0F,0x10,0x10,0x0E,0x01,0x01,0x1E},{0x1F,0x04,0x04,0x04,0x04,0x04,0x04}, // S T
    {0x11,0x11,0x11,0x11,0x11,0x11,0x0E},{0x11,0x11,0x11,0x11,0x11,0x0A,0x04}, // U V
    {0x11,0x11,0x11,0x15,0x15,0x1B,0x11},{0x11,0x11,0x0A,0x04,0x0A,0x11,0x11}, // W X
    {0x11,0x11,0x0A,0x04,0x04,0x04,0x04},{0x1F,0x01,0x02,0x04,0x08,0x10,0x1F}, // Y Z
};
// A few symbols (codes 36+): '+', '-', '.', '%'.
constant ushort kSym[4][7] = {
    {0x00,0x04,0x04,0x1F,0x04,0x04,0x00},   // 36 '+'
    {0x00,0x00,0x00,0x1F,0x00,0x00,0x00},   // 37 '-'
    {0x00,0x00,0x00,0x00,0x00,0x0C,0x0C},   // 38 '.'
    {0x18,0x19,0x02,0x04,0x08,0x13,0x03},   // 39 '%'
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
    } else if (shape == 2) {                // organic leafy sprig (params.x = seed)
        float seed = in.params.x;
        float ang = atan2(p.y, p.x), rad = length(p);
        float lobe = 0.5 + 0.5*cos(ang*5.0 + seed);          // a few leaf lobes
        float wob = 0.18*vnoise(float2(ang*2.5, 1.3)+seed);  // broken edge
        float edge = 0.40 + 0.42*lobe + wob;
        float aa = fwidth(rad);
        float av = smoothstep(edge, edge-0.14-aa, rad);
        if (av < 0.02) discard_fragment();
        float tex = 0.70 + 0.5*vnoise(p*5.0 + seed);         // leaf mottling
        float3 leaf = in.color.rgb * (0.55 + 0.7*rad) * tex; // dark base, bright tips
        return float4(gammaOut(leaf)*av, av);
    } else if (shape == 3) {                // eye: pupil + heritable iris + sclera
        float r = length(p);
        float3 iris = in.color.rgb;
        float3 c = (r < 0.26) ? float3(0.03)                 // pupil
                 : (r < 0.74) ? iris * (0.72 + 0.5*(0.74-r)) // iris fills most of eye
                 : float3(0.95);                             // thin sclera rim
        float av = smoothstep(1.0, 0.78, r);
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
    } else if (shape == 8) {                // text glyph: params.x = 0-9 digit, 10-35 A-Z
        int code = clamp(int(in.params.x + 0.5), 0, 39);
        int cx = clamp(int((p.x*0.5+0.5)*5.0), 0, 4);
        int cy = clamp(int((1.0-(p.y*0.5+0.5))*7.0), 0, 6);
        ushort rowbits = (code < 10) ? kDigit[code][cy]
                       : (code < 36) ? kAlpha[code-10][cy] : kSym[code-36][cy];
        uint bit = (uint(rowbits) >> uint(4-cx)) & 1u;
        if (bit == 0u) discard_fragment();
        return float4(gammaOut(in.color.rgb), in.color.a);
    } else if (shape == 9) {                // woven nest bowl (params.x = seed)
        float seed = in.params.x;
        float ang = atan2(p.y, p.x), rad = length(p);
        float outer = 0.90 + 0.10*vnoise(float2(ang*3.0, 2.0)+seed) + 0.05*sin(ang*6.0+seed);
        float aa = fwidth(rad);
        float disc = smoothstep(outer, outer-0.12-aa, rad);
        if (disc < 0.02) discard_fragment();
        float inner = 0.46 + 0.09*vnoise(float2(ang*4.0, 6.0)+seed);
        float cup = smoothstep(inner-0.06, inner+0.12, rad);       // 0 hollow .. 1 rim
        float strands = vnoise(float2(ang*20.0, rad*9.0)+seed);    // woven look
        float3 twig = in.color.rgb * (0.55 + 0.75*strands);
        float3 hollow = in.color.rgb * 0.22;
        float3 col = mix(hollow, twig, cup);
        col += in.color.rgb * 0.30 * smoothstep(outer-0.18, outer, rad); // rim highlight
        return float4(gammaOut(col)*disc, disc);
    } else if (shape == 10) {               // animated water (params.x=time, y=seed)
        float t = in.params.x, seed = in.params.y;
        float ang = atan2(p.y, p.x), rad = length(p);
        // Irregular, softly lapping shoreline — no hard circle.
        float edge = 0.90 + 0.06*vnoise(float2(ang*3.0,1.0)+seed)
                          + 0.03*sin(ang*5.0 + seed*1.7 + t*0.6);
        float aa = fwidth(rad);
        float mask = smoothstep(edge, edge-0.09-aa, rad);
        if (mask < 0.01) discard_fragment();
        // Depth: darker toward the middle, lighter at the shallows.
        float depth = smoothstep(edge, 0.0, rad);
        float3 col = mix(float3(0.22,0.46,0.60), float3(0.05,0.17,0.35), depth);
        // Surface: layered wavelets drifting in different directions + fbm swell.
        float2 s = p * 5.0;
        float h = 0.5*sin(s.x*1.2 + t*1.6 + seed)
                + 0.4*sin(s.y*1.6 - t*1.2)
                + 0.6*fbm(p*3.2 + float2(t*0.10, -t*0.08));
        float glint = smoothstep(0.72, 1.0, 0.5+0.5*sin(h*3.14159));
        col += glint * 0.16;                 // soft moving sparkle
        col += 0.05 * (h - 0.75);            // gentle light/dark shading
        float foam = smoothstep(edge-0.05, edge, rad);      // wet, bright shore
        col = mix(col, float3(0.55,0.72,0.82), foam*0.35);
        return float4(gammaOut(col)*mask, mask);
    } else if (shape == 11) {               // soft expanding ripple crest
        float r = length(p);
        float d = (r - 0.82) / 0.15;
        float av = exp(-d*d) * in.color.a;   // gaussian ring, no hard edge
        return float4(gammaOut(in.color.rgb)*av, av);
    } else if (shape == 12) {               // grass / reed tuft (params.x = seed)
        float seed = in.params.x;
        float up = p.y*0.5 + 0.5;            // 0 base .. 1 tip
        float av = 0.0;
        for (int k = 0; k < 5; k++) {
            float fk = float(k);
            float root = (fk - 2.0) * 0.30 + 0.12*sin(seed*3.1 + fk);
            float lean = (0.10 + 0.18*fract(sin(seed+fk)*91.7)) * up;   // bends toward tip
            float bx = root + lean;
            float w  = 0.09 * (1.0 - up*0.75);                          // taper to a point
            float blade = smoothstep(w, 0.0, abs(p.x - bx));
            blade *= step(-0.95, p.y) * smoothstep(1.0, 0.15, p.y);
            av = max(av, blade);
        }
        if (av < 0.02) discard_fragment();
        float3 g = in.color.rgb * (0.6 + 0.55*up);   // dark base, bright tips
        return float4(gammaOut(g)*av, av);
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
    std::vector<Predator> _predators;
    std::vector<Nest> _nests;
    std::vector<Water> _water;
    std::vector<Ripple> _ripples;
    std::mt19937 _rng;
    int _initialPop;        // colony size at start, for growth %
    uint32_t _nextId;
    int _generation;
    int _births, _deaths;
    uint32_t _selected;
    bool _paused;
    float _timeScale;
    float _foodTimer;

    // Environment + evolutionary history.
    double _worldTime;      // accumulated sim seconds (drives seasons)
    float _climate;         // -1 cold .. +1 hot (current)
    float _climateTrend;    // slow-drifting climate baseline
    float _sampleTimer;
    int   _histCount, _histHead;
    float _histClim[kHistLen];  // all normalized 0..1 for plotting
    float _histSize[kHistLen];
    float _histDark[kHistLen];
    float _histRes[kHistLen];
    float _histPop[kHistLen];
    float _histPred[kHistLen];   // predator population (normalized)

    int _foodTarget;        // carrying-capacity target (set from the HUD)
    int _startPop;          // colony size at reset (HUD)
    float _lifespanMul;     // global multiplier on genetic lifespan (HUD)
    float _birthRate;       // reproduction multiplier: urge speed + litter size (HUD)

    // Sliding control panel + mouse widget state.
    std::vector<UIWidget> _widgets;
    float _panelT, _panelTarget;   // 0 hidden .. 1 shown
    int   _spliceGene;             // locus selected in the gene lab
    float _spliceExpr;             // engineered expression level 0..1
    bool  _showGraph;              // evolution graph visible?
    int   _dragAct;                // slider being dragged (WA_None if none)
    float _dragX, _dragW;
    int   _flashAct;               // last-clicked widget, for a click flash
    float _flashVal, _flashT;      // _flashT counts down (seconds)

    simd_float2 _uScale, _uOffset;
    double _startTime, _lastFrameTime, _simAccum;
    float _smoothedFPS;

    // Camera (zoom + pan) and world drag-to-pan / click-to-select state.
    float _zoom;                   // 1 = whole world in view
    simd_float2 _panCenter;        // world point held at screen center
    bool _worldDrag, _worldMoved;
    float _downPxX, _downPxY;
    simd_float2 _panAtDown, _downWorld;
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
        _hudBuffers[i] = [device newBufferWithLength:4096*sizeof(InstC)
                                             options:MTLResourceStorageModeShared];
    }
    _frameIndex = 0;
    _frameSemaphore = dispatch_semaphore_create(kMaxInFlight);
    _scratch.reserve(kMaxInstances);
    _hud.reserve(4096);
    // Reserve to the hard caps so births/food never reallocate the vectors
    // mid-simulation (which would invalidate the references we hold).
    _critters.reserve(kMaxCritters);
    _food.reserve(kMaxFood);
    _predators.reserve(kMaxPredators);
    _nests.reserve(kMaxNests);
    _water.reserve(kMaxWater);
    _ripples.reserve(kMaxRipples);

    _rng.seed(0xB10E);
    _nextId = 1;
    _selected = 0;
    _paused = NO;
    _timeScale = 1.0f;
    _widgets.reserve(64);
    _panelT = _panelTarget = 1.0f;   // start open so the controls are discoverable
    _spliceGene = GSize0;
    _spliceExpr = 0.9f;
    _showGraph = true;
    _dragAct = WA_None;
    _flashAct = WA_None;
    _flashVal = 0;
    _flashT = 0;
    _startPop = 24;
    _lifespanMul = 1.0f;
    _birthRate = 1.6f;
    _zoom = 1.0f;
    _panCenter = simd_make_float2(kWorldW*0.5f, kWorldH*0.5f);
    _worldDrag = false; _worldMoved = false;
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
        if (c == 43) { weakSelf->_climateTrend = std::max(weakSelf->_climateTrend-0.15f, -0.75f); return nil; } // , cool
        if (c == 47) { weakSelf->_climateTrend = std::min(weakSelf->_climateTrend+0.15f,  0.75f); return nil; } // . warm
        return e;
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                          handler:^NSEvent *(NSEvent *e) {
        if (!e.window) return e;
        MTKView *v = (MTKView *)e.window.contentView;
        if (![v isKindOfClass:[MTKView class]] || weakSelf->_uScale.x == 0) return e;
        NSPoint pt = [v convertPoint:e.locationInWindow fromView:nil];
        float bw = (float)v.bounds.size.width, bh = (float)v.bounds.size.height;
        // 1) HUD widgets first (topmost wins → iterate in reverse).
        if ([weakSelf hudMouseDown:simd_make_float2((float)pt.x,(float)pt.y) bw:bw bh:bh])
            return nil;
        // 2) world: begin a click/drag. A click selects on mouse-up; a drag pans.
        simd_float2 ndc = simd_make_float2((float)(pt.x/bw)*2.0f-1.0f,
                                           (float)(pt.y/bh)*2.0f-1.0f);
        weakSelf->_worldDrag = true;
        weakSelf->_worldMoved = false;
        weakSelf->_downPxX = (float)pt.x; weakSelf->_downPxY = (float)pt.y;
        weakSelf->_panAtDown = weakSelf->_panCenter;
        weakSelf->_downWorld = (ndc - weakSelf->_uOffset) / weakSelf->_uScale;
        return e;
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDragged
                                          handler:^NSEvent *(NSEvent *e) {
        if (!e.window) return e;
        MTKView *v = (MTKView *)e.window.contentView;
        if (![v isKindOfClass:[MTKView class]]) return e;
        NSPoint pt = [v convertPoint:e.locationInWindow fromView:nil];
        float bw = (float)v.bounds.size.width, bh = (float)v.bounds.size.height;
        if (weakSelf->_dragAct != WA_None) {                 // slider drag
            float frac = ((float)pt.x - weakSelf->_dragX) / std::max(weakSelf->_dragW, 1.0f);
            [weakSelf applySlider:weakSelf->_dragAct frac:std::clamp(frac,0.0f,1.0f)];
            return nil;
        }
        if (weakSelf->_worldDrag) {                          // pan the camera
            float dpx = (float)pt.x - weakSelf->_downPxX, dpy = (float)pt.y - weakSelf->_downPxY;
            if (fabsf(dpx) + fabsf(dpy) > 3.0f) weakSelf->_worldMoved = true;
            simd_float2 dndc = simd_make_float2(2.0f*dpx/bw, 2.0f*dpy/bh);
            simd_float2 dworld = dndc / weakSelf->_uScale;
            weakSelf->_panCenter = weakSelf->_panAtDown - dworld;
            [weakSelf clampPan];
            return nil;
        }
        return e;
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp
                                          handler:^NSEvent *(NSEvent *e) {
        weakSelf->_dragAct = WA_None;
        if (weakSelf->_worldDrag) {
            if (!weakSelf->_worldMoved) [weakSelf selectAt:weakSelf->_downWorld];  // a click
            weakSelf->_worldDrag = false;
        }
        return e;
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
                                          handler:^NSEvent *(NSEvent *e) {
        if (!e.window) return e;
        MTKView *v = (MTKView *)e.window.contentView;
        if (![v isKindOfClass:[MTKView class]] || weakSelf->_uScale.x == 0) return e;
        NSPoint pt = [v convertPoint:e.locationInWindow fromView:nil];
        float bw = (float)v.bounds.size.width, bh = (float)v.bounds.size.height;
        simd_float2 ndc = simd_make_float2((float)(pt.x/bw)*2.0f-1.0f,
                                           (float)(pt.y/bh)*2.0f-1.0f);
        float f = 1.0f + (float)e.scrollingDeltaY * 0.01f;   // scroll up = zoom in
        f = std::clamp(f, 0.5f, 1.6f);
        [weakSelf zoomBy:f atNdc:ndc];
        return nil;
    }];

    printf("=== BIOME v9 (birth rate + visible eyes) — if you don't see this line "
           "you're running an OLD BINARY (run: rm -rf build && make build/09-biome) ===\n"
           "New BIRTH RATE slider (urge speed + litter size) so the colony can grow.\n"
           "Bigger, vivid, heritable eye colors — zoom in to see them.\n");

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
    c.maturity = 9.0f;
    c.energy = 0.7f + 0.3f * u(_rng);
    c.hunger = 0.2f * u(_rng);
    c.thirst = 0.2f * u(_rng);
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

- (void)spawnPredator:(simd_float2)pos {
    if ((int)_predators.size() >= kMaxPredators) return;
    std::uniform_real_distribution<float> u(0,1);
    Predator p = {};
    p.pos = pos;
    p.vel = simd_make_float2(0,0);
    p.heading = u(_rng) * 6.28f;
    for (int i = 0; i < kSpineNodes; i++) p.spine[i] = pos;
    p.age = 0;
    p.lifespan = 90.0f + 40.0f * u(_rng);
    p.energy = 0.7f;
    p.size = 1.7f + 0.4f * u(_rng);      // larger than prey
    p.targetPrey = 0;
    p.cooldown = 0;
    p.phase = u(_rng) * 6.28f;
    p.alive = true;
    _predators.push_back(p);
}

- (void)cullPredators {
    _predators.clear();
}

// If something is moving across a pool, occasionally drop a ripple at its feet.
- (void)waterRippleAt:(simd_float2)pos vel:(simd_float2)vel dt:(float)dt {
    if (simd_length(vel) < 1.2f) return;
    std::uniform_real_distribution<float> u(0,1);
    for (const Water &wp : _water)
        if (simd_distance(pos, wp.pos) < wp.radius) {
            if (u(_rng) < 2.4f * dt && (int)_ripples.size() < kMaxRipples) {
                Ripple rp;
                rp.pos = pos + simd_make_float2((u(_rng)-0.5f)*0.7f, (u(_rng)-0.5f)*0.7f);
                rp.age = 0; rp.life = 1.8f;
                _ripples.push_back(rp);
            }
            return;
        }
}

// Empty the world of animals and nests (leaves the food and climate history),
// so you can start from nothing or hand-place critters with ADD.
- (void)clearColony {
    _critters.clear();
    _predators.clear();
    _nests.clear();
    _selected = 0;
}

// ----------------------------------------------------------------- Camera ---

- (void)clampPan {
    // Keep the view over the world: allowable pan grows with zoom, so at fit
    // zoom the center stays put and you can never drag the world off-screen.
    float rx = kWorldW * 0.5f * std::max(0.0f, 1.0f - 1.0f/_zoom);
    float ry = kWorldH * 0.5f * std::max(0.0f, 1.0f - 1.0f/_zoom);
    _panCenter.x = std::clamp(_panCenter.x, kWorldW*0.5f - rx, kWorldW*0.5f + rx);
    _panCenter.y = std::clamp(_panCenter.y, kWorldH*0.5f - ry, kWorldH*0.5f + ry);
}

// Zoom by factor f, keeping the world point under `ndc` fixed on screen.
- (void)zoomBy:(float)f atNdc:(simd_float2)ndc {
    if (_uScale.x == 0) { _zoom = std::clamp(_zoom * f, 1.0f, 8.0f); return; }
    float oldZoom = _zoom;
    _zoom = std::clamp(_zoom * f, 1.0f, 8.0f);
    simd_float2 scaleNew = _uScale * (_zoom / oldZoom);
    simd_float2 worldC = _panCenter + ndc / _uScale;      // world point under cursor
    _panCenter = worldC - ndc / scaleNew;                 // hold it there
    [self clampPan];
}

- (void)resetColony {
    _critters.clear();
    _food.clear();
    _predators.clear();
    _nests.clear();
    _ripples.clear();
    _generation = 0;
    _births = _deaths = 0;
    _selected = 0;
    _worldTime = 0;
    _climate = 0;
    _climateTrend = 0;
    _sampleTimer = 0;
    _histCount = _histHead = 0;
    _foodTarget = 320;
    // A few water pools scattered around the world.
    _water.clear();
    std::uniform_real_distribution<float> ur(0,1);
    int nPools = 2 + (int)(ur(_rng) * 2.5f);   // 2..4
    for (int i = 0; i < nPools; i++) {
        Water wtr; wtr.pos = [self randomPos]; wtr.radius = 4.0f + 4.0f * ur(_rng);
        _water.push_back(wtr);
    }
    for (int i = 0; i < _startPop; i++)
        [self spawnCritter:randomGenome(_rng, i % 2) at:[self randomPos] gen:0];
    [self scatterFood:220];
    if (_startPop > 0)
        for (int i = 0; i < 2; i++) [self spawnPredator:[self randomPos]];
    _initialPop = (int)_critters.size();
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

// Index of the nest owned by `owner`, creating one at `pos` if she has none.
- (int)nestForOwner:(uint32_t)owner at:(simd_float2)pos {
    for (size_t i = 0; i < _nests.size(); i++)
        if (_nests[i].alive && _nests[i].owner == owner) return (int)i;
    if ((int)_nests.size() >= kMaxNests) return -1;
    // Keep nests off the water — nudge to the nearest dry shore if needed.
    for (const Water &wp : _water) {
        float d = simd_distance(pos, wp.pos);
        if (d < wp.radius + 1.2f) {
            simd_float2 dir = d > 1e-3f ? (pos - wp.pos) / d : simd_make_float2(1,0);
            pos = wp.pos + dir * (wp.radius + 1.5f);
        }
    }
    Nest n; n.pos = pos; n.owner = owner; n.quality = 0.12f; n.alive = true;
    _nests.push_back(n);
    return (int)_nests.size() - 1;
}

// -------------------------------------------------------------------- Sim ---

- (void)simStep:(float)dt {
    std::uniform_real_distribution<float> u(0,1);

    // --- climate: gentle seasons over a slowly wandering baseline ---
    _worldTime += dt;
    _climateTrend += (u(_rng) - 0.5f) * 0.03f * dt;      // slow random walk
    _climateTrend = std::clamp(_climateTrend, -0.75f, 0.75f);
    float season = sinf((float)_worldTime * (6.2831853f / kSeasonSecs));
    _climate = std::clamp(0.35f * season + _climateTrend, -1.0f, 1.0f);

    // Food regrows / seeds slowly toward a carrying capacity.
    for (Food &f : _food) if (f.alive) f.growth = std::min(f.growth + 0.20f * dt, 1.0f);
    _foodTimer -= dt;
    if (_foodTimer <= 0 && (int)_food.size() < _foodTarget) {
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
        c.thirst = std::min(c.thirst + (0.014f + ph.metabolism*0.016f
                                        + std::max(_climate,0.0f)*0.02f) * dt, 1.5f);
        if (c.thirst > 1.2f) c.energy -= (c.thirst - 1.2f) * 0.10f * dt;   // dehydration
        float moving = simd_length(c.vel) / std::max(ph.speed, 0.1f);
        c.energy -= (0.01f + ph.metabolism * 0.012f + 0.02f * moving) * dt;
        if (c.hunger > 0.9f) c.energy -= (c.hunger - 0.9f) * 0.15f * dt;   // starving
        // Thermal stress: bodies ill-matched to the climate burn extra energy,
        // so they forage harder, breed less, and die younger — selection that
        // pushes the colony's size and coloration to track the environment.
        float adapt = adaptation(ph, _climate);
        c.energy -= (1.0f - adapt) * kThermalCost * dt;
        if (c.age > c.maturity && c.energy > 0.45f && !c.pregnant)
            c.urge = std::min(c.urge + ph.fertility * (0.5f + 0.7f * adapt)
                                       * 0.085f * _birthRate * dt, 1.0f);

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
        if (c.age > ph.lifespan * _lifespanMul || c.energy <= 0 || c.health <= 0) {
            c.alive = false; _deaths++;
            if (c.id == _selected) _selected = 0;
            continue;
        }

        // --- nest shelter status (cover from predators) ---
        c.sheltered = false;
        for (const Nest &nst : _nests)
            if (nst.alive && simd_distance(nst.pos, c.pos) < kNestRadius) { c.sheltered = true; break; }

        // --- detect predators (sharper-eyed critters see them sooner) ---
        simd_float2 threatDir = simd_make_float2(0,0);
        float threatLvl = 0.0f;
        for (const Predator &pr : _predators) {
            if (!pr.alive) continue;
            float dd = simd_distance(pr.pos, c.pos);
            if (dd < ph.sensory) {
                float near = 1.0f - dd / ph.sensory;
                if (near > threatLvl) { threatLvl = near; threatDir = c.pos - pr.pos; }
            }
        }

        // --- utility AI: pick the most pressing drive ---
        float sForage = c.hunger;
        float sRest = (1.0f - c.energy) * 0.9f;
        float sMate = (c.age > c.maturity && c.energy > 0.45f && !c.pregnant) ? c.urge : 0.0f;
        float sWander = 0.15f;
        float sFlee = threatLvl * 2.0f;              // survival trumps everything
        float sNest = c.pregnant ? 0.8f : 0.0f;      // expectant mothers nest
        float sDrink = _water.empty() ? 0.0f : std::max(0.0f, c.thirst - 0.45f) * 2.2f;
        c.action = AWander;
        float best = sWander;
        if (sForage > best) { best = sForage; c.action = AForage; }
        if (sDrink > best)  { best = sDrink;  c.action = ADrink; }
        if (sRest > best)   { best = sRest;   c.action = ARest; }
        if (sMate > best)   { best = sMate;   c.action = AMate; }
        if (sNest > best)   { best = sNest;   c.action = ANest; }
        if (sFlee > best)   { best = sFlee;   c.action = AFlee; }

        // --- act ---
        simd_float2 desire = simd_make_float2(0,0);
        float wantSpeed = ph.speed;
        if (c.action == AFlee) {
            desire = (simd_length(threatDir) > 1e-3f) ? simd_normalize(threatDir)
                        : simd_make_float2(cosf(c.heading), sinf(c.heading));
            wantSpeed = ph.speed * 1.6f;      // panic sprint
            c.energy -= 0.02f * dt;           // burns energy
        } else if (c.action == AForage) {
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
                    c.energy = std::min(c.energy + _food[fi].growth * 0.7f, 1.0f);
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
                c.targetMate = 0;
                if (!c.male) {
                    // Female choice: pick the showiest male within sight (weighted
                    // toward nearer ones). Sexual selection on ornament genes.
                    float bestScore = 0.0f;
                    for (Critter &o : _critters) {
                        if (!o.alive || o.male == c.male) continue;
                        if (o.age <= o.maturity || o.energy < 0.4f) continue;
                        float dd = simd_distance(o.pos, c.pos);
                        if (dd > ph.sensory) continue;
                        float score = ornament(o) * (1.0f - 0.5f * dd / ph.sensory);
                        if (score > bestScore) { bestScore = score; c.targetMate = o.id; }
                    }
                } else {
                    // Males court the nearest receptive female.
                    float bd = ph.sensory;
                    for (Critter &o : _critters) {
                        if (!o.alive || o.male == c.male) continue;
                        if (o.age <= o.maturity || o.energy < 0.4f) continue;
                        float dd = simd_distance(o.pos, c.pos);
                        if (dd < bd) { bd = dd; c.targetMate = o.id; }
                    }
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
                        mom->mateGenome = dad->genome;   // for litter-mate meiosis
                        mom->pregnant = true;
                        mom->gestation = 5.0f;
                        mom->urge = 0; dad->urge = 0;
                        mom->energy -= 0.12f; dad->energy -= 0.06f;
                    }
                } else desire = to / std::max(dd, 1e-3f);
            } else { wantSpeed *= 0.6f; desire = simd_make_float2(cosf(c.heading), sinf(c.heading)); }
        } else if (c.action == ANest) {
            // Expectant mother: head to her nest (build a new one if she has
            // none) and tend it — a better nest gives her pups a head start.
            int ni = [self nestForOwner:c.id at:c.pos];
            if (ni >= 0) {
                Nest &nst = _nests[ni];
                simd_float2 to = nst.pos - c.pos;
                float dd = simd_length(to);
                if (dd < kNestRadius * 0.5f) {
                    nst.quality = std::min(nst.quality + 0.06f * dt, 1.0f);
                    wantSpeed = 0.0f;
                    c.energy = std::min(c.energy + 0.03f * dt, 1.0f);
                } else desire = to / std::max(dd, 1e-3f);
            } else { wantSpeed *= 0.5f; desire = simd_make_float2(cosf(c.heading), sinf(c.heading)); }
        } else if (c.action == ADrink) {
            // Head to the nearest pool and drink at its shore.
            int wi = -1; float bd = 1e9f;
            for (int k = 0; k < (int)_water.size(); k++) {
                float dd = simd_distance(_water[k].pos, c.pos);
                if (dd < bd) { bd = dd; wi = k; }
            }
            if (wi >= 0) {
                simd_float2 to = _water[wi].pos - c.pos;
                float dd = simd_length(to);
                if (dd < _water[wi].radius + 0.8f) {       // drinking
                    c.thirst = std::max(c.thirst - 1.2f * dt, 0.0f);
                    wantSpeed = 0.0f;
                } else desire = to / std::max(dd, 1e-3f);
            } else { wantSpeed *= 0.5f; desire = simd_make_float2(cosf(c.heading), sinf(c.heading)); }
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
        [self waterRippleAt:c.pos vel:c.vel dt:dt];
        c.phase += (0.5f + simd_length(c.vel) * 0.5f) * dt * 6.0f;

        // --- Verlet spine follows the head (elongated bodies stretch it) ---
        c.spine[0] = c.pos;
        float link = 0.40f * ph.size * (0.75f + 0.7f * ph.aspect);
        for (int s = 1; s < kSpineNodes; s++) {
            simd_float2 dir = c.spine[s] - c.spine[s-1];
            float dl = simd_length(dir);
            if (dl > 1e-4f) c.spine[s] = c.spine[s-1] + dir / dl * link;
            // lateral slither offset
            simd_float2 perp = simd_make_float2(-sinf(c.heading), cosf(c.heading));
            c.spine[s] += perp * sinf(c.phase - s * 0.9f) * 0.06f * ph.size
                        * simd_length(c.vel) / std::max(ph.speed,1.0f);
        }

        // --- gestation / birth (at the nest, with a quality-scaled head start) ---
        if (c.pregnant) {
            c.gestation -= dt;
            if (c.gestation <= 0) {
                int gen = c.generation + 1;
                simd_float2 bpos = c.pos;
                float bonus = 0.0f;
                int ni = [self nestForOwner:c.id at:c.pos];
                if (ni >= 0) { bpos = _nests[ni].pos; bonus = 0.20f * _nests[ni].quality; }
                int litter = std::max(1, (int)lroundf(_birthRate));   // pups this birth
                for (int L = 0; L < litter; L++) {
                    Genome kid = (L == 0) ? c.unborn
                                          : breed(c.genome, c.mateGenome, _rng);  // distinct sibling
                    size_t before = _critters.size();
                    [self spawnCritter:kid
                                    at:(bpos + simd_make_float2(u(_rng)-0.5f, u(_rng)-0.5f)) gen:gen];
                    if (_critters.size() > before)
                        _critters.back().energy = std::min(_critters.back().energy + bonus, 1.0f);
                    _births++;
                }
                _generation = std::max(_generation, gen);
                c.pregnant = false;
            }
        }
    }

    // --- nests decay when untended; remove the empty ones ---
    for (Nest &nst : _nests) if (nst.alive) {
        nst.quality -= 0.012f * dt;
        if (nst.quality <= 0.0f) nst.alive = false;
    }
    _nests.erase(std::remove_if(_nests.begin(), _nests.end(),
                 [](const Nest &n){ return !n.alive; }), _nests.end());

    // --- age water ripples and drop the faded ones ---
    for (Ripple &rp : _ripples) rp.age += dt;
    _ripples.erase(std::remove_if(_ripples.begin(), _ripples.end(),
                   [](const Ripple &rp){ return rp.age >= rp.life; }), _ripples.end());

    // --- predators: hunt prey; numbers rise and fall with the prey supply ---
    float groundLuma = 0.24f + 0.06f * _climate;   // grass tone by climate
    for (size_t i = 0; i < _predators.size(); i++) {
        Predator &p = _predators[i];
        if (!p.alive) continue;
        p.age += dt;
        p.cooldown = std::max(p.cooldown - dt, 0.0f);
        p.energy -= 0.022f * dt;                    // metabolism
        if (p.age > p.lifespan || p.energy <= 0.0f) { p.alive = false; continue; }

        float sight = 22.0f;
        // Re-acquire a target if the current one is gone.
        Critter *prey = [self critterById:p.targetPrey];
        if (!prey) {
            float bestD = 1e9f;
            for (Critter &o : _critters) {
                if (!o.alive) continue;
                float dd = simd_distance(o.pos, p.pos);
                // Camouflaged coats (matching the ground) are spotted only up
                // close; conspicuous / vivid ones — the ones mates prefer — are
                // seen from far off. Nests offer cover.
                float contrast = fabsf(coatLuma(o.ph.color) - groundLuma);
                float visRange = sight * (0.35f + 1.3f * std::clamp(contrast,0.0f,1.0f)
                                          + 0.5f * coatVividness(o.ph.color));
                if (o.sheltered) visRange *= 0.55f;
                if (dd < visRange && dd < bestD) { bestD = dd; p.targetPrey = o.id; }
            }
            prey = [self critterById:p.targetPrey];
        }

        simd_float2 desire = simd_make_float2(0,0);
        float wantSpeed = 8.6f;                      // fast prey can outrun it
        if (prey) {
            simd_float2 to = prey->pos - p.pos;
            float d = simd_length(to);
            float catchR = 0.9f + p.size * 0.3f + prey->ph.size * 0.3f;
            if (d < catchR) {
                if (p.cooldown <= 0.0f) {             // kill
                    prey->alive = false; _deaths++;
                    if (prey->id == _selected) _selected = 0;
                    p.energy = std::min(p.energy + 0.5f, 1.4f);
                    p.cooldown = 1.6f;
                    p.targetPrey = 0;
                }
            } else desire = to / std::max(d, 1e-3f);
        } else {
            p.heading += (u(_rng) - 0.5f) * 1.4f * dt;
            desire = simd_make_float2(cosf(p.heading), sinf(p.heading));
            wantSpeed *= 0.45f;                       // patrol slowly
        }

        // Well-fed adults bud off a new predator (asexual, for simplicity).
        if (p.energy > 1.05f && p.age > 14.0f && (int)_predators.size() < kMaxPredators) {
            [self spawnPredator:(p.pos + simd_make_float2(u(_rng)-0.5f, u(_rng)-0.5f))];
            p.energy -= 0.6f;
        }

        simd_float2 wantVel = (simd_length(desire) > 1e-3f)
            ? simd_normalize(desire) * wantSpeed : simd_make_float2(0,0);
        p.vel += (wantVel - p.vel) * std::min(3.5f * dt, 1.0f);
        if (simd_length(p.vel) > 0.05f) p.heading = atan2f(p.vel.y, p.vel.x);
        p.pos += p.vel * dt;
        p.pos.x = std::clamp(p.pos.x, 1.0f, kWorldW - 1.0f);
        p.pos.y = std::clamp(p.pos.y, 1.0f, kWorldH - 1.0f);
        [self waterRippleAt:p.pos vel:p.vel dt:dt];
        p.phase += (0.5f + simd_length(p.vel) * 0.4f) * dt * 6.0f;
        p.spine[0] = p.pos;
        float plink = 0.55f * p.size;
        for (int s = 1; s < kSpineNodes; s++) {
            simd_float2 dir = p.spine[s] - p.spine[s-1];
            float dl = simd_length(dir);
            if (dl > 1e-4f) p.spine[s] = p.spine[s-1] + dir / dl * plink;
            simd_float2 perp = simd_make_float2(-sinf(p.heading), cosf(p.heading));
            p.spine[s] += perp * sinf(p.phase - s * 0.9f) * 0.05f * p.size
                        * simd_length(p.vel) / 9.0f;
        }
    }
    _predators.erase(std::remove_if(_predators.begin(), _predators.end(),
                     [](const Predator &p){ return !p.alive; }), _predators.end());

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
    if (!_critters.empty() && u(_rng) < 0.01f * dt * _critters.size()) {
        Critter &c = _critters[_rng() % _critters.size()];
        if (c.alive && c.sick == 0) c.sick = 0.2f;
    }

    // compact dead
    _critters.erase(std::remove_if(_critters.begin(), _critters.end(),
                    [](const Critter &c){ return !c.alive; }), _critters.end());
    _food.erase(std::remove_if(_food.begin(), _food.end(),
                [](const Food &f){ return !f.alive; }), _food.end());

    // --- sample colony averages for the evolution graph ---
    _sampleTimer -= dt;
    if (_sampleTimer <= 0) {
        _sampleTimer = kSampleSecs;
        float ss = 0, dd = 0, rr = 0; int n = 0;
        for (const Critter &c : _critters) {
            ss += std::clamp((c.ph.size - 0.6f) / 1.1f, 0.0f, 1.0f);
            dd += 1.0f - coatLuma(c.ph.color);
            rr += c.ph.resistance;
            n++;
        }
        if (n) { ss /= n; dd /= n; rr /= n; }
        int i = _histHead;
        _histClim[i] = _climate * 0.5f + 0.5f;
        _histSize[i] = ss;
        _histDark[i] = dd;
        _histRes[i]  = rr;
        _histPop[i]  = std::min(n / (float)kMaxCritters * 3.0f, 1.0f);
        _histPred[i] = std::min((int)_predators.size() / 40.0f, 1.0f);
        _histHead = (i + 1) % kHistLen;
        if (_histCount < kHistLen) _histCount++;
    }
}

// ---------------------------------------------------------------- Render ---

- (void)push:(simd_float2)c half:(simd_float2)h rot:(float)rot shape:(float)s
       color:(simd_float4)col p:(simd_float4)pr {
    if ((int)_scratch.size() >= kMaxInstances) return;
    _scratch.push_back({c.x,c.y,h.x,h.y,rot,s, col.x,col.y,col.z,col.w, pr.x,pr.y,pr.z,pr.w});
}
- (void)hud:(float)cx cy:(float)cy hw:(float)hw hh:(float)hh shape:(float)s
      color:(simd_float4)col p0:(float)p0 {
    if (_hud.size() >= 4096) return;
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

// Draw a text string (A-Z, 0-9) from the bitmap font, left-aligned at (x,y).
- (void)hudText:(const char *)s x:(float)x y:(float)y h:(float)h
            col:(simd_float4)col bw:(float)bw bh:(float)bh {
    float gw = h * 0.62f, adv = gw + h * 0.30f;
    for (const char *p = s; *p; ++p) {
        char ch = *p; int code = -1;
        if (ch >= '0' && ch <= '9') code = ch - '0';
        else if (ch >= 'A' && ch <= 'Z') code = 10 + (ch - 'A');
        else if (ch >= 'a' && ch <= 'z') code = 10 + (ch - 'a');
        else if (ch == '+') code = 36;
        else if (ch == '-') code = 37;
        else if (ch == '.') code = 38;
        else if (ch == '%') code = 39;
        if (code >= 0) {
            float cx = (x + gw*0.5f)/bw*2.0f-1.0f, cy = (y + h*0.5f)/bh*2.0f-1.0f;
            [self hud:cx cy:cy hw:gw/bw hh:h/bh shape:8 color:col p0:(float)code];
        }
        x += adv;
    }
}

// -------------------------------------------------------------- Gene lab ---

// Craft a synthetic allele of a chosen expression level that is always
// DOMINANT (its dominance region is packed with G/T), so a spliced gene
// visibly takes over the phenotype and then spreads through the gene pool.
- (uint32_t)engineerAllele:(float)expr {
    int k = (int)lroundf(std::clamp(expr, 0.0f, 1.0f) * 16.0f);
    uint32_t g = 0; int gc = 0;
    for (int i = 0; i < 16; i++) {
        bool wantGC = gc < k;
        int b = (i >= 8) ? (wantGC ? 2 : 3)     // dominance region: G (GC) or T
                         : (wantGC ? 1 : 0);     // value region:    C (GC) or A
        if (b == 1 || b == 2) gc++;
        g |= ((uint32_t)b) << (2 * i);
    }
    return g;
}

// Introduce n engineered individuals homozygous for the spliced allele.
- (void)spliceGene:(int)gene expr:(float)expr count:(int)n {
    uint32_t allele = [self engineerAllele:expr];
    for (int i = 0; i < n && (int)_critters.size() < kMaxCritters; i++) {
        Genome g = randomGenome(_rng, i % 2);
        g.hom[0][gene] = allele;
        g.hom[1][gene] = allele;
        [self spawnCritter:g at:[self randomPos] gen:_generation];
    }
}

// ------------------------------------------------------------ HUD input ---

- (void)applySlider:(int)act frac:(float)f {
    if (act == WA_ClimateSlider) _climateTrend = f * 1.5f - 0.75f;
    else if (act == WA_ExprSlider) _spliceExpr = std::clamp(f, 0.0f, 1.0f);
    else if (act == WA_FoodSlider) _foodTarget = (int)(40.0f + f * 460.0f);
    else if (act == WA_StartPopSlider) _startPop = (int)(f * 120.0f);          // 0..120
    else if (act == WA_LifespanSlider) _lifespanMul = 0.4f + f * 2.1f;          // 0.4x..2.5x
    else if (act == WA_BirthRateSlider) _birthRate = 0.5f + f * 3.0f;           // 0.5x..3.5x
}

- (BOOL)hudMouseDown:(simd_float2)pt bw:(float)bw bh:(float)bh {
    for (int i = (int)_widgets.size() - 1; i >= 0; i--) {
        UIWidget &wg = _widgets[i];
        if (pt.x < wg.x || pt.x > wg.x+wg.w || pt.y < wg.y || pt.y > wg.y+wg.h) continue;
        _flashAct = wg.act; _flashVal = wg.val; _flashT = 0.30f;   // click feedback
        switch (wg.act) {
            case WA_Toggle:    _panelTarget = (_panelTarget > 0.5f) ? 0.0f : 1.0f; break;
            case WA_Pause:     _paused = !_paused; break;
            case WA_SpeedDn:   _timeScale = std::max(_timeScale*0.5f, 0.25f); break;
            case WA_SpeedUp:   _timeScale = std::min(_timeScale*2.0f, 8.0f); break;
            case WA_Food:      [self scatterFood:60]; break;
            case WA_Introduce: [self introduceRandom]; break;
            case WA_Cull:      [self cullSelected]; break;
            case WA_Reset:     [self resetColony]; break;
            case WA_TraitPick: _spliceGene = (int)wg.val; break;
            case WA_Splice:    [self spliceGene:_spliceGene expr:_spliceExpr count:4]; break;
            case WA_ToggleGraph: _showGraph = !_showGraph; break;
            case WA_AddPredator: [self spawnPredator:[self randomPos]]; break;
            case WA_CullPredators: [self cullPredators]; break;
            case WA_ClearColony: [self clearColony]; break;
            case WA_ZoomIn:    [self zoomBy:1.4f atNdc:simd_make_float2(0,0)]; break;
            case WA_ZoomOut:   [self zoomBy:1.0f/1.4f atNdc:simd_make_float2(0,0)]; break;
            case WA_ResetView: _zoom = 1.0f;
                               _panCenter = simd_make_float2(kWorldW*0.5f, kWorldH*0.5f); break;
            case WA_ClimateSlider:
            case WA_ExprSlider:
            case WA_FoodSlider:
            case WA_StartPopSlider:
            case WA_LifespanSlider:
            case WA_BirthRateSlider:
                _dragAct = wg.act; _dragX = wg.x; _dragW = wg.w;
                [self applySlider:wg.act
                             frac:std::clamp((pt.x-wg.x)/std::max(wg.w,1.0f), 0.0f, 1.0f)];
                break;
            default: break;
        }
        return YES;
    }
    // Click landed on the open panel but missed every widget: swallow it so it
    // doesn't select a critter hidden behind the panel.
    float panelX = bw - 300.0f * _panelT;
    return (_panelT > 0.5f && pt.x >= panelX) ? YES : NO;
}

// Sliding control panel: every environmental knob and the gene lab, all
// mouse-driven. Rebuilt each frame; widgets are registered for hit-testing.
- (void)buildControlPanel:(float)bw bh:(float)bh {
    auto rect = [&](float x, float y, float w, float h, simd_float4 c, float s) {
        float cx = (x+w*0.5f)/bw*2.0f-1.0f, cy = (y+h*0.5f)/bh*2.0f-1.0f;
        [self hud:cx cy:cy hw:w/bw hh:h/bh shape:s color:c p0:0];
    };
    auto text = [&](float x, float y, const char *t, float h, simd_float4 c) {
        [self hudText:t x:x y:y h:h col:c bw:bw bh:bh];
    };
    const float panW = 300, tabW = 30;
    float panelX = bw - panW * _panelT;

    // Tab handle (always present, even when the panel is hidden).
    float tabH = 76, tabX = panelX - tabW, tabY = bh*0.5f - tabH*0.5f;
    rect(tabX, tabY, tabW, tabH, simd_make_float4(0.10f,0.12f,0.16f,0.96f), 6);
    for (int i = 0; i < 3; i++)
        rect(tabX+9, tabY+tabH*0.5f-7+i*6, tabW-18, 2.5f, simd_make_float4(0.75f,0.85f,1.0f,1), 4);
    _widgets.push_back({tabX, tabY, tabW, tabH, WA_Toggle, 0});

    if (_panelT < 0.02f) return;
    bool live = _panelT > 0.5f;

    rect(panelX, 0, panW, bh, simd_make_float4(0.05f,0.06f,0.09f,0.95f), 4);
    rect(panelX, 0, 2, bh, simd_make_float4(0.30f,0.55f,0.80f,0.7f), 4);

    float x0 = panelX + 16, cw = panW - 32;
    simd_float4 cLabel = simd_make_float4(0.55f,0.68f,0.85f,1);
    simd_float4 cTxt   = simd_make_float4(0.92f,0.95f,1.0f,1);
    std::vector<UIWidget> &widgets = _widgets;
    int flashAct = _flashAct; float flashVal = _flashVal, flashT = _flashT;

    auto button = [&](float x, float y, float w, float h, const char *t,
                      int act, float val, bool hot) {
        simd_float4 bg = hot ? simd_make_float4(0.18f,0.42f,0.62f,1)
                             : simd_make_float4(0.14f,0.17f,0.22f,1);
        // Momentary click flash: light up and fade back over ~0.3s.
        if (flashT > 0.0f && act == flashAct && val == flashVal) {
            simd_float4 hi = simd_make_float4(0.45f,0.85f,1.0f,1.0f);
            bg = bg + (hi - bg) * (flashT / 0.30f);
        }
        rect(x, y, w, h, bg, 6);
        float gh = h*0.5f, adv = gh*0.62f + gh*0.30f;
        float tw = (float)strlen(t) * adv - gh*0.30f;
        text(x + std::max((w-tw)*0.5f, 3.0f), y + (h-gh)*0.5f, t, gh, cTxt);
        if (live) widgets.push_back({x, y, w, h, act, val});
    };
    auto slider = [&](float x, float y, float w, float h, float frac, int act) {
        frac = std::clamp(frac, 0.0f, 1.0f);
        rect(x, y, w, h, simd_make_float4(0.12f,0.14f,0.18f,1), 6);
        rect(x, y, w*frac, h, simd_make_float4(0.28f,0.52f,0.78f,1), 6);
        rect(x + frac*w - 4, y-3, 8, h+6, simd_make_float4(0.9f,0.95f,1.0f,1), 6);
        if (live) widgets.push_back({x, y, w, h, act, 0});
    };

    float cy = bh - 22;
    auto row = [&](float h, float gap) { cy -= h; float y = cy; cy -= gap; return y; };

    text(x0, row(18,12), "CONTROLS", 18, simd_make_float4(0.85f,0.92f,1.0f,1));

    // --- TIME ---
    text(x0, row(11,5), "TIME", 11, cLabel);
    {
        float y = row(26,6);
        button(x0, y, 96, 26, _paused ? "PLAY" : "PAUSE", WA_Pause, 0, _paused);
        button(x0+cw-84, y, 40, 26, "-", WA_SpeedDn, 0, false);
        button(x0+cw-40, y, 40, 26, "+", WA_SpeedUp, 0, false);
    }
    {
        float y = row(8,14);
        int idx = (int)lroundf(log2f(std::max(_timeScale,0.25f)) + 2.0f);  // 0..5
        float segW = (cw - 5*4) / 6.0f;
        for (int k = 0; k < 6; k++)
            rect(x0 + k*(segW+4), y, segW, 8,
                 (k <= idx) ? simd_make_float4(0.30f,0.60f,0.85f,1)
                            : simd_make_float4(0.16f,0.18f,0.22f,1), 6);
    }

    // --- VIEW (zoom) ---
    text(x0, row(11,5), "VIEW", 11, cLabel);
    {
        float y = row(24,14), w = (cw-8)/3.0f;
        button(x0, y, w, 24, "ZOOM-", WA_ZoomOut, 0, false);
        button(x0+(w+4), y, w, 24, "ZOOM+", WA_ZoomIn, 0, false);
        button(x0+2*(w+4), y, w, 24, "FIT", WA_ResetView, 0, false);
    }

    // --- CLIMATE ---
    text(x0, row(11,5), "CLIMATE", 11, cLabel);
    slider(x0, row(18,5), cw, 18, (_climateTrend+0.75f)/1.5f, WA_ClimateSlider);
    {
        const char *band = _climate<-0.33f ? "COLD" : (_climate>0.33f ? "HOT" : "TEMPERATE");
        text(x0, row(11,14), band, 11, cTxt);
    }

    // --- FOOD ---
    text(x0, row(11,5), "FOOD", 11, cLabel);
    button(x0, row(26,6), cw, 26, "SCATTER FOOD", WA_Food, 0, false);
    text(x0, row(10,3), "ABUNDANCE", 10, cLabel);
    slider(x0, row(18,14), cw, 18, (_foodTarget-40)/460.0f, WA_FoodSlider);

    // --- POPULATION ---
    text(x0, row(11,5), "POPULATION", 11, cLabel);
    {
        float y = row(24,14), w = (cw-12)/4.0f;
        button(x0, y, w, 24, "ADD", WA_Introduce, 0, false);
        button(x0+(w+4), y, w, 24, "CULL", WA_Cull, 0, false);
        button(x0+2*(w+4), y, w, 24, "RESET", WA_Reset, 0, false);
        button(x0+3*(w+4), y, w, 24, "CLEAR", WA_ClearColony, 0, false);
    }

    // --- LIFE (start population + lifespan multiplier) ---
    {
        float y = row(11,5);
        text(x0, y, "START POP", 11, cLabel);
        [self hudNumber:_startPop x:x0+cw-46 y:y dw:5 dh:9 col:cTxt bw:bw bh:bh];
    }
    slider(x0, row(18,10), cw, 18, _startPop/120.0f, WA_StartPopSlider);
    {
        float y = row(11,5);
        text(x0, y, "LIFESPAN PCT", 11, cLabel);
        [self hudNumber:(int)(_lifespanMul*100.0f) x:x0+cw-46 y:y dw:5 dh:9 col:cTxt bw:bw bh:bh];
    }
    slider(x0, row(18,10), cw, 18, (_lifespanMul-0.4f)/2.1f, WA_LifespanSlider);
    {
        float y = row(11,5);
        text(x0, y, "BIRTH RATE PCT", 11, cLabel);
        [self hudNumber:(int)(_birthRate*100.0f) x:x0+cw-52 y:y dw:5 dh:9 col:cTxt bw:bw bh:bh];
    }
    slider(x0, row(18,12), cw, 18, (_birthRate-0.5f)/3.0f, WA_BirthRateSlider);

    // --- PREDATORS ---
    text(x0, row(11,5), "PREDATORS", 11, cLabel);
    {
        float y = row(26,14), w = (cw-4)/2.0f;
        button(x0, y, w, 26, "ADD HUNTER", WA_AddPredator, 0, false);
        button(x0+w+4, y, w, 26, "REMOVE ALL", WA_CullPredators, 0, false);
    }

    // --- GENE LAB ---
    text(x0, row(12,6), "SPLICE GENE", 12, simd_make_float4(0.70f,0.92f,0.66f,1));
    {
        float bwid = (cw-6)/2.0f, bhei = 22;
        int rows = (kNumTraitBtns + 1) / 2;
        for (int r = 0; r < rows; r++) {
            float y = row(bhei, 4);
            for (int c2 = 0; c2 < 2; c2++) {
                int i = r*2 + c2;
                if (i >= kNumTraitBtns) break;
                button(x0 + c2*(bwid+6), y, bwid, bhei, kTraits[i].name,
                       WA_TraitPick, (float)kTraits[i].gene,
                       kTraits[i].gene == _spliceGene);
            }
        }
    }
    text(x0, row(10,3), "EXPRESSION", 10, cLabel);
    slider(x0, row(18,8), cw, 18, _spliceExpr, WA_ExprSlider);
    button(x0, row(28,8), cw, 28, "SPLICE INTO COLONY", WA_Splice, 0, false);
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
    _panelT += (_panelTarget - _panelT) * std::min(1.0f, 12.0f * dtRaw);  // slide
    if (_flashT > 0) _flashT = std::max(0.0f, _flashT - dtRaw);           // click flash fades

    if (!_paused) {
        _simAccum += std::min(dtRaw * _timeScale, 0.5f);
        const double step = 1.0/60.0;
        int guard = 0;
        while (_simAccum >= step && guard++ < 40) { [self simStep:(float)step]; _simAccum -= step; }
    }

    float aspect = (float)(view.drawableSize.width / view.drawableSize.height);
    float s = std::min(2.0f*aspect/kWorldW, 2.0f/kWorldH) * 0.96f * _zoom;
    _uScale = simd_make_float2(s/aspect, s);
    _uOffset = simd_make_float2(-_panCenter.x * (s/aspect), -_panCenter.y * s);

    struct { simd_float2 scale, offset, resolution; float time, pad; } uni = {
        _uScale, _uOffset,
        simd_make_float2((float)view.drawableSize.width, (float)view.drawableSize.height), t,
        _climate
    };

    dispatch_semaphore_wait(_frameSemaphore, DISPATCH_TIME_FOREVER);
    _scratch.clear();
    _hud.clear();

    // water pools (lowest layer): one animated water sprite per pool
    for (const Water &wp : _water) {
        float seed = wp.pos.x*0.7f + wp.pos.y*1.3f;
        [self push:wp.pos half:simd_make_float2(wp.radius, wp.radius) rot:0 shape:10
              color:simd_make_float4(1,1,1,1) p:simd_make_float4(t, seed, 0, 0)];
    }
    // soft wake ripples — faint gaussian crests that expand and dissolve
    for (const Ripple &rp : _ripples) {
        float ft = rp.age / rp.life;                // 0..1
        float rad = 0.4f + 2.0f * ft;               // grows outward
        float alpha = (1.0f - ft) * (1.0f - ft) * 0.28f;   // eases out gently
        [self push:rp.pos half:simd_make_float2(rad, rad) rot:0 shape:11
              color:simd_make_float4(0.85f,0.93f,1.0f, alpha) p:simd_make_float4(0,0,0,0)];
    }
    // grassy reeds ringing each pond — they part where a critter treads/drinks
    auto hashf = [](float n){ float s = sinf(n)*43758.5453f; return s - floorf(s); };
    for (int wi = 0; wi < (int)_water.size(); wi++) {
        const Water &wp = _water[wi];
        int nT = (int)(wp.radius * 3.5f);
        for (int i = 0; i < nT; i++) {
            float base = wi*17.31f + i*2.399f;
            float j0 = hashf(base), j1 = hashf(base+1.7f), j2 = hashf(base+3.3f);
            float ang = (i/(float)nT)*6.2831853f + (j0-0.5f)*0.35f;
            float rr = wp.radius * (1.02f + 0.13f*j1);
            simd_float2 gp = wp.pos + simd_make_float2(cosf(ang), sinf(ang)) * rr;
            simd_float2 push = simd_make_float2(0,0);
            float bend = 0.0f;
            for (const Critter &c : _critters) {
                if (!c.alive) continue;
                simd_float2 to = gp - c.pos;
                float d = simd_length(to);
                if (d < 1.7f) {
                    float kk = (1.7f - d) / 1.7f;
                    push += (d > 1e-3f ? to/d : simd_make_float2(0,1)) * kk;
                    bend = std::max(bend, kk);
                }
            }
            gp += push;                                        // reeds lean away
            float sz = (0.7f + 0.4f*j2) * (1.0f - 0.45f*bend); // and flatten a bit
            simd_float3 gcol = simd_make_float3(0.16f, 0.34f + 0.14f*j1, 0.12f);
            [self push:gp half:simd_make_float2(sz, sz*1.2f) rot:(j0-0.5f)*0.4f shape:12
                  color:simd_make_float4(gcol, 1.0f) p:simd_make_float4(base,0,0,0)];
        }
    }

    // Soft contact shadows — drawn first so every entity sits on top of its own
    // shadow. Offset toward lower-right so the light reads as upper-left.
    simd_float2 shOff = simd_make_float2(0.22f, -0.22f);
    simd_float4 shGrn = simd_make_float4(0,0,0,0);
    for (const Nest &n : _nests) if (n.alive) {
        float r = (1.2f + 1.6f * n.quality) * 0.95f;
        [self push:n.pos+shOff half:simd_make_float2(r,r) rot:0 shape:0
              color:simd_make_float4(0,0,0,0.18f) p:shGrn];
    }
    for (const Food &f : _food) if (f.alive)
        [self push:f.pos+simd_make_float2(0.10f,-0.10f) half:simd_make_float2(0.34f,0.34f)
              rot:0 shape:0 color:simd_make_float4(0,0,0,0.13f) p:shGrn];
    for (const Critter &c : _critters) if (c.alive)
        [self push:c.pos+shOff half:simd_make_float2(c.ph.size*0.62f, c.ph.size*0.62f)
              rot:0 shape:0 color:simd_make_float4(0,0,0,0.24f) p:shGrn];
    for (const Predator &p : _predators) if (p.alive)
        [self push:p.pos+shOff half:simd_make_float2(p.size*0.55f, p.size*0.55f)
              rot:0 shape:0 color:simd_make_float4(0,0,0,0.28f) p:shGrn];

    // food: organic leafy sprigs, each seeded from its position so no two match
    for (const Food &f : _food) {
        if (!f.alive) continue;
        float g = f.growth;
        float seed = f.pos.x*1.7f + f.pos.y*0.9f;
        [self push:f.pos half:simd_make_float2(0.6f*g+0.28f, 0.6f*g+0.28f)
              rot:fmodf(seed, 6.2831f) shape:2
              color:simd_make_float4(0.26f, 0.50f+0.28f*g, 0.16f, 1.0f)
                 p:simd_make_float4(seed,0,0,0)];
    }

    // nests: irregular woven bowls (a single seeded organic sprite)
    for (const Nest &n : _nests) {
        if (!n.alive) continue;
        float r = 1.2f + 1.6f * n.quality;
        float seed = n.pos.x*2.3f + n.pos.y*1.1f;
        simd_float3 twig = simd_make_float3(0.46f, 0.33f, 0.17f);
        [self push:n.pos half:simd_make_float2(r,r) rot:fmodf(seed, 6.2831f) shape:9
              color:simd_make_float4(twig, 1.0f) p:simd_make_float4(seed,0,0,0)];
    }

    // critters: spine of soft blobs, head + eyes, status pips
    for (const Critter &c : _critters) {
        if (!c.alive) continue;
        const Phenotype &ph = c.ph;
        // Primary + secondary coat colors, tinted by sickness and dimmed by
        // failing health.
        simd_float3 base = ph.color;
        simd_float3 sec = ph.color2;
        if (c.sick > 0) {
            simd_float3 ill = simd_make_float3(0.70f, 0.85f, 0.30f);
            base = base + (ill - base) * (c.sick * 0.6f);
            sec  = sec  + (ill - sec)  * (c.sick * 0.6f);
        }
        if (c.health < 0.5f) { float f = 0.6f + 0.4f*c.health; base = base*f; sec = sec*f; }

        float widthMul = 1.15f - 0.40f * ph.aspect;   // longer bodies are slimmer
        simd_float2 fwd = simd_make_float2(cosf(c.heading), sinf(c.heading));
        simd_float2 perp = simd_make_float2(-fwd.y, fwd.x);

        // Snout: a forward-projecting muzzle blob.
        if (ph.snout > 0.10f) {
            float sr = ph.size * 0.28f * (0.5f + 0.6f * ph.snout);
            [self push:c.pos + fwd * (0.55f*ph.size*(0.4f+0.7f*ph.snout))
                  half:simd_make_float2(sr,sr) rot:0 shape:0
                  color:simd_make_float4(base,1.0f) p:simd_make_float4(0,0,0,0)];
        }
        // Side fins / spines along the flanks.
        int nf = (int)(ph.spikes * 3.5f + 0.5f);
        for (int k = 0; k < nf && (k+1) < kSpineNodes; k++) {
            int node = k + 1;
            float un = node / (kSpineNodes - 1.0f);
            float rr = ph.size * 0.55f * (1.0f - 0.72f*un) * widthMul;
            float fr = ph.size * 0.20f * (0.5f + 0.7f * ph.spikes);
            float side = (k % 2 == 0) ? 1.0f : -1.0f;
            [self push:c.spine[node] + perp * side * (rr + fr*0.5f)
                  half:simd_make_float2(fr,fr) rot:0 shape:7
                  color:simd_make_float4(sec*0.85f,1.0f) p:simd_make_float4(0,0,0,0)];
        }
        // Body: tapered, belly-bulged, banded segments (tail first).
        for (int sidx = kSpineNodes-1; sidx >= 0; sidx--) {
            float un = sidx / (kSpineNodes - 1.0f);              // 0 head .. 1 tail
            float taper = 1.0f - 0.72f * un;
            float bulge = 1.0f + ph.girth * 0.70f * sinf(un * 3.14159f);
            float rr = ph.size * 0.55f * taper * bulge * widthMul;
            float band = ph.pattern * (0.5f + 0.5f * sinf(un * 3.0f * 6.2831853f));
            simd_float3 srgb = base + (sec - base) * band;
            [self push:c.spine[sidx] half:simd_make_float2(rr,rr) rot:0 shape:0
                  color:simd_make_float4(srgb,1.0f) p:simd_make_float4(0,0,0,0)];
        }
        // Eyes (size and iris color are both heritable traits). Drawn a bit
        // larger than life so the iris color is legible.
        float er = ph.eyeSize * ph.size * 1.3f + 0.05f;
        simd_float4 eyec = simd_make_float4(ph.eyeColor * (0.8f + 0.4f*ph.eyeShine), 1.0f);
        [self push:c.pos + fwd*0.18f*ph.size + perp*0.26f*ph.size
              half:simd_make_float2(er,er) rot:0 shape:3
              color:eyec p:simd_make_float4(0,0,0,0)];
        [self push:c.pos + fwd*0.18f*ph.size - perp*0.26f*ph.size
              half:simd_make_float2(er,er) rot:0 shape:3
              color:eyec p:simd_make_float4(0,0,0,0)];
        // Pregnancy pip.
        if (c.pregnant)
            [self push:c.pos + simd_make_float2(0, ph.size * 0.95f)
                  half:simd_make_float2(0.18f,0.18f) rot:0 shape:7
                  color:simd_make_float4(1.0f,0.5f,0.7f,1) p:simd_make_float4(0,0,0,0)];
    }

    // predators: larger dark-red hunters, same procedural spine + glowing eyes
    for (const Predator &p : _predators) {
        if (!p.alive) continue;
        simd_float2 fwd = simd_make_float2(cosf(p.heading), sinf(p.heading));
        simd_float2 perp = simd_make_float2(-fwd.y, fwd.x);
        simd_float3 body = simd_make_float3(0.58f, 0.11f, 0.12f);
        simd_float3 dark = simd_make_float3(0.26f, 0.05f, 0.07f);
        for (int sidx = kSpineNodes-1; sidx >= 0; sidx--) {
            float un = sidx / (kSpineNodes - 1.0f);
            float rr = p.size * 0.50f * (1.0f - 0.60f * un);
            simd_float3 col = dark + (body - dark) * (1.0f - un);
            [self push:p.spine[sidx] half:simd_make_float2(rr,rr) rot:0 shape:0
                  color:simd_make_float4(col,1.0f) p:simd_make_float4(0,0,0,0)];
        }
        for (int k = 1; k < kSpineNodes-1; k++)   // dorsal spikes
            [self push:p.spine[k] half:simd_make_float2(p.size*0.15f,p.size*0.15f) rot:0 shape:7
                  color:simd_make_float4(0.80f,0.22f,0.16f,1) p:simd_make_float4(0,0,0,0)];
        float er = 0.14f * p.size;
        [self push:p.pos + fwd*0.22f*p.size + perp*0.22f*p.size
              half:simd_make_float2(er,er) rot:0 shape:0
              color:simd_make_float4(1.0f,0.82f,0.2f,1) p:simd_make_float4(0,0,0,0)];
        [self push:p.pos + fwd*0.22f*p.size - perp*0.22f*p.size
              half:simd_make_float2(er,er) rot:0 shape:0
              color:simd_make_float4(1.0f,0.82f,0.2f,1) p:simd_make_float4(0,0,0,0)];
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
    _widgets.clear();
    [self buildEvoGraph:bw bh:bh];
    [self buildStats:bw bh:bh];
    [self buildHUD:sel bw:bw bh:bh];
    [self buildControlPanel:bw bh:bh];
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
    const char *band = _climate < -0.33f ? "COLD" : (_climate > 0.33f ? "HOT" : "TEMPERATE");
    view.window.title = [NSString stringWithFormat:
        @"09 — BIOME v9 ▸ prey %d (%dM/%dF) ▸ pred %d ▸ nests %d ▸ gen %d ▸ births %d deaths %d ▸ sick %d ▸ %s %+.2f ▸ x%.2g%s ▸ %.0f fps",
        (int)_critters.size(), males, females, (int)_predators.size(), (int)_nests.size(),
        _generation, _births, _deaths, sick, band, _climate, _timeScale, _paused ? " PAUSED" : "", _smoothedFPS];
}

// ------------------------------------------------------------- Inspector ---

// Top-center population readout: living count, total deaths, and net growth /
// decline since the colony started.
- (void)buildStats:(float)bw bh:(float)bh {
    auto rect = [&](float x, float y, float w, float h, simd_float4 c, float s) {
        float cx = (x+w*0.5f)/bw*2.0f-1.0f, cy = (y+h*0.5f)/bh*2.0f-1.0f;
        [self hud:cx cy:cy hw:w/bw hh:h/bh shape:s color:c p0:0];
    };
    float sw = 384, sh = 34, sx = (bw - sw) * 0.5f, sy = bh - 14 - sh;
    rect(sx, sy, sw, sh, simd_make_float4(0.05f,0.06f,0.09f,0.85f), 6);
    simd_float4 lab = simd_make_float4(0.55f,0.68f,0.85f,1);
    simd_float4 val = simd_make_float4(0.96f,0.98f,1.0f,1);

    int pop = (int)_critters.size();
    int growth = _initialPop > 0 ? (int)lroundf((pop - _initialPop) * 100.0f / _initialPop) : 0;
    simd_float4 gcol = growth >= 0 ? simd_make_float4(0.45f,0.90f,0.55f,1)   // green up
                                   : simd_make_float4(0.95f,0.45f,0.40f,1);  // red down
    char bPop[16], bDied[16], bGrow[16];
    snprintf(bPop, sizeof bPop, "%d", pop);
    snprintf(bDied, sizeof bDied, "%d", _deaths);
    snprintf(bGrow, sizeof bGrow, "%+d%%", growth);

    float ly = sy + 4, vy = sy + 17;
    [self hudText:"ORGANISMS" x:sx+14  y:ly h:9  col:lab bw:bw bh:bh];
    [self hudText:bPop        x:sx+14  y:vy h:13 col:val bw:bw bh:bh];
    [self hudText:"DEATHS"    x:sx+150 y:ly h:9  col:lab bw:bw bh:bh];
    [self hudText:bDied       x:sx+150 y:vy h:13 col:val bw:bw bh:bh];
    [self hudText:"GROWTH"    x:sx+270 y:ly h:9  col:lab bw:bw bh:bh];
    [self hudText:bGrow       x:sx+270 y:vy h:13 col:gcol bw:bw bh:bh];
}

// Evolution graph: the climate driver and the colony-average traits that
// track it, scrolling over the last ~kHistLen sim-seconds. Can be hidden with
// its X button; a small GRAPH tab brings it back.
- (void)buildEvoGraph:(float)bw bh:(float)bh {
    auto rect = [&](float x, float y, float w, float h, simd_float4 col, float shape) {
        float cx = (x + w*0.5f)/bw*2.0f-1.0f, cy = (y + h*0.5f)/bh*2.0f-1.0f;
        [self hud:cx cy:cy hw:w/bw hh:h/bh shape:shape color:col p0:0];
    };
    float gw = 360, gh = 150, gx = 16, gy = bh - 32 - gh;

    // Collapsed: just a little tab in the top-left corner to reopen it.
    if (!_showGraph) {
        float tw = 70, th = 22, tx = 16, ty = bh - 16 - th;
        rect(tx, ty, tw, th, simd_make_float4(0.10f,0.12f,0.16f,0.92f), 6);
        [self hudText:"GRAPH" x:tx+10 y:ty+6 h:11 col:simd_make_float4(0.8f,0.88f,1.0f,1)
                   bw:bw bh:bh];
        _widgets.push_back({tx, ty, tw, th, WA_ToggleGraph, 0});
        return;
    }

    rect(gx-8, gy-8, gw+16, gh+32, simd_make_float4(0.05f,0.06f,0.08f,0.85f), 6);
    for (int k = 0; k <= 2; k++)                              // 0 / 0.5 / 1 grid
        rect(gx, gy + k*0.5f*gh, gw, 1, simd_make_float4(1,1,1,0.08f), 4);
    // Title + hide (X) button in the top-right corner of the panel.
    [self hudText:"EVOLUTION" x:gx y:gy+gh+6 h:11 col:simd_make_float4(0.7f,0.82f,1.0f,1)
               bw:bw bh:bh];
    float xb = 18, xx = gx + gw - xb, xy = gy + gh + 4;
    rect(xx, xy, xb, xb, simd_make_float4(0.20f,0.22f,0.28f,1), 6);
    [self hudText:"X" x:xx+5 y:xy+4 h:11 col:simd_make_float4(0.9f,0.94f,1.0f,1) bw:bw bh:bh];
    _widgets.push_back({xx, xy, xb, xb, WA_ToggleGraph, 0});

    int count = _histCount, head = _histHead;
    auto plot = [&](const float *buf, simd_float4 col, float dot) {
        for (int k = 0; k < count; k++) {
            int idx = (head - count + k + kHistLen) % kHistLen;
            float v = std::clamp(buf[idx], 0.0f, 1.0f);
            float x = gx + (float)k/(kHistLen-1) * gw;
            float y = gy + v * gh;
            rect(x - dot*0.5f, y - dot*0.5f, dot, dot, col, 4);
        }
    };
    if (count >= 2) {
        plot(_histPop,  simd_make_float4(0.55f,0.55f,0.62f,0.7f), 2.0f);  // prey population
        plot(_histClim, simd_make_float4(1.00f,1.00f,1.00f,0.9f), 2.5f);  // climate (driver)
        plot(_histRes,  simd_make_float4(0.95f,0.70f,0.30f,1.0f), 2.5f);  // resistance
        plot(_histSize, simd_make_float4(0.35f,0.75f,0.95f,1.0f), 2.5f);  // avg size
        plot(_histDark, simd_make_float4(0.45f,0.90f,0.50f,1.0f), 2.5f);  // coat darkness
        plot(_histPred, simd_make_float4(0.90f,0.25f,0.20f,1.0f), 2.5f);  // predators
    }
    // Colour key (bottom): climate·size·darkness·resistance·prey·predators.
    simd_float4 key[6] = {
        simd_make_float4(1.00f,1.00f,1.00f,0.9f), simd_make_float4(0.35f,0.75f,0.95f,1),
        simd_make_float4(0.45f,0.90f,0.50f,1),    simd_make_float4(0.95f,0.70f,0.30f,1),
        simd_make_float4(0.55f,0.55f,0.62f,0.9f), simd_make_float4(0.90f,0.25f,0.20f,1),
    };
    for (int k = 0; k < 6; k++)
        rect(gx + k*26.0f, gy - 7, 20, 5, key[k], 4);
}

- (void)buildHUD:(Critter *)sel bw:(float)bw bh:(float)bh {
    auto rect = [&](float x, float y, float w, float h, simd_float4 col, float shape) {
        float cx = (x + w*0.5f)/bw*2.0f-1.0f, cy = (y + h*0.5f)/bh*2.0f-1.0f;
        [self hud:cx cy:cy hw:w/bw hh:h/bh shape:shape color:col p0:0];
    };
    if (!sel) return;
    float px = 16, py = 16, panW = 360, panH = 312;
    rect(px-8, py-8, panW+16, panH+16, simd_make_float4(0.05f,0.06f,0.08f,0.88f), 6);

    // Trait bars, colored by group: physiology (blue), morphology (green),
    // condition (amber). Two columns.
    simd_float4 cPhys  = simd_make_float4(0.35f,0.75f,0.95f,1);
    simd_float4 cMorph = simd_make_float4(0.45f,0.90f,0.50f,1);
    simd_float4 cState = simd_make_float4(0.95f,0.70f,0.30f,1);
    const Phenotype &q = sel->ph;
    struct Bar { float v; simd_float4 c; };
    Bar bars[16] = {
        {(q.size-0.6f)/1.1f, cPhys}, {q.speed/16.0f, cPhys},
        {q.metabolism/1.7f, cPhys}, {(q.sensory-10.0f)/15.0f, cPhys},
        {q.fertility, cPhys}, {q.resistance, cPhys},
        {q.aspect, cMorph}, {q.girth, cMorph}, {q.eyeSize/0.25f, cMorph},
        {q.snout, cMorph}, {q.spikes, cMorph}, {q.pattern, cMorph},
        {sel->energy, cState}, {sel->hunger, cState}, {sel->health, cState},
        {std::clamp(sel->age/(q.lifespan*_lifespanMul),0.0f,1.0f), cState},
    };
    float by0 = py + 34;
    for (int i = 0; i < 16; i++) {
        float bx = px + (i/8) * 180.0f;
        float y = by0 + (i%8) * 17.0f;
        rect(bx, y, 150, 11, simd_make_float4(0.15f,0.16f,0.18f,1), 4);
        rect(bx, y, 150*std::clamp(bars[i].v,0.0f,1.0f), 11, bars[i].c, 4);
    }
    // Coat swatches (primary + secondary), an eye showing iris color, sex bar.
    rect(px+300, py+34, 44, 30, simd_make_float4(q.color, 1.0f), 4);
    rect(px+300, py+66, 44, 30, simd_make_float4(q.color2, 1.0f), 4);
    rect(px+300, py+100, 26, 26, simd_make_float4(q.eyeColor, 1.0f), 3);  // eye icon
    rect(px+330, py+104, 14, 18,
         sel->male ? simd_make_float4(0.4f,0.6f,1.0f,1.0f)
                   : simd_make_float4(1.0f,0.5f,0.7f,1.0f), 4);

    // Genome strip: both homologs, each gene's 16 bases as colored ticks
    // (A green, C blue, G yellow, T red).
    float gy = py + panH - 84;
    float tickW = (panW - 16) / (float)(kNumGenes * 16);
    simd_float4 baseCol[4] = {
        simd_make_float4(0.30f,0.85f,0.35f,1), simd_make_float4(0.30f,0.55f,0.95f,1),
        simd_make_float4(0.95f,0.85f,0.30f,1), simd_make_float4(0.95f,0.35f,0.30f,1),
    };
    for (int h = 0; h < 2; h++)
        for (int g = 0; g < kNumGenes; g++) {
            uint32_t word = sel->genome.hom[h][g];
            for (int b = 0; b < 16; b++) {
                int base = (word >> (2*b)) & 3;
                float x = px + (g*16 + b) * tickW;
                rect(x, gy + h*32, tickW*0.9f, 26, baseCol[base], 4);
            }
        }
    // Header numbers: id, age, generation.
    [self hudNumber:(int)sel->id x:px y:py dw:6 dh:11 col:simd_make_float4(1,1,1,1) bw:bw bh:bh];
    [self hudNumber:(int)sel->age x:px+120 y:py dw:6 dh:11 col:simd_make_float4(0.8f,0.9f,1,1) bw:bw bh:bh];
    [self hudNumber:sel->generation x:px+230 y:py dw:6 dh:11 col:simd_make_float4(0.7f,1,0.7f,1) bw:bw bh:bh];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}
@end

int main() {
    return RunMetalApp(@"09 — BIOME v9", 1280, 800, ^(MTKView *view) {
        return (NSObject<MTKViewDelegate> *)[[BiomeRenderer alloc] initWithView:view];
    });
}
