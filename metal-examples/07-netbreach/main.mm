// 07 — NET BREACH (vertical slice, step 2: towers + Spark-Node economy)
//
// Cyberpunk tower defense on a neon circuit board. Current systems:
//
//   * Procedural circuit-grid background + animated data conduit
//   * HDR scene + bloom post chain (bright-pass, blur, composite FX)
//   * Enemies (Bits + Daemons) marching the path; Core integrity
//   * THREE TOWERS: Sentry (kinetic tracers), Arc Coil (chain lightning),
//     Cryo Node (slow aura) — with linear tier upgrades
//   * Spark-Node economy: kills pay, build/upgrade/sell
//
// Controls:
//   1 / 2 / 3     select Sentry / Arc Coil / Cryo Node
//   Left-click    empty tile: build selected tower · your tower: upgrade tier
//   Right-click   your tower: sell for 75% of invested
//
// The 10-wave table, Golem/Wisp, and the Black ICE boss land next. DESIGN.md
// is the source of truth for stats.

#include "../common/app.h"
#include <simd/simd.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <random>
#include <string>
#include <vector>

// ---------------------------------------------------------------- Tuning ---

static const float kBoardW = 24.0f;   // board size in tiles (world units)
static const float kBoardH = 14.0f;
static const int kTilesW = 24, kTilesH = 14;
static const int kStartIntegrity = 20;
static const int kStartSparks = 120;
static const int kMaxInstances = 8192;
static const int kMaxInFlight = 3;

// Tower archetypes: 3 types x 3 linear tiers (stats from DESIGN.md).
enum { kTowerSentry = 0, kTowerArc = 1, kTowerCryo = 2, kTowerTypeCount = 3 };

struct TowerTier {
    float damage;     // per shot (Cryo: unused)
    float rate;       // shots/sec (Cryo: unused)
    float range;      // world units (Cryo: aura radius)
    float chains;     // Arc only
    float slow;       // Cryo only, 0..1
};
struct TowerSpec {
    const char *name;
    int buildCost;
    int upCost[2];        // tier1->2, tier2->3
    simd_float4 color;    // signature neon
    TowerTier tiers[3];
};
static const TowerSpec kTowers[kTowerTypeCount] = {
    {"Sentry", 40, {30, 60}, {0.15f, 1.7f, 2.1f, 1.0f},          // cyan
     {{6, 2.0f, 3.0f, 0, 0}, {10, 2.5f, 3.0f, 0, 0}, {16, 3.0f, 3.5f, 0, 0}}},
    {"Arc Coil", 70, {55, 90}, {1.5f, 1.9f, 2.5f, 1.0f},         // near-white
     {{5, 1.0f, 2.5f, 2, 0}, {8, 1.2f, 2.5f, 3, 0}, {12, 1.4f, 3.0f, 4, 0}}},
    {"Cryo Node", 50, {40, 70}, {0.30f, 1.0f, 2.4f, 1.0f},       // deep ice blue
     {{0, 0, 2.0f, 0, 0.30f}, {0, 0, 2.5f, 0, 0.45f}, {0, 0, 3.0f, 0, 0.60f}}},
};

// Sector 1 conduit: an S-curve from the breach (left) to the Core (right).
static const simd_float2 kPath[] = {
    {-0.8f, 3.5f}, {5.5f, 3.5f}, {5.5f, 10.5f}, {12.5f, 10.5f},
    {12.5f, 3.5f}, {18.5f, 3.5f}, {18.5f, 10.5f}, {22.0f, 10.5f},
};
static const int kPathCount = sizeof(kPath) / sizeof(kPath[0]);

// Enemy archetypes (v1 subset: Bit, Daemon).
struct EnemyType {
    float hp, speed, radius;
    int reward;           // Spark-Nodes on kill
    bool armored;         // halves kinetic damage
    simd_float4 color;    // HDR: >1 channels feed the bloom
};
// TRON palette: intruders are orange; defenses are cyan/white.
static const EnemyType kEnemyTypes[] = {
    {12.0f, 1.0f, 0.30f, 2, false, {2.4f, 0.62f, 0.10f, 1.0f}},   // Bit — orange
    { 8.0f, 2.2f, 0.24f, 3, false, {2.6f, 1.25f, 0.25f, 1.0f}},   // Daemon — hot amber
};

enum { kDmgKinetic = 0, kDmgEnergy = 1 };

// ---------------------------------------------------------------- Shaders ---

static const char *kShaderSource = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct Uni {
    float2 scale;       // world -> NDC scale
    float2 offset;      // world -> NDC offset
    float2 resolution;  // drawable pixels
    float  time;
    float  pad;
    float4 fx;          // x = bloom strength, y = aberration, z = scanline
};

// ---------- fullscreen triangle ----------
struct FSOut {
    float4 position [[position]];
    float2 uv;
};

vertex FSOut fs_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);   // top-left origin uv
    return o;
}

float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// ---------- background: TRON cityscape floor ----------
// Dark desaturated blue-grey panel plating with seams, hex-plate accent
// regions, a cool ambient key light, and the conduit drawn as a proper road:
// darkened lane bounded by continuous white-hot edge ribbons.

float segDist(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    float t = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
    return length(p - a - ab * t);
}

float2 mod2(float2 p, float2 m) { return p - m * floor(p / m); }

// Distance-ish offset to the nearest hex center (pointy tiling).
float2 hexLocal(float2 p) {
    float2 r = float2(1.0, 1.7320508);
    float2 h = r * 0.5;
    float2 a = mod2(p, r) - h;
    float2 b = mod2(p + h, r) - h;
    return dot(a, a) < dot(b, b) ? a : b;
}

float hexEdge(float2 lp) {   // distance from hex EDGE for a unit-ish cell
    float2 q = abs(lp);
    return max(dot(q, float2(0.866025, 0.5)), q.y);
}

fragment float4 bg_fragment(FSOut in [[stage_in]],
                            constant Uni &u [[buffer(0)]]) {
    // uv -> NDC -> world
    float2 ndc = float2(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0);
    float2 w = (ndc - u.offset) / u.scale;

    // --- Panel plating: regions choose a plate size; plates vary in tone.
    float2 region = floor(w / 6.0);
    float rs = hash21(region);
    float2 psize = (rs < 0.25) ? float2(3.0, 1.5) :
                   (rs < 0.50) ? float2(1.5, 3.0) :
                   (rs < 0.75) ? float2(2.0, 2.0) : float2(3.0, 3.0);
    float2 pid = floor(w / psize);
    float pr = hash21(pid * 1.31 + region * 13.7);
    float3 col = float3(0.030, 0.046, 0.062) * (0.7 + 0.6 * pr);

    // Cool key light pooling over the board + slow breathing.
    float amb = 0.75 + 0.55 * exp(-length(w - float2(9.0, 9.5)) * 0.055);
    amb *= 0.95 + 0.05 * sin(u.time * 0.5 - w.x * 0.08);
    col *= amb;

    // Hex-plate accent regions (the TRON floor motif), softly outlined.
    if (hash21(region + 5.1) > 0.70) {
        float2 lp = hexLocal(w * 1.1);
        float he = hexEdge(lp);
        float hline = smoothstep(0.06, 0.02, abs(he - 0.44));
        col += float3(0.020, 0.060, 0.085) * hline;
        col *= 0.9 + 0.1 * hash21(floor(w * 1.1 - lp));   // per-hex tone step
    }

    // Panel seams: a dark gap with a faint lit bevel beside it.
    float2 pf = fract(w / psize);
    float2 ew = min(pf, 1.0 - pf) * psize;
    float seam = min(ew.x, ew.y);
    col *= mix(0.30, 1.0, smoothstep(0.0, 0.045, seam));
    col += float3(0.05, 0.10, 0.13) * smoothstep(0.10, 0.045, seam)
                                    * smoothstep(0.015, 0.045, seam);

    // Static micro-grain so surfaces read as material, not vector fill.
    col *= 0.93 + 0.14 * hash21(floor(w * 24.0));

    // --- The road: dark lane + double edge ribbons along the conduit.
    float dRoad = 1e9;
    for (int i = 0; i < kRoadCount - 1; i++)
        dRoad = min(dRoad, segDist(w, kRoad[i], kRoad[i + 1]));
    float laneHalf = 0.55;
    float aa = fwidth(dRoad) * 1.5;
    // darken the lane surface
    col *= mix(0.30, 1.0, smoothstep(laneHalf - aa, laneHalf + aa, dRoad));
    // white-hot primary ribbon at the lane edge (HDR: tonemap whitens core)
    float ribbon = smoothstep(2.5 * aa, 0.5 * aa, abs(dRoad - laneHalf));
    col += float3(1.6, 2.6, 3.2) * ribbon;
    // dimmer inner guide line
    float inner = smoothstep(2.0 * aa, 0.4 * aa, abs(dRoad - laneHalf * 0.45));
    col += float3(0.10, 0.30, 0.42) * inner;

    // Board bounds: fade the world off beyond the play area.
    float2 bd = max(float2(-0.5, -0.5) - w, w - float2(24.5, 14.5));
    float outside = max(max(bd.x, bd.y), 0.0);
    col *= exp(-outside * 1.4);

    return float4(col, 1.0);
}

// ---------- instanced neon entities ----------
// One instanced draw renders everything glowing: conduit stream segments,
// markers, enemies, particles. Shapes are SDFs picked by `shape`.
struct EInst {
    packed_float2 center;
    packed_float2 half2;
    float rot;
    float shape;      // 0 circle, 1 ring, 2 diamond, 3 hex ring, 4 square, 6 stream
    packed_float4 color;
    packed_float4 params;
};

struct EOut {
    float4 position [[position]];
    float2 lp;        // local -1..1
    float4 color;
    float4 params;
    float  shape;
};

constant float2 kCorners[6] = {
    float2(-1, -1), float2(1, -1), float2(1, 1),
    float2(-1, -1), float2(1, 1), float2(-1, 1),
};

vertex EOut entity_vertex(uint vid [[vertex_id]],
                          uint iid [[instance_id]],
                          const device EInst *insts [[buffer(0)]],
                          constant Uni &u [[buffer(1)]]) {
    EInst inst = insts[iid];
    float2 lp = kCorners[vid];
    float2 p = lp * float2(inst.half2);
    float cs = cos(inst.rot), sn = sin(inst.rot);
    float2 world = float2(inst.center) + float2(p.x * cs - p.y * sn,
                                                p.x * sn + p.y * cs);
    EOut o;
    o.position = float4(world * u.scale + u.offset, 0.0, 1.0);
    o.lp = lp;
    o.color = float4(inst.color);
    o.params = float4(inst.params);
    o.shape = inst.shape;
    return o;
}

// Hard neon line: a crisp core ~`px` pixels wide around distance-measure d,
// antialiased over one pixel via screen-space derivatives. The bloom pass
// supplies the halo; the line itself stays razor sharp (the TRON look).
float neon(float d, float px, float aa) {
    return smoothstep(px * aa, max((px - 1.6) * aa, 0.0), d);
}

fragment float4 entity_fragment(EOut in [[stage_in]],
                                constant Uni &u [[buffer(0)]]) {
    float2 p = in.lp;
    float a = 0.0;
    int shape = int(in.shape + 0.5);

    if (shape == 0) {                       // soft glow dot (particles, cores)
        float r = length(p);
        a = smoothstep(1.0, 0.0, r);
        a *= a;
    } else if (shape == 1) {                // hard ring + faint interior
        float r = length(p);
        float aa = fwidth(r);
        a = neon(abs(r - 0.82), 2.2, aa) + 0.06 * smoothstep(0.82, 0.0, r);
    } else if (shape == 2) {                // diamond: hard edge, dim body
        float d = abs(p.x) + abs(p.y);
        float aa = fwidth(d);
        a = neon(abs(d - 0.88), 2.2, aa)
          + 0.10 * smoothstep(aa, -aa, d - 0.88);
    } else if (shape == 3) {                // hex: hard outline, dim body
        float2 q = abs(p);
        float d = max(q.x * 0.866 + q.y * 0.5, q.y) - 0.82;
        float aa = fwidth(d);
        a = neon(abs(d), 2.2, aa) + 0.08 * smoothstep(aa, -aa, d);
    } else if (shape == 4) {                // solid, crisp-edged fill
        float d = max(abs(p.x), abs(p.y));
        float aa = fwidth(d);
        a = smoothstep(aa, -aa, d - 0.96);
    } else if (shape == 5) {                // square outline, dim body
        float d = max(abs(p.x), abs(p.y));
        float aa = fwidth(d);
        a = neon(abs(d - 0.88), 2.2, aa)
          + 0.10 * smoothstep(aa, -aa, d - 0.88);
    } else if (shape == 6) {                // road traffic: packets of hostile data
        // params.x = arc distance at segment start, params.y = segment length
        float uWorld = in.params.x + (p.x * 0.5 + 0.5) * in.params.y;
        float d = fract(uWorld * 0.55 - u.time * 1.4);
        float packet = exp(-pow((d - 0.5) * 8.0, 2.0));
        float lane = smoothstep(0.85, 0.0, abs(p.y));
        a = lane * (0.03 + 0.75 * packet);
    } else if (shape == 7) {                // lightning bolt (params.x = seed)
        float wob = 0.5 * sin(p.x * 9.0 + in.params.x * 40.0 + u.time * 55.0)
                  * sin(p.x * 3.7 - in.params.x * 17.0);
        float flick = 0.7 + 0.3 * sin(u.time * 90.0 + in.params.x * 30.0);
        float m = abs(p.y - wob);
        float aa = fwidth(p.y);
        a = (neon(m, 2.0, aa) + 0.35 * smoothstep(0.5, 0.0, m)) * flick;
    } else if (shape == 8) {                // thin exact ring (range indicator)
        float r = length(p);
        float aa = fwidth(r);
        a = 0.85 * neon(abs(r - 0.97), 1.6, aa)
          + 0.03 * smoothstep(1.0, 0.0, r);
    }

    // The light-cycle look: line cores burn to white, halos stay colored.
    // pow(a,5) only reaches the center of a line; the ACES tonemap and bloom
    // finish the job.
    float3 rgb = in.color.rgb * a + float3(1.0, 1.0, 1.0) * (pow(a, 5.0) * 0.9 * in.color.a);
    return float4(rgb, a * in.color.a);
}

// ---------- bloom chain ----------
fragment float4 bright_fragment(FSOut in [[stage_in]],
                                texture2d<float> scene [[texture(0)]],
                                sampler smp [[sampler(0)]]) {
    float3 c = scene.sample(smp, in.uv).rgb;
    float luma = dot(c, float3(0.299, 0.587, 0.114));
    float k = smoothstep(0.85, 1.4, luma);
    return float4(c * k, 1.0);
}

constant float kBlurW[5] = {0.227027, 0.194594, 0.121621, 0.054054, 0.016216};

fragment float4 blur_fragment(FSOut in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              sampler smp [[sampler(0)]],
                              constant float2 &dir [[buffer(0)]]) {
    float2 texel = 1.0 / float2(src.get_width(), src.get_height());
    float3 c = src.sample(smp, in.uv).rgb * kBlurW[0];
    for (int i = 1; i < 5; i++) {
        float2 o = dir * texel * float(i) * 1.5;
        c += src.sample(smp, in.uv + o).rgb * kBlurW[i];
        c += src.sample(smp, in.uv - o).rgb * kBlurW[i];
    }
    return float4(c, 1.0);
}

fragment float4 composite_fragment(FSOut in [[stage_in]],
                                   texture2d<float> scene [[texture(0)]],
                                   texture2d<float> bloom [[texture(1)]],
                                   sampler smp [[sampler(0)]],
                                   constant Uni &u [[buffer(0)]]) {
    float2 uv = in.uv;
    float2 cc = uv - 0.5;

    // Chromatic aberration: R/B sampled slightly apart, growing at the edges.
    float ab = u.fx.y * dot(cc, cc);
    float3 c;
    c.r = scene.sample(smp, uv + cc * ab).r;
    c.g = scene.sample(smp, uv).g;
    c.b = scene.sample(smp, uv - cc * ab).b;

    c += bloom.sample(smp, uv).rgb * u.fx.x;

    // Faint scanlines, film grain, cool shadow tint, vignette.
    c *= 1.0 - u.fx.z * (0.5 + 0.5 * sin(uv.y * u.resolution.y * 3.14159));
    c += (hash21(uv * u.resolution.xy + fract(u.time) * 61.7) - 0.5) * 0.018;
    c *= float3(0.97, 1.00, 1.04);
    c *= 1.0 - 0.38 * dot(cc, cc) * 2.2;

    // Tonemap + gamma.
    c = saturate((c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14));
    return float4(pow(c, float3(0.4545)), 1.0);
}
)METAL";

// ------------------------------------------------------------- CPU mirror ---

struct EInstC {
    float cx, cy;
    float hx, hy;
    float rot;
    float shape;
    float r, g, b, a;
    float p0, p1, p2, p3;
};

struct Enemy {
    uint32_t id;
    int type;
    float dist;      // arc length along the path
    float hp, maxHp;
    float slow;      // 0..1, recomputed from cryo auras each step
    float flash;     // hit flash timer
    float wobble;    // per-enemy phase
    bool alive;
};

struct Tower {
    int type;
    int tier;        // 0..2
    int tx, ty;      // tile
    int invested;    // Spark-Nodes sunk in (for sell refund)
    float cooldown;
    float aim;       // barrel angle
};

struct Projectile {
    simd_float2 pos;
    uint32_t targetId;
    float speed, damage;
    int dmgType;
    simd_float4 color;
    bool alive;
};

struct Beam {
    simd_float2 a, b;
    float age, life, seed;
    simd_float4 color;
};

struct Puff {
    simd_float2 pos, vel;
    float age, life;
    float size0, size1;
    simd_float4 color;
};

// --------------------------------------------------------------- Renderer ---

@interface NetBreachRenderer : NSObject <MTKViewDelegate>
- (instancetype)initWithView:(MTKView *)view;
@end

@implementation NetBreachRenderer {
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _bgPipeline;        // opaque, into scene tex
    id<MTLRenderPipelineState> _entityPipeline;    // additive, into scene tex
    id<MTLRenderPipelineState> _brightPipeline;
    id<MTLRenderPipelineState> _blurPipeline;
    id<MTLRenderPipelineState> _compositePipeline; // into drawable
    id<MTLSamplerState> _sampler;

    id<MTLTexture> _sceneTex;
    id<MTLTexture> _bloomA, _bloomB;

    id<MTLBuffer> _instBuffers[kMaxInFlight];
    int _frameIndex;
    dispatch_semaphore_t _frameSemaphore;
    std::vector<EInstC> _scratch;

    // Path
    std::vector<simd_float2> _waypoints;
    std::vector<float> _cumLen;   // arc length at each waypoint
    float _pathLen;

    // Game state
    std::vector<Enemy> _enemies;
    std::vector<Tower> _towers;
    std::vector<Projectile> _projectiles;
    std::vector<Beam> _beams;
    std::vector<Puff> _puffs;
    bool _blocked[kTilesW][kTilesH];   // path/core tiles: unbuildable
    uint32_t _nextEnemyId;
    int _integrity;
    int _sparks;
    int _selectedType;                 // tower type armed for building
    simd_float2 _hoverWorld;
    int _waveNum;
    float _waveTimer;
    int _spawnLeft;
    float _spawnTimer;
    std::mt19937 _rng;

    // Frame plumbing
    double _startTime, _lastFrameTime;
    double _simAccum;
    float _smoothedFPS;
    simd_float2 _uScale, _uOffset;   // cached world->NDC for click mapping
}

- (instancetype)initWithView:(MTKView *)view {
    if (!(self = [super init])) return nil;

    id<MTLDevice> device = view.device;
    _queue = [device newCommandQueue];

    // Bake the conduit polyline into the shader so the background can draw
    // the road (dark lane + edge ribbons) with no extra buffers.
    std::string roadSrc = "constant int kRoadCount = " + std::to_string(kPathCount) + ";\n"
                          "constant float2 kRoad[" + std::to_string(kPathCount) + "] = {\n";
    for (int i = 0; i < kPathCount; i++) {
        char line[64];
        snprintf(line, sizeof(line), "    float2(%f, %f),\n", kPath[i].x, kPath[i].y);
        roadSrc += line;
    }
    roadSrc += "};\n";
    std::string source(kShaderSource);
    size_t anchor = source.find("// ---------- background");
    source.insert(anchor, roadSrc);

    id<MTLLibrary> library = CompileLibrary(device, source.c_str());
    if (!library) return nil;

    NSError *error = nil;
    id<MTLFunction> fsVertex = [library newFunctionWithName:@"fs_vertex"];

    // Scene-target pipelines (HDR half-float).
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;

    d.vertexFunction = fsVertex;
    d.fragmentFunction = [library newFunctionWithName:@"bg_fragment"];
    _bgPipeline = [device newRenderPipelineStateWithDescriptor:d error:&error];
    if (!_bgPipeline) { fprintf(stderr, "bg pipeline: %s\n", error.localizedDescription.UTF8String); return nil; }

    d.vertexFunction = [library newFunctionWithName:@"entity_vertex"];
    d.fragmentFunction = [library newFunctionWithName:@"entity_fragment"];
    d.colorAttachments[0].blendingEnabled = YES;      // additive neon
    d.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    d.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
    d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
    _entityPipeline = [device newRenderPipelineStateWithDescriptor:d error:&error];
    if (!_entityPipeline) { fprintf(stderr, "entity pipeline: %s\n", error.localizedDescription.UTF8String); return nil; }

    d.colorAttachments[0].blendingEnabled = NO;
    d.vertexFunction = fsVertex;
    d.fragmentFunction = [library newFunctionWithName:@"bright_fragment"];
    _brightPipeline = [device newRenderPipelineStateWithDescriptor:d error:&error];
    if (!_brightPipeline) { fprintf(stderr, "bright pipeline: %s\n", error.localizedDescription.UTF8String); return nil; }

    d.fragmentFunction = [library newFunctionWithName:@"blur_fragment"];
    _blurPipeline = [device newRenderPipelineStateWithDescriptor:d error:&error];
    if (!_blurPipeline) { fprintf(stderr, "blur pipeline: %s\n", error.localizedDescription.UTF8String); return nil; }

    d.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    d.fragmentFunction = [library newFunctionWithName:@"composite_fragment"];
    _compositePipeline = [device newRenderPipelineStateWithDescriptor:d error:&error];
    if (!_compositePipeline) { fprintf(stderr, "composite pipeline: %s\n", error.localizedDescription.UTF8String); return nil; }

    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = MTLSamplerMinMagFilterLinear;
    sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    _sampler = [device newSamplerStateWithDescriptor:sd];

    for (int i = 0; i < kMaxInFlight; i++) {
        _instBuffers[i] = [device newBufferWithLength:kMaxInstances * sizeof(EInstC)
                                              options:MTLResourceStorageModeShared];
    }
    _frameIndex = 0;
    _frameSemaphore = dispatch_semaphore_create(kMaxInFlight);
    _scratch.reserve(kMaxInstances);

    // Path arc lengths.
    _pathLen = 0;
    for (int i = 0; i < kPathCount; i++) {
        _waypoints.push_back(kPath[i]);
        if (i > 0) _pathLen += simd_distance(kPath[i], kPath[i - 1]);
        _cumLen.push_back(_pathLen);
    }

    _integrity = kStartIntegrity;
    _sparks = kStartSparks;
    _selectedType = kTowerSentry;
    _nextEnemyId = 1;
    _hoverWorld = simd_make_float2(-100, -100);
    _waveNum = 0;
    _waveTimer = 4.0f;   // first wave after 4s (time to build)
    _spawnLeft = 0;
    _spawnTimer = 0;
    _rng.seed(1337);

    // Mark the conduit's tiles unbuildable by sampling the path densely.
    memset(_blocked, 0, sizeof(_blocked));
    for (float d = 0; d <= _pathLen; d += 0.05f) {
        simd_float2 p = [self pathPointAt:d];
        int tx = (int)floorf(p.x), ty = (int)floorf(p.y);
        if (tx >= 0 && tx < kTilesW && ty >= 0 && ty < kTilesH)
            _blocked[tx][ty] = true;
    }

    // Input: 1/2/3 select a tower type; left-click builds/upgrades;
    // right-click sells.
    __unsafe_unretained NetBreachRenderer *weakSelf = self;
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                          handler:^NSEvent *(NSEvent *event) {
        if (event.modifierFlags & NSEventModifierFlagCommand) return event;
        unsigned short code = event.keyCode;
        if (code == 18 || code == 19 || code == 20) {   // ANSI 1 / 2 / 3
            weakSelf->_selectedType = code - 18;
            return nil;
        }
        return event;
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseDown |
                                                   NSEventMaskRightMouseDown)
                                          handler:^NSEvent *(NSEvent *event) {
        if (!event.window) return event;
        MTKView *v = (MTKView *)event.window.contentView;
        if (![v isKindOfClass:[MTKView class]]) return event;
        if (weakSelf->_uScale.x == 0) return event;   // no frame rendered yet
        NSPoint pt = [v convertPoint:event.locationInWindow fromView:nil];
        simd_float2 ndc = simd_make_float2((float)(pt.x / v.bounds.size.width) * 2.0f - 1.0f,
                                           (float)(pt.y / v.bounds.size.height) * 2.0f - 1.0f);
        simd_float2 world = (ndc - weakSelf->_uOffset) / weakSelf->_uScale;
        if (event.type == NSEventTypeLeftMouseDown) [weakSelf clickAt:world];
        else [weakSelf sellAt:world];
        return event;
    }];

    printf("NET BREACH — step 2.\n"
           "  1/2/3 select Sentry / Arc Coil / Cryo Node\n"
           "  Left-click: build on empty tile, upgrade your tower\n"
           "  Right-click: sell tower (75%% refund)\n");

    _startTime = CACurrentMediaTime();
    _lastFrameTime = _startTime;
    _simAccum = 0;
    _smoothedFPS = 60;
    return self;
}

// ------------------------------------------------------------------- Path ---

- (simd_float2)pathPointAt:(float)dist {
    dist = std::clamp(dist, 0.0f, _pathLen);
    for (size_t i = 1; i < _waypoints.size(); i++) {
        if (dist <= _cumLen[i]) {
            float segLen = _cumLen[i] - _cumLen[i - 1];
            float f = segLen > 0 ? (dist - _cumLen[i - 1]) / segLen : 0;
            return _waypoints[i - 1] + (_waypoints[i] - _waypoints[i - 1]) * f;
        }
    }
    return _waypoints.back();
}

// -------------------------------------------------------------------- Sim ---

// ------------------------------------------------------------- Build UI ---

- (int)towerIndexAtTile:(int)tx ty:(int)ty {
    for (size_t i = 0; i < _towers.size(); i++)
        if (_towers[i].tx == tx && _towers[i].ty == ty) return (int)i;
    return -1;
}

- (BOOL)canBuildAt:(int)tx ty:(int)ty {
    if (tx < 0 || tx >= kTilesW || ty < 0 || ty >= kTilesH) return NO;
    if (_blocked[tx][ty]) return NO;
    return [self towerIndexAtTile:tx ty:ty] < 0;
}

- (void)clickAt:(simd_float2)world {
    int tx = (int)floorf(world.x), ty = (int)floorf(world.y);
    int ti = [self towerIndexAtTile:tx ty:ty];
    if (ti >= 0) {                          // upgrade existing tower
        Tower &tw = _towers[ti];
        if (tw.tier >= 2) { printf("%s is already max tier.\n", kTowers[tw.type].name); return; }
        int cost = kTowers[tw.type].upCost[tw.tier];
        if (_sparks < cost) { printf("Need %d Spark-Nodes to upgrade.\n", cost); return; }
        _sparks -= cost;
        tw.invested += cost;
        tw.tier++;
        [self ringBurst:simd_make_float2(tx + 0.5f, ty + 0.5f)
                  color:kTowers[tw.type].color count:14];
        return;
    }
    if (![self canBuildAt:tx ty:ty]) return;
    int cost = kTowers[_selectedType].buildCost;
    if (_sparks < cost) { printf("Need %d Spark-Nodes to build %s.\n", cost, kTowers[_selectedType].name); return; }
    _sparks -= cost;
    Tower tw;
    tw.type = _selectedType;
    tw.tier = 0;
    tw.tx = tx; tw.ty = ty;
    tw.invested = cost;
    tw.cooldown = 0;
    tw.aim = 0;
    _towers.push_back(tw);
    [self ringBurst:simd_make_float2(tx + 0.5f, ty + 0.5f)
              color:kTowers[_selectedType].color count:14];
}

- (void)sellAt:(simd_float2)world {
    int tx = (int)floorf(world.x), ty = (int)floorf(world.y);
    int ti = [self towerIndexAtTile:tx ty:ty];
    if (ti < 0) return;
    int refund = (int)(_towers[ti].invested * 0.75f);
    _sparks += refund;
    [self ringBurst:simd_make_float2(tx + 0.5f, ty + 0.5f)
              color:simd_make_float4(1.2f, 1.2f, 1.2f, 1.0f) count:10];
    printf("Sold %s for %d Spark-Nodes.\n", kTowers[_towers[ti].type].name, refund);
    _towers.erase(_towers.begin() + ti);
}

// --------------------------------------------------------------- Combat ---

- (int)enemyIndexById:(uint32_t)eid {
    for (size_t i = 0; i < _enemies.size(); i++)
        if (_enemies[i].id == eid && _enemies[i].alive) return (int)i;
    return -1;
}

- (simd_float2)enemyPos:(const Enemy &)e {
    return [self pathPointAt:e.dist];
}

- (void)ringBurst:(simd_float2)pos color:(simd_float4)col count:(int)n {
    std::uniform_real_distribution<float> u01(0.0f, 1.0f);
    for (int k = 0; k < n; k++) {
        Puff p;
        float ang = u01(_rng) * 6.2831853f;
        float spd = 1.5f + 3.5f * u01(_rng);
        p.pos = pos;
        p.vel = simd_make_float2(cosf(ang), sinf(ang)) * spd;
        p.age = 0;
        p.life = 0.35f + 0.5f * u01(_rng);
        p.size0 = 0.16f;
        p.size1 = 0.03f;
        p.color = col * (1.2f + 0.8f * u01(_rng));
        _puffs.push_back(p);
    }
}

- (void)damageEnemy:(int)i amount:(float)dmg type:(int)dmgType {
    Enemy &e = _enemies[i];
    if (!e.alive) return;
    if (dmgType == kDmgKinetic && kEnemyTypes[e.type].armored) dmg *= 0.5f;
    e.hp -= dmg;
    e.flash = 0.1f;
    if (e.hp <= 0) {
        e.alive = false;
        _sparks += kEnemyTypes[e.type].reward;
        [self ringBurst:[self enemyPos:e] color:kEnemyTypes[e.type].color count:26];
    }
}

// Pick the enemy furthest along the path within range ("first" targeting).
- (int)acquireTarget:(simd_float2)from range:(float)range {
    int best = -1;
    float bestDist = -1;
    for (size_t i = 0; i < _enemies.size(); i++) {
        const Enemy &e = _enemies[i];
        if (!e.alive) continue;
        if (simd_distance([self enemyPos:e], from) > range) continue;
        if (e.dist > bestDist) { bestDist = e.dist; best = (int)i; }
    }
    return best;
}

- (void)breachBurst:(simd_float2)pos {
    std::uniform_real_distribution<float> u01(0.0f, 1.0f);
    for (int k = 0; k < 34; k++) {
        Puff p;
        float ang = u01(_rng) * 6.2831853f;
        float spd = 2.0f + 4.0f * u01(_rng);
        p.pos = pos;
        p.vel = simd_make_float2(cosf(ang), sinf(ang)) * spd;
        p.age = 0;
        p.life = 0.4f + 0.6f * u01(_rng);
        p.size0 = 0.2f;
        p.size1 = 0.04f;
        p.color = simd_make_float4(2.2f, 0.25f, 0.2f, 1.0f);   // alarm red
        _puffs.push_back(p);
    }
}

- (void)simStep:(float)dt time:(float)t {
    // Demo wave director: alternating Bit swarms and Daemon rushes.
    _waveTimer -= dt;
    if (_waveTimer <= 0 && _spawnLeft == 0) {
        _waveNum++;
        _spawnLeft = 6 + _waveNum * 2;
        _spawnTimer = 0;
        _waveTimer = 14.0f;
    }
    if (_spawnLeft > 0) {
        _spawnTimer -= dt;
        if (_spawnTimer <= 0) {
            Enemy e;
            e.type = (_waveNum % 2 == 0) ? 1 : 0;
            std::uniform_real_distribution<float> u01(0.0f, 1.0f);
            if (_waveNum > 2 && u01(_rng) < 0.3f) e.type ^= 1;  // mix later waves
            e.id = _nextEnemyId++;
            e.dist = 0;
            e.hp = e.maxHp = kEnemyTypes[e.type].hp;
            e.slow = 0;
            e.flash = 0;
            e.wobble = u01(_rng) * 6.28f;
            e.alive = true;
            _enemies.push_back(e);
            _spawnLeft--;
            _spawnTimer = (e.type == 1) ? 0.4f : 0.6f;
        }
    }

    // Cryo auras: recompute each enemy's slow (strongest aura wins).
    for (Enemy &e : _enemies) e.slow = 0;
    for (const Tower &tw : _towers) {
        if (tw.type != kTowerCryo) continue;
        const TowerTier &tier = kTowers[tw.type].tiers[tw.tier];
        simd_float2 tp = simd_make_float2(tw.tx + 0.5f, tw.ty + 0.5f);
        for (Enemy &e : _enemies) {
            if (!e.alive) continue;
            if (simd_distance([self enemyPos:e], tp) <= tier.range)
                e.slow = std::max(e.slow, tier.slow);
        }
    }

    // March.
    for (size_t i = 0; i < _enemies.size(); i++) {
        Enemy &e = _enemies[i];
        if (!e.alive) continue;
        e.flash = std::max(0.0f, e.flash - dt);
        e.dist += kEnemyTypes[e.type].speed * (1.0f - e.slow) * dt;
        if (e.dist >= _pathLen) {
            e.alive = false;
            if (_integrity > 0) {
                _integrity--;
                [self breachBurst:_waypoints.back()];
                if (_integrity == 0) printf("*** CORE BREACHED — flatlined. ***\n");
            }
        }
    }

    // Towers fire.
    std::uniform_real_distribution<float> u01(0.0f, 1.0f);
    for (Tower &tw : _towers) {
        const TowerTier &tier = kTowers[tw.type].tiers[tw.tier];
        simd_float2 tp = simd_make_float2(tw.tx + 0.5f, tw.ty + 0.5f);
        tw.cooldown -= dt;
        if (tw.type == kTowerCryo) continue;   // aura handled above
        int ti = [self acquireTarget:tp range:tier.range];
        if (ti < 0) continue;
        simd_float2 ep = [self enemyPos:_enemies[ti]];
        tw.aim = atan2f(ep.y - tp.y, ep.x - tp.x);
        if (tw.cooldown > 0) continue;
        tw.cooldown = 1.0f / tier.rate;

        if (tw.type == kTowerSentry) {
            Projectile pr;
            pr.pos = tp;
            pr.targetId = _enemies[ti].id;
            pr.speed = 10.0f;
            pr.damage = tier.damage;
            pr.dmgType = kDmgKinetic;
            pr.color = kTowers[kTowerSentry].color;
            pr.alive = true;
            _projectiles.push_back(pr);
        } else if (tw.type == kTowerArc) {
            // Chain lightning: hit the target, then leap to nearest unhit.
            std::vector<int> hit;
            int cur = ti;
            simd_float2 from = tp;
            for (int c = 0; c < (int)tier.chains && cur >= 0; c++) {
                simd_float2 cp = [self enemyPos:_enemies[cur]];
                Beam b;
                b.a = from; b.b = cp;
                b.age = 0; b.life = 0.14f;
                b.seed = u01(_rng);
                b.color = kTowers[kTowerArc].color;
                _beams.push_back(b);
                [self damageEnemy:cur amount:tier.damage type:kDmgEnergy];
                hit.push_back(cur);
                from = cp;
                // next leap: nearest living enemy within 2.4 not already hit
                int next = -1;
                float bestD = 2.4f;
                for (size_t j = 0; j < _enemies.size(); j++) {
                    if (!_enemies[j].alive) continue;
                    if (std::find(hit.begin(), hit.end(), (int)j) != hit.end()) continue;
                    float d = simd_distance([self enemyPos:_enemies[j]], cp);
                    if (d < bestD) { bestD = d; next = (int)j; }
                }
                cur = next;
            }
        }
    }

    // Projectiles home on their target.
    for (Projectile &pr : _projectiles) {
        if (!pr.alive) continue;
        int ti = [self enemyIndexById:pr.targetId];
        if (ti < 0) { pr.alive = false; continue; }
        simd_float2 ep = [self enemyPos:_enemies[ti]];
        simd_float2 d = ep - pr.pos;
        float dist = simd_length(d);
        float step = pr.speed * dt;
        if (dist <= step + 0.18f) {
            [self damageEnemy:ti amount:pr.damage type:pr.dmgType];
            [self ringBurst:ep color:pr.color count:4];
            pr.alive = false;
        } else {
            pr.pos += d * (step / dist);
        }
    }
    _projectiles.erase(std::remove_if(_projectiles.begin(), _projectiles.end(),
                       [](const Projectile &p) { return !p.alive; }),
                       _projectiles.end());

    // Beams age out.
    for (Beam &b : _beams) b.age += dt;
    _beams.erase(std::remove_if(_beams.begin(), _beams.end(),
                 [](const Beam &b) { return b.age >= b.life; }),
                 _beams.end());

    // Particles.
    for (Puff &p : _puffs) {
        p.age += dt;
        p.pos += p.vel * dt;
        p.vel *= expf(-3.0f * dt);
    }
    _puffs.erase(std::remove_if(_puffs.begin(), _puffs.end(),
                 [](const Puff &p) { return p.age >= p.life; }),
                 _puffs.end());
    _enemies.erase(std::remove_if(_enemies.begin(), _enemies.end(),
                   [](const Enemy &e) { return !e.alive; }),
                   _enemies.end());
}

// ---------------------------------------------------------------- Render ---

- (void)pushInst:(simd_float2)c half:(simd_float2)h rot:(float)rot
           shape:(float)shape color:(simd_float4)col params:(simd_float4)pr {
    if ((int)_scratch.size() >= kMaxInstances) return;
    _scratch.push_back({c.x, c.y, h.x, h.y, rot, shape,
                        col.x, col.y, col.z, col.w,
                        pr.x, pr.y, pr.z, pr.w});
}

- (void)ensureTargets:(id<MTLDevice>)device size:(CGSize)size {
    NSUInteger w = (NSUInteger)size.width, h = (NSUInteger)size.height;
    if (w == 0 || h == 0) return;
    if (_sceneTex && _sceneTex.width == w && _sceneTex.height == h) return;

    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                           width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    _sceneTex = [device newTextureWithDescriptor:td];

    td.width = std::max<NSUInteger>(w / 4, 1);
    td.height = std::max<NSUInteger>(h / 4, 1);
    _bloomA = [device newTextureWithDescriptor:td];
    _bloomB = [device newTextureWithDescriptor:td];
}

- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor *drawPass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!drawPass || !drawable) return;

    double now = CACurrentMediaTime();
    float t = (float)(now - _startTime);
    float dtRaw = (float)(now - _lastFrameTime);
    _lastFrameTime = now;
    if (dtRaw > 0) _smoothedFPS += (1.0f / dtRaw - _smoothedFPS) * 0.05f;

    // Fixed-timestep simulation: deterministic and frame-rate independent.
    _simAccum += std::min(dtRaw, 0.25f);
    const double kStep = 1.0 / 120.0;
    while (_simAccum >= kStep) {
        [self simStep:(float)kStep time:t];
        _simAccum -= kStep;
    }

    [self ensureTargets:view.device size:view.drawableSize];
    if (!_sceneTex) return;

    // World -> NDC: fit the board with a margin, aspect-correct.
    float aspect = (float)(view.drawableSize.width / view.drawableSize.height);
    float s = std::min(2.0f * aspect / kBoardW, 2.0f / kBoardH) * 0.92f;
    _uScale = simd_make_float2(s / aspect, s);
    _uOffset = simd_make_float2(-kBoardW * 0.5f * s / aspect, -kBoardH * 0.5f * s);

    struct {
        simd_float2 scale, offset, resolution;
        float time, pad;
        simd_float4 fx;
    } uni = {
        _uScale, _uOffset,
        simd_make_float2((float)view.drawableSize.width, (float)view.drawableSize.height),
        t, 0,
        simd_make_float4(0.9f, 0.5f, 0.03f, 0.0f),   // bloom, aberration, scanline
    };

    // Track the hovered tile for the placement ghost.
    {
        NSPoint m = [view.window mouseLocationOutsideOfEventStream];
        NSPoint local = [view convertPoint:m fromView:nil];
        if (NSPointInRect(local, view.bounds)) {
            simd_float2 ndc = simd_make_float2(
                (float)(local.x / view.bounds.size.width) * 2.0f - 1.0f,
                (float)(local.y / view.bounds.size.height) * 2.0f - 1.0f);
            _hoverWorld = (ndc - _uOffset) / _uScale;
        } else {
            _hoverWorld = simd_make_float2(-100, -100);
        }
    }

    // ---- Build this frame's instances (everything additive, one draw).
    dispatch_semaphore_wait(_frameSemaphore, DISPATCH_TIME_FOREVER);
    _scratch.clear();

    // Hostile traffic pulses riding the road (the road itself is drawn by
    // the background shader).
    for (size_t i = 1; i < _waypoints.size(); i++) {
        simd_float2 a = _waypoints[i - 1], b = _waypoints[i];
        float len = simd_distance(a, b);
        [self pushInst:(a + b) * 0.5f
                  half:simd_make_float2(len * 0.5f, 0.34f)
                   rot:atan2f(b.y - a.y, b.x - a.x)
                 shape:6
                 color:simd_make_float4(2.3f, 1.0f, 0.18f, 1.0f)
                params:simd_make_float4(_cumLen[i - 1], len, 0, 0)];
    }

    // Breach portal (hostile, orange) + the Core (ours, cyan-white).
    float pulse = 0.75f + 0.25f * sinf(t * 3.0f);
    [self pushInst:_waypoints.front() half:simd_make_float2(0.55f, 0.55f) rot:t * 0.8f
             shape:1 color:simd_make_float4(2.0f, 0.8f, 0.15f, 1.0f) * pulse
            params:simd_make_float4(0, 0, 0, 0)];
    simd_float2 core = _waypoints.back();
    [self pushInst:core half:simd_make_float2(0.95f, 0.95f) rot:t * 0.35f
             shape:3 color:simd_make_float4(0.9f, 1.8f, 2.2f, 1.0f) * pulse
            params:simd_make_float4(0, 0, 0, 0)];
    [self pushInst:core half:simd_make_float2(0.45f, 0.45f) rot:0
             shape:0 color:simd_make_float4(1.2f, 1.7f, 2.0f, 1.0f)
            params:simd_make_float4(0, 0, 0, 0)];

    // Towers.
    for (const Tower &tw : _towers) {
        const TowerSpec &spec = kTowers[tw.type];
        simd_float2 tp = simd_make_float2(tw.tx + 0.5f, tw.ty + 0.5f);
        if (tw.type == kTowerSentry) {
            [self pushInst:tp half:simd_make_float2(0.34f, 0.34f) rot:0
                     shape:5 color:spec.color * 1.1f params:simd_make_float4(0, 0, 0, 0)];
            [self pushInst:tp half:simd_make_float2(0.34f, 0.07f) rot:tw.aim
                     shape:4 color:spec.color * 1.5f params:simd_make_float4(0, 0, 0, 0)];
        } else if (tw.type == kTowerArc) {
            [self pushInst:tp half:simd_make_float2(0.36f, 0.36f) rot:t * 1.5f
                     shape:1 color:spec.color params:simd_make_float4(0, 0, 0, 0)];
            [self pushInst:tp half:simd_make_float2(0.14f, 0.14f) rot:0
                     shape:0 color:spec.color * (1.1f + 0.5f * sinf(t * 7.0f))
                    params:simd_make_float4(0, 0, 0, 0)];
        } else {
            [self pushInst:tp half:simd_make_float2(0.36f, 0.36f) rot:t * 0.6f
                     shape:3 color:spec.color params:simd_make_float4(0, 0, 0, 0)];
            const TowerTier &tier = spec.tiers[tw.tier];
            float ap = 0.55f + 0.45f * sinf(t * 2.2f);
            [self pushInst:tp half:simd_make_float2(tier.range, tier.range) rot:0
                     shape:8 color:spec.color * (0.28f * ap)
                    params:simd_make_float4(0, 0, 0, 0)];
        }
        // Tier pips under the base.
        for (int k = 0; k <= tw.tier; k++) {
            [self pushInst:simd_make_float2(tp.x - 0.22f + 0.22f * k, tp.y - 0.44f)
                      half:simd_make_float2(0.05f, 0.05f) rot:0
                     shape:0 color:spec.color * 1.3f params:simd_make_float4(0, 0, 0, 0)];
        }
    }

    // Placement ghost + range ring at the hovered tile.
    {
        int tx = (int)floorf(_hoverWorld.x), ty = (int)floorf(_hoverWorld.y);
        int hoverTower = [self towerIndexAtTile:tx ty:ty];
        if (hoverTower >= 0) {
            const Tower &tw = _towers[hoverTower];
            const TowerTier &tier = kTowers[tw.type].tiers[tw.tier];
            if (tw.type != kTowerCryo) {
                [self pushInst:simd_make_float2(tw.tx + 0.5f, tw.ty + 0.5f)
                          half:simd_make_float2(tier.range, tier.range) rot:0
                         shape:8 color:kTowers[tw.type].color * 0.6f
                        params:simd_make_float4(0, 0, 0, 0)];
            }
        } else if (tx >= 0 && tx < kTilesW && ty >= 0 && ty < kTilesH) {
            BOOL ok = [self canBuildAt:tx ty:ty] &&
                      _sparks >= kTowers[_selectedType].buildCost;
            simd_float2 c = simd_make_float2(tx + 0.5f, ty + 0.5f);
            simd_float4 gcol = ok ? kTowers[_selectedType].color * 0.55f
                                  : simd_make_float4(1.6f, 0.25f, 0.15f, 1.0f) * 0.55f;
            [self pushInst:c half:simd_make_float2(0.4f, 0.4f) rot:0
                     shape:4 color:gcol params:simd_make_float4(0, 0, 0, 0)];
            if (ok) {
                const TowerTier &tier = kTowers[_selectedType].tiers[0];
                [self pushInst:c half:simd_make_float2(tier.range, tier.range) rot:0
                         shape:8 color:gcol params:simd_make_float4(0, 0, 0, 0)];
            }
        }
    }

    // Lightning beams.
    for (const Beam &b : _beams) {
        simd_float2 mid = (b.a + b.b) * 0.5f;
        float len = simd_distance(b.a, b.b);
        float fade = 1.0f - b.age / b.life;
        [self pushInst:mid half:simd_make_float2(len * 0.5f, 0.22f)
                   rot:atan2f(b.b.y - b.a.y, b.b.x - b.a.x)
                 shape:7 color:b.color * (fade * 1.6f)
                params:simd_make_float4(b.seed, 0, 0, 0)];
    }

    // Projectiles: bright tracer bolts.
    for (const Projectile &pr : _projectiles) {
        [self pushInst:pr.pos half:simd_make_float2(0.10f, 0.10f) rot:0
                 shape:0 color:pr.color * 1.8f params:simd_make_float4(0, 0, 0, 0)];
    }

    // Enemies: orange programs with a hot core; icy when slowed, flash on hit.
    for (const Enemy &e : _enemies) {
        if (!e.alive) continue;
        const EnemyType &et = kEnemyTypes[e.type];
        simd_float2 pos = [self pathPointAt:e.dist];
        pos.y += 0.06f * sinf(t * 6.0f + e.wobble);
        simd_float4 col = et.color;
        if (e.slow > 0) {   // frost tint toward ice blue
            simd_float4 ice = simd_make_float4(0.5f, 1.3f, 2.0f, 1.0f);
            col = col + (ice - col) * (e.slow * 0.8f);
        }
        if (e.flash > 0) col = col + simd_make_float4(1.5f, 1.5f, 1.5f, 0.0f) * (e.flash * 10.0f);
        [self pushInst:pos half:simd_make_float2(et.radius, et.radius)
                   rot:t * 2.2f + e.wobble shape:2 color:col
                params:simd_make_float4(0, 0, 0, 0)];
        [self pushInst:pos half:simd_make_float2(et.radius * 0.4f, et.radius * 0.4f)
                   rot:0 shape:0 color:simd_make_float4(1.7f, 1.5f, 1.2f, 1.0f)
                params:simd_make_float4(0, 0, 0, 0)];
        // HP bar once damaged.
        if (e.hp < e.maxHp) {
            float frac = std::max(e.hp / e.maxHp, 0.0f);
            simd_float2 barPos = simd_make_float2(pos.x, pos.y + et.radius + 0.18f);
            [self pushInst:barPos half:simd_make_float2(0.3f, 0.045f) rot:0
                     shape:4 color:simd_make_float4(0.25f, 0.05f, 0.02f, 1.0f)
                    params:simd_make_float4(0, 0, 0, 0)];
            [self pushInst:simd_make_float2(barPos.x - 0.3f * (1.0f - frac), barPos.y)
                      half:simd_make_float2(0.3f * frac, 0.045f) rot:0
                     shape:4 color:simd_make_float4(1.8f, 0.6f, 0.1f, 1.0f)
                    params:simd_make_float4(0, 0, 0, 0)];
        }
    }

    // Particles.
    for (const Puff &p : _puffs) {
        float f = p.age / p.life;
        float size = p.size0 + (p.size1 - p.size0) * f;
        simd_float4 col = p.color * (1.0f - f);
        [self pushInst:p.pos half:simd_make_float2(size, size) rot:0
                 shape:0 color:col params:simd_make_float4(0, 0, 0, 0)];
    }

    id<MTLBuffer> instBuf = _instBuffers[_frameIndex];
    NSUInteger instCount = _scratch.size();
    if (instCount > 0)
        memcpy([instBuf contents], _scratch.data(), instCount * sizeof(EInstC));

    // ---- Passes.
    id<MTLCommandBuffer> commands = [_queue commandBuffer];

    // 1) Scene (HDR): background, then all neon instances.
    MTLRenderPassDescriptor *scenePass = [MTLRenderPassDescriptor renderPassDescriptor];
    scenePass.colorAttachments[0].texture = _sceneTex;
    scenePass.colorAttachments[0].loadAction = MTLLoadActionClear;
    scenePass.colorAttachments[0].storeAction = MTLStoreActionStore;
    scenePass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    {
        id<MTLRenderCommandEncoder> enc =
            [commands renderCommandEncoderWithDescriptor:scenePass];
        [enc setRenderPipelineState:_bgPipeline];
        [enc setFragmentBytes:&uni length:sizeof(uni) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        if (instCount > 0) {
            [enc setRenderPipelineState:_entityPipeline];
            [enc setVertexBuffer:instBuf offset:0 atIndex:0];
            [enc setVertexBytes:&uni length:sizeof(uni) atIndex:1];
            [enc setFragmentBytes:&uni length:sizeof(uni) atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                    vertexCount:6 instanceCount:instCount];
        }
        [enc endEncoding];
    }

    // 2) Bright-pass into quarter-res bloom A.
    MTLRenderPassDescriptor *p2 = [MTLRenderPassDescriptor renderPassDescriptor];
    p2.colorAttachments[0].texture = _bloomA;
    p2.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    p2.colorAttachments[0].storeAction = MTLStoreActionStore;
    {
        id<MTLRenderCommandEncoder> enc = [commands renderCommandEncoderWithDescriptor:p2];
        [enc setRenderPipelineState:_brightPipeline];
        [enc setFragmentTexture:_sceneTex atIndex:0];
        [enc setFragmentSamplerState:_sampler atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
    }

    // 3) Separable blur, two iterations for a wide cinematic halo:
    //    A -> B -> A -> B -> A (H,V,H,V).
    for (int pass = 0; pass < 4; pass++) {
        MTLRenderPassDescriptor *pp = [MTLRenderPassDescriptor renderPassDescriptor];
        pp.colorAttachments[0].texture = (pass == 0) ? _bloomB : _bloomA;
        pp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        pp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [commands renderCommandEncoderWithDescriptor:pp];
        [enc setRenderPipelineState:_blurPipeline];
        [enc setFragmentTexture:(pass == 0) ? _bloomA : _bloomB atIndex:0];
        [enc setFragmentSamplerState:_sampler atIndex:0];
        simd_float2 dir = (pass == 0) ? simd_make_float2(1, 0) : simd_make_float2(0, 1);
        [enc setFragmentBytes:&dir length:sizeof(dir) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
    }

    // 4) Composite to the drawable: scene + bloom + scanlines/aberration.
    {
        id<MTLRenderCommandEncoder> enc =
            [commands renderCommandEncoderWithDescriptor:drawPass];
        [enc setRenderPipelineState:_compositePipeline];
        [enc setFragmentTexture:_sceneTex atIndex:0];
        [enc setFragmentTexture:_bloomA atIndex:1];
        [enc setFragmentSamplerState:_sampler atIndex:0];
        [enc setFragmentBytes:&uni length:sizeof(uni) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
    }

    dispatch_semaphore_t sem = _frameSemaphore;
    [commands addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        (void)cb;
        dispatch_semaphore_signal(sem);
    }];
    [commands presentDrawable:drawable];
    [commands commit];
    _frameIndex = (_frameIndex + 1) % kMaxInFlight;

    view.window.title = [NSString stringWithFormat:
        @"07 — NET BREACH ▸ ⚡%d ▸ Integrity %d ▸ Wave %d ▸ Building: %s [1/2/3] ▸ %.0f fps",
        _sparks, _integrity, _waveNum, kTowers[_selectedType].name, _smoothedFPS];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

@end

int main() {
    return RunMetalApp(@"07 — NET BREACH", 1280, 760, ^(MTKView *view) {
        return (NSObject<MTKViewDelegate> *)[[NetBreachRenderer alloc] initWithView:view];
    });
}
