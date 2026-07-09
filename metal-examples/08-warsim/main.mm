// 08 — WAR SIM (TABS-style battle simulator, v1)
//
// Paint two armies on a battlefield, hit SPACE, and watch them clash until
// one side is annihilated. Thousands of little procedural soldiers — no art
// assets, every character is SDF shapes on an instanced billboard.
//
//   * Four unit types with distinct silhouettes and combat behavior:
//       1 Infantry   sword & shield line troops
//       2 Archer     ballistic arrow volleys, weak up close
//       3 Cavalry    fast; heavy bonus damage on the charge
//       4 Berserker  huge damage, no armor
//   * Setup phase: pick a type (1-4), click/drag to stamp squads — LEFT half
//     of the field paints RED, RIGHT half paints BLUE. Right-click erases.
//   * SPACE starts the battle. R resets to an empty field. D re-deploys the
//     default armies.
//   * Sim: fixed 60 Hz, spatial-hash targeting and separation, melee with
//     cooldowns, arrows on true ballistic arcs, charge bonuses, blood,
//     corpses and ground splats. Last army standing wins.
//
// Rendering: tilted perspective battle-cam onto a ground plane; units are
// alpha-tested camera-facing billboards (depth-correct, no sorting); shadows,
// splats and corpses are flat decals; blood is soft particles.

#include "../common/app.h"
#include <simd/simd.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <random>
#include <string>
#include <vector>

// ---------------------------------------------------------------- Tuning ---

static const float kFieldW = 140.0f;   // meters
static const float kFieldH = 80.0f;
static const float kNoMansMin = 58.0f; // deploy zones end here...
static const float kNoMansMax = 82.0f; // ...and resume here
static const int kMaxUnits = 3000;
static const int kMaxBillboards = 8192;
static const int kMaxFlats = 12288;
static const int kMaxInFlight = 3;

enum { kInfantry = 0, kArcher = 1, kCavalry = 2, kBerserker = 3, kUnitTypeCount = 4 };
enum { kPhaseSetup = 0, kPhaseBattle = 1, kPhaseDone = 2 };

struct UnitSpec {
    const char *name;
    float hp, damage, reach, speed, radius, cooldown;
    float width, height;      // billboard size (m)
};
static const UnitSpec kSpecs[kUnitTypeCount] = {
    {"Infantry",  100, 22, 0.9f, 2.6f, 0.35f, 1.00f, 1.15f, 1.45f},
    {"Archer",     55,  8, 0.8f, 2.8f, 0.30f, 1.20f, 1.00f, 1.40f},
    {"Cavalry",   160, 30, 1.2f, 7.5f, 0.55f, 1.10f, 2.10f, 1.90f},
    {"Berserker", 140, 45, 1.0f, 3.4f, 0.40f, 0.90f, 1.30f, 1.55f},
};
static const float kArcherRange = 26.0f;
static const float kArcherReload = 2.4f;
static const float kArrowDamage = 28.0f;
static const float kChargeSpeed = 5.5f;   // cavalry above this speed => charge hit
static const float kChargeMult = 3.0f;

static const simd_float4 kArmyColor[2] = {
    {0.80f, 0.16f, 0.12f, 1.0f},   // RED
    {0.15f, 0.35f, 0.85f, 1.0f},   // BLUE
};

// ---------------------------------------------------------------- Shaders ---

static const char *kShaderSource = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct Uni {
    float4x4 viewProj;
    float2 resolution;
    float time;
    float phase;      // 0 setup, 1 battle, 2 done
};

float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), f.x),
               mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), f.x), f.y);
}

float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 3; i++) { v += a * vnoise(p); p *= 2.17; a *= 0.5; }
    return v;
}

float3 gammaOut(float3 c) { return pow(max(c, 0.0), float3(0.4545)); }

// ---------------- Ground ----------------
// One big quad; fragment paints grass, the worn battle strip, and (during
// setup) the two deploy zones. Board coords: x 0..140, z 0..80 -> world
// (x, 0, -z).

struct GroundVSOut {
    float4 position [[position]];
    float2 w;          // board coords (x, z)
};

constant float2 kGroundCorners[6] = {
    float2(-160, -120), float2(300, -120), float2(300, 200),
    float2(-160, -120), float2(300, 200), float2(-160, 200),
};

vertex GroundVSOut ground_vertex(uint vid [[vertex_id]],
                                 constant Uni &u [[buffer(0)]]) {
    float2 b = kGroundCorners[vid];
    GroundVSOut o;
    o.position = u.viewProj * float4(b.x, 0.0, -b.y, 1.0);
    o.w = b;
    return o;
}

fragment float4 ground_fragment(GroundVSOut in [[stage_in]],
                                constant Uni &u [[buffer(0)]]) {
    float2 w = in.w;

    // Grass with large + small mottling.
    float n1 = fbm(w * 0.05);
    float n2 = fbm(w * 0.35 + 17.0);
    float3 grass = mix(float3(0.13, 0.24, 0.08), float3(0.22, 0.34, 0.12), n1);
    grass *= 0.85 + 0.3 * n2;

    // Worn dirt strip where the armies meet, plus scattered bare patches.
    float mid = smoothstep(18.0, 4.0, abs(w.x - 70.0));
    float patches = smoothstep(0.62, 0.75, fbm(w * 0.13 + 41.0));
    float dirtAmt = max(mid * 0.7, patches * 0.5);
    float3 dirt = float3(0.30, 0.24, 0.15) * (0.8 + 0.3 * n2);
    float3 col = mix(grass, dirt, dirtAmt);

    // Field boundary: fade to darker wilds outside.
    float2 bd = max(float2(0.0, 0.0) - w, w - float2(140.0, 80.0));
    float outside = max(max(bd.x, bd.y), 0.0);
    col *= 1.0 / (1.0 + outside * 0.12);

    // Deploy zones during setup: faint team tint + boundary lines.
    if (u.phase < 0.5) {
        float inField = step(0.0, w.y) * step(w.y, 80.0);
        float red = step(0.0, w.x) * step(w.x, 58.0);
        float blue = step(82.0, w.x) * step(w.x, 140.0);
        col += float3(0.10, 0.01, 0.01) * red * inField;
        col += float3(0.01, 0.02, 0.10) * blue * inField;
        float lineA = smoothstep(0.5, 0.1, abs(w.x - 58.0));
        float lineB = smoothstep(0.5, 0.1, abs(w.x - 82.0));
        col += float3(0.25) * (lineA + lineB) * inField;
    }

    // Simple sun falloff + vignette toward far edges.
    col *= 0.9 + 0.2 * smoothstep(120.0, 0.0, length(w - float2(70.0, 30.0)));

    return float4(gammaOut(col), 1.0);
}

// ---------------- Flat decals (shadows, splats, corpses) ----------------

struct FInst {
    packed_float2 center;    // board coords
    packed_float2 half2;
    float rot;
    float shape;             // 0 soft ellipse, 1 blood splat, 2 corpse
    packed_float4 color;
    packed_float4 params;    // x seed
};

struct FOut {
    float4 position [[position]];
    float2 lp;
    float4 color;
    float4 params;
    float shape;
};

constant float2 kCorners[6] = {
    float2(-1, -1), float2(1, -1), float2(1, 1),
    float2(-1, -1), float2(1, 1), float2(-1, 1),
};

vertex FOut flat_vertex(uint vid [[vertex_id]],
                        uint iid [[instance_id]],
                        const device FInst *insts [[buffer(0)]],
                        constant Uni &u [[buffer(1)]]) {
    FInst inst = insts[iid];
    float2 lp = kCorners[vid];
    float2 p = lp * float2(inst.half2);
    float cs = cos(inst.rot), sn = sin(inst.rot);
    float2 b = float2(inst.center) + float2(p.x * cs - p.y * sn, p.x * sn + p.y * cs);
    FOut o;
    o.position = u.viewProj * float4(b.x, 0.02, -b.y, 1.0);
    o.lp = lp;
    o.color = float4(inst.color);
    o.params = float4(inst.params);
    o.shape = inst.shape;
    return o;
}

fragment float4 flat_fragment(FOut in [[stage_in]]) {
    float2 p = in.lp;
    float a = 0.0;
    int shape = int(in.shape + 0.5);
    if (shape == 0) {                      // soft ellipse (contact shadow)
        a = smoothstep(1.0, 0.35, length(p));
    } else if (shape == 1) {               // blood splat: noisy blob
        float r = length(p);
        float n = fbm(p * 2.5 + in.params.x * 19.0);
        a = smoothstep(0.9, 0.25, r + (n - 0.5) * 0.8);
    } else if (shape == 2) {               // corpse: lumpy lozenge
        float2 q = float2(p.x, p.y * 2.2);
        float n = fbm(p * 3.0 + in.params.x * 7.0);
        a = smoothstep(1.0, 0.6, length(q) + (n - 0.5) * 0.35);
    }
    float alpha = a * in.color.a;
    return float4(gammaOut(in.color.rgb) * alpha, alpha);
}

// ---------------- Unit billboards ----------------
// Camera-facing quads standing on the ground. Alpha-tested (discard) so the
// depth buffer sorts them — no CPU sorting needed.

struct BInst {
    float px, pz;        // feet position (board coords)
    float yoff;          // bob / sink
    float w, h;          // billboard size
    float rot;           // in-plane rotation (death fall)
    float shape;         // unit type, 4 = arrow, 5 = blood puff
    float facing;        // +1 faces +x, -1 faces -x
    packed_float4 color; // army color
    float flash;         // attack flash 0..1
    float seed;
    float pad0, pad1;
};

struct BOut {
    float4 position [[position]];
    float2 lp;
    float4 color;
    float shape;
    float facing;
    float flash;
    float seed;
};

vertex BOut unit_vertex(uint vid [[vertex_id]],
                        uint iid [[instance_id]],
                        const device BInst *insts [[buffer(0)]],
                        constant Uni &u [[buffer(1)]]) {
    BInst inst = insts[iid];
    float2 lp = kCorners[vid];
    float2 q = lp * float2(inst.w, inst.h) * 0.5;
    float cs = cos(inst.rot), sn = sin(inst.rot);
    q = float2(q.x * cs - q.y * sn, q.x * sn + q.y * cs);
    float3 wp = float3(inst.px + q.x,
                       inst.h * 0.5 + q.y + inst.yoff,
                       -inst.pz);
    BOut o;
    o.position = u.viewProj * float4(wp, 1.0);
    o.lp = lp;
    o.color = float4(inst.color);
    o.shape = inst.shape;
    o.facing = inst.facing;
    o.flash = inst.flash;
    o.seed = inst.seed;
    return o;
}

float sdSeg(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    float t = clamp(dot(p - a, ab) / dot(ab, ab), 0.0, 1.0);
    return length(p - a - ab * t);
}

// Layered little characters. p is -1..1 with feet at y=-1, head at y=+1.
fragment float4 unit_fragment(BOut in [[stage_in]],
                              constant Uni &u [[buffer(0)]]) {
    float2 p = in.lp;
    p.x *= in.facing;                    // mirror to face the enemy
    int shape = int(in.shape + 0.5);
    float3 army = in.color.rgb;
    const float3 skin = float3(0.85, 0.62, 0.45);
    const float3 steel = float3(0.55, 0.58, 0.62);
    const float3 dark = float3(0.13, 0.10, 0.08);
    const float3 wood = float3(0.35, 0.22, 0.10);

    float cov = 0.0;
    float3 col = army;

    if (shape == 5) {                    // blood puff (soft; drawn additively)
        float r = length(p);
        float a = smoothstep(1.0, 0.0, r);
        a *= a * in.color.a;
        return float4(gammaOut(float3(0.45, 0.02, 0.01)) * a, a * 0.85);
    }

    if (shape == 4) {                    // arrow
        float sh = sdSeg(p, float2(-0.9, 0.0), float2(0.7, 0.0));
        float head = sdSeg(p, float2(0.7, 0.0), float2(0.95, 0.0));
        cov = step(sh, 0.10) + step(head, 0.18);
        col = mix(wood, steel, step(0.5, p.x));
        if (cov < 0.5) discard_fragment();
        return float4(gammaOut(col * 0.9), 1.0);
    }

    // --- soldiers ---
    float body = 0.0, headC = 0.0, gear = 0.0, gearC = 0.0;
    float3 gearCol = steel;

    if (shape == 2) {                    // CAVALRY: horse + rider
        // horse body
        float horse = step(sdSeg(p, float2(-0.45, -0.42), float2(0.35, -0.42)), 0.30);
        // neck + head
        horse += step(sdSeg(p, float2(0.35, -0.35), float2(0.62, -0.05)), 0.14);
        horse += step(length((p - float2(0.70, 0.02)) * float2(1.0, 1.4)), 0.16);
        // legs
        horse += step(sdSeg(p, float2(-0.42, -0.55), float2(-0.45, -0.98)), 0.06);
        horse += step(sdSeg(p, float2(0.30, -0.55), float2(0.33, -0.98)), 0.06);
        horse += step(sdSeg(p, float2(-0.15, -0.55), float2(-0.16, -0.95)), 0.055);
        horse += step(sdSeg(p, float2(0.08, -0.55), float2(0.09, -0.95)), 0.055);
        // rider torso + head
        body = step(sdSeg(p, float2(-0.10, -0.15), float2(-0.10, 0.38)), 0.17);
        headC = step(length(p - float2(-0.10, 0.58)), 0.15);
        // lance
        gear = step(sdSeg(p, float2(-0.05, 0.05), float2(0.85, 0.42)), 0.045);
        gearCol = wood;
        float horseCov = min(horse, 1.0);
        cov = max(max(horseCov, body), max(headC, gear));
        col = float3(0.24, 0.16, 0.10);                       // horse coat
        col = mix(col, army, body);                            // rider tunic
        col = mix(col, skin, headC);
        col = mix(col, gearCol, gear * (1.0 - body));
        // saddle blanket in army color
        float blanket = step(sdSeg(p, float2(-0.28, -0.40), float2(0.10, -0.40)), 0.20)
                      * step(horseCov, 1.5);
        col = mix(col, army * 0.8, blanket * horseCov * (1.0 - body) * (1.0 - gear));
    } else {
        // biped: torso capsule
        float tw = (shape == 3) ? 0.30 : 0.24;                 // berserker broader
        body = step(sdSeg(p, float2(0.0, -0.30), float2(0.0, 0.28)), tw);
        // legs
        body = max(body, step(sdSeg(p, float2(-0.10, -0.35), float2(-0.14, -0.95)), 0.09));
        body = max(body, step(sdSeg(p, float2(0.10, -0.35), float2(0.14, -0.95)), 0.09));
        headC = step(length(p - float2(0.0, 0.52)), 0.18);

        if (shape == 0) {                // INFANTRY: shield + sword
            gear = step(max(abs(p.x - 0.34) - 0.10, abs(p.y - 0.02) - 0.30), 0.0);
            gearCol = steel;
            gearC = step(sdSeg(p, float2(0.18, 0.30), float2(0.62, 0.78)), 0.05);
        } else if (shape == 1) {         // ARCHER: bow arc
            float r = length(p - float2(0.42, 0.05));
            gear = step(abs(r - 0.38), 0.045) * step(-0.15, p.x - 0.42);
            gearCol = wood;
            gearC = step(sdSeg(p, float2(0.42, -0.33), float2(0.42, 0.43)), 0.028);
        } else {                         // BERSERKER: axe
            gearC = step(sdSeg(p, float2(0.22, 0.10), float2(0.58, 0.66)), 0.055);
            gear = step(length((p - float2(0.66, 0.72)) * float2(1.0, 1.6)), 0.20);
            gearCol = steel;
        }
        cov = max(max(body, headC), max(gear, gearC));
        col = army;
        col = mix(col, skin, headC);
        // helmet for infantry/berserker
        if (shape != 1) {
            float helm = step(length(p - float2(0.0, 0.58)), 0.17) * step(0.52, p.y);
            col = mix(col, steel * 0.9, helm);
        }
        col = mix(col, gearCol, max(gear, 0.0) * (1.0 - body * 0.0));
        col = mix(col, (shape == 1) ? wood : steel, gearC);
    }

    if (cov < 0.5) discard_fragment();

    // Cheap shading: darker at feet, sun from upper-left, attack flash.
    float shade = 0.72 + 0.28 * smoothstep(-1.0, 1.0, p.y);
    shade *= 1.0 - 0.15 * smoothstep(0.0, 0.8, p.x * in.facing);
    col *= shade;
    col += float3(1.0, 0.95, 0.8) * in.flash * 0.6;
    return float4(gammaOut(col), 1.0);
}
)METAL";

// ------------------------------------------------------------- CPU mirror ---

struct FInstC {
    float cx, cy, hx, hy, rot, shape;
    float r, g, b, a;
    float p0, p1, p2, p3;
};
struct BInstC {
    float px, pz, yoff, w, h, rot, shape, facing;
    float r, g, b, a;
    float flash, seed, pad0, pad1;
};

struct Unit {
    simd_float2 pos, vel;
    int army, type;
    float hp;
    float cooldown;        // melee swing / arrow reload
    float retarget;        // time until next target search
    int target;            // index into units, -1 none
    float attackAnim;      // 0..1 flash after a swing
    float bobPhase;
    float deathT;          // >0 once dying; grows
    float seed;
    bool alive;
};

struct Arrow {
    simd_float3 pos, vel;
    int army;
    bool alive;
};

struct Blood {
    simd_float2 pos;
    float y;
    simd_float2 vel;
    float vy;
    float age, life, size;
    bool ground;           // splat spawned?
};

struct Splat {
    simd_float2 pos;
    float size, seed, age;
};

// --------------------------------------------------------------- Matrices ---

static simd_float4x4 Perspective(float fovy, float aspect, float nearZ, float farZ) {
    float ys = 1.0f / tanf(fovy * 0.5f);
    float xs = ys / aspect;
    float zs = farZ / (nearZ - farZ);
    return simd_matrix(simd_make_float4(xs, 0, 0, 0),
                       simd_make_float4(0, ys, 0, 0),
                       simd_make_float4(0, 0, zs, -1),
                       simd_make_float4(0, 0, nearZ * zs, 0));
}

static simd_float4x4 LookAt(simd_float3 eye, simd_float3 right, simd_float3 up, simd_float3 fwd) {
    return simd_matrix(
        simd_make_float4(right.x, up.x, -fwd.x, 0),
        simd_make_float4(right.y, up.y, -fwd.y, 0),
        simd_make_float4(right.z, up.z, -fwd.z, 0),
        simd_make_float4(-simd_dot(right, eye), -simd_dot(up, eye), simd_dot(fwd, eye), 1));
}

// --------------------------------------------------------------- Renderer ---

@interface WarSimRenderer : NSObject <MTKViewDelegate>
- (instancetype)initWithView:(MTKView *)view;
@end

@implementation WarSimRenderer {
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _groundPipeline;
    id<MTLRenderPipelineState> _flatPipeline;    // decals: over, no depth write
    id<MTLRenderPipelineState> _unitPipeline;    // alpha-test billboards
    id<MTLDepthStencilState> _depthWrite;
    id<MTLDepthStencilState> _depthTest;

    id<MTLBuffer> _flatBuffers[kMaxInFlight];
    id<MTLBuffer> _unitBuffers[kMaxInFlight];
    int _frameIndex;
    dispatch_semaphore_t _frameSemaphore;
    std::vector<FInstC> _flatScratch;
    std::vector<BInstC> _unitScratch;

    // Game
    std::vector<Unit> _units;
    std::vector<Arrow> _arrows;
    std::vector<Blood> _blood;
    std::vector<Splat> _splats;
    std::vector<std::vector<int>> _grid;   // spatial hash buckets
    int _gridW, _gridH;
    float _cellSize;
    int _phase;
    int _selectedType;
    int _winner;
    std::mt19937 _rng;

    simd_float4x4 _viewProj;
    bool _haveVP;
    simd_float2 _lastPaint;

    double _startTime, _lastFrameTime;
    double _simAccum;
    float _smoothedFPS;
}

- (instancetype)initWithView:(MTKView *)view {
    if (!(self = [super init])) return nil;

    id<MTLDevice> device = view.device;
    _queue = [device newCommandQueue];
    view.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    view.clearColor = MTLClearColorMake(0.35, 0.42, 0.50, 1.0);   // haze past field

    id<MTLLibrary> library = CompileLibrary(device, kShaderSource);
    if (!library) return nil;

    NSError *error = nil;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    d.depthAttachmentPixelFormat = view.depthStencilPixelFormat;

    d.vertexFunction = [library newFunctionWithName:@"ground_vertex"];
    d.fragmentFunction = [library newFunctionWithName:@"ground_fragment"];
    _groundPipeline = [device newRenderPipelineStateWithDescriptor:d error:&error];
    if (!_groundPipeline) { fprintf(stderr, "ground: %s\n", error.localizedDescription.UTF8String); return nil; }

    d.vertexFunction = [library newFunctionWithName:@"flat_vertex"];
    d.fragmentFunction = [library newFunctionWithName:@"flat_fragment"];
    d.colorAttachments[0].blendingEnabled = YES;
    d.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    d.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    _flatPipeline = [device newRenderPipelineStateWithDescriptor:d error:&error];
    if (!_flatPipeline) { fprintf(stderr, "flat: %s\n", error.localizedDescription.UTF8String); return nil; }

    d.vertexFunction = [library newFunctionWithName:@"unit_vertex"];
    d.fragmentFunction = [library newFunctionWithName:@"unit_fragment"];
    _unitPipeline = [device newRenderPipelineStateWithDescriptor:d error:&error];
    if (!_unitPipeline) { fprintf(stderr, "unit: %s\n", error.localizedDescription.UTF8String); return nil; }

    MTLDepthStencilDescriptor *ds = [MTLDepthStencilDescriptor new];
    ds.depthCompareFunction = MTLCompareFunctionLess;
    ds.depthWriteEnabled = YES;
    _depthWrite = [device newDepthStencilStateWithDescriptor:ds];
    ds.depthWriteEnabled = NO;
    ds.depthCompareFunction = MTLCompareFunctionLessEqual;
    _depthTest = [device newDepthStencilStateWithDescriptor:ds];

    for (int i = 0; i < kMaxInFlight; i++) {
        _flatBuffers[i] = [device newBufferWithLength:kMaxFlats * sizeof(FInstC)
                                              options:MTLResourceStorageModeShared];
        _unitBuffers[i] = [device newBufferWithLength:kMaxBillboards * sizeof(BInstC)
                                              options:MTLResourceStorageModeShared];
    }
    _frameIndex = 0;
    _frameSemaphore = dispatch_semaphore_create(kMaxInFlight);
    _flatScratch.reserve(kMaxFlats);
    _unitScratch.reserve(kMaxBillboards);

    _cellSize = 2.5f;
    _gridW = (int)ceilf(kFieldW / _cellSize);
    _gridH = (int)ceilf(kFieldH / _cellSize);
    _grid.resize((size_t)_gridW * _gridH);

    _phase = kPhaseSetup;
    _selectedType = kInfantry;
    _winner = -1;
    _rng.seed(20250709);
    _haveVP = false;
    _lastPaint = simd_make_float2(-1000, -1000);
    [self deployDefaultArmies];

    __unsafe_unretained WarSimRenderer *weakSelf = self;
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                          handler:^NSEvent *(NSEvent *event) {
        if (event.modifierFlags & NSEventModifierFlagCommand) return event;
        unsigned short c = event.keyCode;
        if (c >= 18 && c <= 21) { weakSelf->_selectedType = c - 18; return nil; }  // 1..4
        if (c == 49) { [weakSelf pressedSpace]; return nil; }                      // space
        if (c == 15) { [weakSelf resetField:YES]; return nil; }                    // R
        if (c == 2)  { [weakSelf resetField:NO]; [weakSelf deployDefaultArmies]; return nil; } // D
        return event;
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseDown |
                                                   NSEventMaskLeftMouseDragged |
                                                   NSEventMaskRightMouseDown |
                                                   NSEventMaskRightMouseDragged)
                                          handler:^NSEvent *(NSEvent *event) {
        if (!event.window) return event;
        MTKView *v = (MTKView *)event.window.contentView;
        if (![v isKindOfClass:[MTKView class]] || !weakSelf->_haveVP) return event;
        NSPoint pt = [v convertPoint:event.locationInWindow fromView:nil];
        simd_float2 ndc = simd_make_float2((float)(pt.x / v.bounds.size.width) * 2.0f - 1.0f,
                                           (float)(pt.y / v.bounds.size.height) * 2.0f - 1.0f);
        simd_float2 board = [weakSelf unproject:ndc];
        BOOL erase = (event.type == NSEventTypeRightMouseDown ||
                      event.type == NSEventTypeRightMouseDragged);
        if (event.type == NSEventTypeLeftMouseDown)
            weakSelf->_lastPaint = simd_make_float2(-1000, -1000);   // fresh click always stamps
        [weakSelf paintAt:board erase:erase];
        return event;
    }];

    printf("WAR SIM\n"
           "  1-4 select unit: Infantry / Archer / Cavalry / Berserker\n"
           "  Click/drag: stamp a squad (left half = RED, right half = BLUE)\n"
           "  Right-click: erase   SPACE: battle!   R: clear   D: default armies\n");

    _startTime = CACurrentMediaTime();
    _lastFrameTime = _startTime;
    _simAccum = 0;
    _smoothedFPS = 60;
    return self;
}

// ---------------------------------------------------------------- Set-up ---

- (void)resetField:(BOOL)full {
    _units.clear();
    _arrows.clear();
    _blood.clear();
    if (full) _splats.clear();
    _phase = kPhaseSetup;
    _winner = -1;
}

- (void)spawnUnit:(int)type army:(int)army at:(simd_float2)pos {
    if ((int)_units.size() >= kMaxUnits) return;
    std::uniform_real_distribution<float> u01(0.0f, 1.0f);
    Unit un = {};
    un.pos = pos;
    un.vel = simd_make_float2(0, 0);
    un.army = army;
    un.type = type;
    un.hp = kSpecs[type].hp;
    un.cooldown = u01(_rng) * 0.5f;
    un.retarget = u01(_rng) * 0.3f;
    un.target = -1;
    un.bobPhase = u01(_rng) * 6.28f;
    un.seed = u01(_rng);
    un.alive = true;
    _units.push_back(un);
}

- (void)deployDefaultArmies {
    // Symmetric classic setup: infantry line, archers behind, cavalry wings.
    for (int army = 0; army < 2; army++) {
        float sgn = army == 0 ? 1.0f : -1.0f;
        float front = army == 0 ? 46.0f : 94.0f;
        for (int r = 0; r < 3; r++)
            for (int c = 0; c < 40; c++)
                [self spawnUnit:kInfantry army:army
                             at:simd_make_float2(front - sgn * r * 1.2f, 16.0f + c * 1.2f)];
        for (int r = 0; r < 2; r++)
            for (int c = 0; c < 30; c++)
                [self spawnUnit:kArcher army:army
                             at:simd_make_float2(front - sgn * (5.0f + r * 1.3f), 21.0f + c * 1.3f)];
        for (int w = 0; w < 2; w++)
            for (int r = 0; r < 2; r++)
                for (int c = 0; c < 8; c++)
                    [self spawnUnit:kCavalry army:army
                                 at:simd_make_float2(front - sgn * (2.0f + r * 1.8f),
                                                     (w == 0 ? 5.0f : 66.0f) + c * 1.3f)];
    }
}

- (simd_float2)unproject:(simd_float2)ndc {
    simd_float4x4 inv = simd_inverse(_viewProj);
    simd_float4 p0 = simd_mul(inv, simd_make_float4(ndc.x, ndc.y, 0.0f, 1.0f));
    simd_float4 p1 = simd_mul(inv, simd_make_float4(ndc.x, ndc.y, 1.0f, 1.0f));
    simd_float3 a = p0.xyz / p0.w, b = p1.xyz / p1.w;
    float t = (fabsf(b.y - a.y) > 1e-6f) ? a.y / (a.y - b.y) : 0.0f;
    simd_float3 hit = a + (b - a) * t;
    return simd_make_float2(hit.x, -hit.z);
}

- (void)paintAt:(simd_float2)board erase:(BOOL)erase {
    if (_phase != kPhaseSetup) return;
    if (erase) {
        for (Unit &u : _units)
            if (u.alive && simd_distance(u.pos, board) < 3.0f) u.alive = false;
        _units.erase(std::remove_if(_units.begin(), _units.end(),
                     [](const Unit &u) { return !u.alive; }), _units.end());
        return;
    }
    if (simd_distance(board, _lastPaint) < 2.5f) return;   // rate-limit drag stamps
    _lastPaint = board;
    // Which army? Left half of the field = RED, right half = BLUE.
    int army = board.x < 70.0f ? 0 : 1;
    // Clamp the stamp into the army's deploy zone.
    float minX = army == 0 ? 2.0f : kNoMansMax;
    float maxX = army == 0 ? kNoMansMin : kFieldW - 2.0f;
    std::uniform_real_distribution<float> jit(-0.25f, 0.25f);
    for (int r = 0; r < 4; r++) {
        for (int c = 0; c < 4; c++) {
            simd_float2 p = board + simd_make_float2((r - 1.5f) * 0.95f, (c - 1.5f) * 0.95f);
            p.x = std::clamp(p.x, minX, maxX);
            p.y = std::clamp(p.y, 2.0f, kFieldH - 2.0f);
            p += simd_make_float2(jit(_rng), jit(_rng));
            [self spawnUnit:_selectedType army:army at:p];
        }
    }
}

- (void)pressedSpace {
    if (_phase == kPhaseSetup) {
        int have[2] = {0, 0};
        for (const Unit &u : _units) if (u.alive) have[u.army]++;
        if (have[0] == 0 || have[1] == 0) {
            printf("Both armies need units before the battle can start.\n");
            return;
        }
        _phase = kPhaseBattle;
        printf("BATTLE! %d red vs %d blue\n", have[0], have[1]);
    } else if (_phase == kPhaseDone) {
        [self resetField:YES];
        [self deployDefaultArmies];
    }
}

// ------------------------------------------------------------------- Sim ---

- (void)rebuildGrid {
    for (auto &cell : _grid) cell.clear();
    for (size_t i = 0; i < _units.size(); i++) {
        if (!_units[i].alive) continue;
        int cx = std::clamp((int)(_units[i].pos.x / _cellSize), 0, _gridW - 1);
        int cy = std::clamp((int)(_units[i].pos.y / _cellSize), 0, _gridH - 1);
        _grid[(size_t)cy * _gridW + cx].push_back((int)i);
    }
}

// Nearest living enemy via expanding ring search over the grid.
- (int)findEnemyFor:(int)idx {
    const Unit &u = _units[idx];
    int cx = std::clamp((int)(u.pos.x / _cellSize), 0, _gridW - 1);
    int cy = std::clamp((int)(u.pos.y / _cellSize), 0, _gridH - 1);
    int best = -1;
    float bestD2 = 1e18f;
    int maxRing = std::max(_gridW, _gridH);
    for (int ring = 0; ring <= maxRing; ring++) {
        if (best >= 0 && ring > 2 &&
            (float)((ring - 2) * (ring - 2)) * _cellSize * _cellSize > bestD2) break;
        int x0 = cx - ring, x1 = cx + ring, y0 = cy - ring, y1 = cy + ring;
        for (int y = y0; y <= y1; y++) {
            if (y < 0 || y >= _gridH) continue;
            for (int x = x0; x <= x1; x++) {
                if (x < 0 || x >= _gridW) continue;
                if (ring > 0 && x != x0 && x != x1 && y != y0 && y != y1) continue;
                for (int j : _grid[(size_t)y * _gridW + x]) {
                    const Unit &e = _units[j];
                    if (e.army == u.army || !e.alive) continue;
                    float d2 = simd_distance_squared(u.pos, e.pos);
                    if (d2 < bestD2) { bestD2 = d2; best = j; }
                }
            }
        }
    }
    return best;
}

- (void)spawnBloodAt:(simd_float2)pos big:(BOOL)big {
    std::uniform_real_distribution<float> u01(0.0f, 1.0f);
    int n = big ? 10 : 4;
    for (int k = 0; k < n; k++) {
        Blood b;
        float ang = u01(_rng) * 6.2831853f;
        float spd = 1.0f + 2.5f * u01(_rng);
        b.pos = pos;
        b.y = 0.8f + 0.5f * u01(_rng);
        b.vel = simd_make_float2(cosf(ang), sinf(ang)) * spd;
        b.vy = 1.5f + 2.0f * u01(_rng);
        b.age = 0;
        b.life = 0.5f + 0.4f * u01(_rng);
        b.size = big ? 0.30f : 0.18f;
        b.ground = false;
        _blood.push_back(b);
    }
}

- (void)hurtUnit:(int)idx damage:(float)dmg {
    Unit &u = _units[idx];
    if (!u.alive) return;
    u.hp -= dmg;
    if (u.hp <= 0) {
        u.alive = false;
        u.deathT = 0.0001f;
        [self spawnBloodAt:u.pos big:YES];
        std::uniform_real_distribution<float> u01(0.0f, 1.0f);
        Splat s;
        s.pos = u.pos;
        s.size = 0.5f + 0.5f * u01(_rng) + kSpecs[u.type].radius;
        s.seed = u01(_rng);
        s.age = 0;
        _splats.push_back(s);
        if (_splats.size() > 1600) _splats.erase(_splats.begin(), _splats.begin() + 200);
    } else {
        [self spawnBloodAt:u.pos big:NO];
    }
}

- (void)simStep:(float)dt {
    // Death/corpse timers and blood always run so the field settles.
    for (Unit &u : _units) if (!u.alive && u.deathT > 0) u.deathT += dt;
    for (Blood &b : _blood) {
        b.age += dt;
        b.pos += b.vel * dt;
        b.y += b.vy * dt;
        b.vy -= 9.8f * dt;
        if (b.y < 0.02f) b.y = 0.02f;
    }
    _blood.erase(std::remove_if(_blood.begin(), _blood.end(),
                 [](const Blood &b) { return b.age >= b.life; }), _blood.end());
    for (Splat &s : _splats) s.age += dt;

    if (_phase != kPhaseBattle) return;

    [self rebuildGrid];
    std::uniform_real_distribution<float> u01(0.0f, 1.0f);

    for (size_t i = 0; i < _units.size(); i++) {
        Unit &u = _units[i];
        if (!u.alive) continue;
        const UnitSpec &spec = kSpecs[u.type];
        u.cooldown -= dt;
        u.attackAnim = std::max(0.0f, u.attackAnim - dt * 4.0f);
        u.retarget -= dt;
        if (u.retarget <= 0 ||
            u.target < 0 || u.target >= (int)_units.size() || !_units[u.target].alive) {
            u.target = [self findEnemyFor:(int)i];
            u.retarget = 0.25f + 0.1f * u01(_rng);
        }
        if (u.target < 0) continue;   // no enemies left (win check below)
        Unit &tgt = _units[u.target];
        simd_float2 d = tgt.pos - u.pos;
        float dist = simd_length(d);
        simd_float2 dir = dist > 1e-4f ? d / dist : simd_make_float2(1, 0);
        float reach = spec.reach + spec.radius + kSpecs[tgt.type].radius;

        // Archers hold position and volley when in range (unless cornered).
        bool archerShooting = (u.type == kArcher && dist < kArcherRange && dist > 4.0f);

        simd_float2 want = simd_make_float2(0, 0);
        if (archerShooting) {
            if (u.cooldown <= 0) {
                u.cooldown = kArcherReload * (0.9f + 0.2f * u01(_rng));
                u.attackAnim = 1.0f;
                // Ballistic arc that lands on the target's predicted position.
                float T = std::clamp(dist / 28.0f, 0.45f, 1.6f);
                simd_float2 aim = tgt.pos + tgt.vel * (T * 0.85f);
                aim += simd_make_float2(u01(_rng) - 0.5f, u01(_rng) - 0.5f) * (dist * 0.12f);
                Arrow ar;
                ar.pos = simd_make_float3(u.pos.x, 1.3f, u.pos.y);
                simd_float2 flat = (aim - u.pos) / T;
                ar.vel = simd_make_float3(flat.x, 0.5f * 9.8f * T, flat.y);
                ar.army = u.army;
                ar.alive = true;
                _arrows.push_back(ar);
            }
        } else if (dist > reach) {
            want = dir * spec.speed;
        } else {
            // In reach: swing.
            if (u.cooldown <= 0) {
                u.cooldown = spec.cooldown * (0.9f + 0.2f * u01(_rng));
                u.attackAnim = 1.0f;
                float dmg = (u.type == kArcher) ? spec.damage : spec.damage;
                if (u.type == kCavalry && simd_length(u.vel) > kChargeSpeed)
                    dmg *= kChargeMult;
                dmg *= 0.85f + 0.3f * u01(_rng);
                [self hurtUnit:u.target damage:dmg];
            }
        }

        // Separation from neighbors (same grid cell + adjacent).
        int cx = std::clamp((int)(u.pos.x / _cellSize), 0, _gridW - 1);
        int cy = std::clamp((int)(u.pos.y / _cellSize), 0, _gridH - 1);
        simd_float2 push = simd_make_float2(0, 0);
        for (int yy = std::max(cy - 1, 0); yy <= std::min(cy + 1, _gridH - 1); yy++)
            for (int xx = std::max(cx - 1, 0); xx <= std::min(cx + 1, _gridW - 1); xx++)
                for (int j : _grid[(size_t)yy * _gridW + xx]) {
                    if (j == (int)i || !_units[j].alive) continue;
                    simd_float2 dd = u.pos - _units[j].pos;
                    float dl = simd_length(dd);
                    float minD = spec.radius + kSpecs[_units[j].type].radius + 0.12f;
                    if (dl < minD && dl > 1e-4f)
                        push += dd / dl * ((minD - dl) / minD) * 6.0f;
                }
        want += push;

        // Smooth accel toward desired velocity.
        u.vel += (want - u.vel) * std::min(6.0f * dt, 1.0f);
        u.pos += u.vel * dt;
        u.pos.x = std::clamp(u.pos.x, 0.5f, kFieldW - 0.5f);
        u.pos.y = std::clamp(u.pos.y, 0.5f, kFieldH - 0.5f);
        u.bobPhase += simd_length(u.vel) * dt * 6.0f;
    }

    // Arrows.
    for (Arrow &a : _arrows) {
        if (!a.alive) continue;
        a.vel.y -= 9.8f * dt;
        a.pos += a.vel * dt;
        if (a.pos.y <= 0.0f) {
            a.alive = false;
            simd_float2 hit = simd_make_float2(a.pos.x, a.pos.z);
            // Damage the closest enemy within the landing circle.
            int cx = std::clamp((int)(hit.x / _cellSize), 0, _gridW - 1);
            int cy = std::clamp((int)(hit.y / _cellSize), 0, _gridH - 1);
            int best = -1;
            float bestD = 0.85f;
            for (int yy = std::max(cy - 1, 0); yy <= std::min(cy + 1, _gridH - 1); yy++)
                for (int xx = std::max(cx - 1, 0); xx <= std::min(cx + 1, _gridW - 1); xx++)
                    for (int j : _grid[(size_t)yy * _gridW + xx]) {
                        if (!_units[j].alive || _units[j].army == a.army) continue;
                        float dd = simd_distance(_units[j].pos, hit);
                        if (dd < bestD) { bestD = dd; best = j; }
                    }
            if (best >= 0) [self hurtUnit:best damage:kArrowDamage];
        }
    }
    _arrows.erase(std::remove_if(_arrows.begin(), _arrows.end(),
                  [](const Arrow &a) { return !a.alive; }), _arrows.end());

    // Win check.
    int alive[2] = {0, 0};
    for (const Unit &u : _units) if (u.alive) alive[u.army]++;
    if (alive[0] == 0 || alive[1] == 0) {
        _phase = kPhaseDone;
        _winner = alive[0] > 0 ? 0 : (alive[1] > 0 ? 1 : -1);
        if (_winner >= 0)
            printf("*** %s ARMY WINS — %d survivors ***\n",
                   _winner == 0 ? "RED" : "BLUE", alive[_winner]);
        else
            printf("*** MUTUAL ANNIHILATION ***\n");
    }
}

// ---------------------------------------------------------------- Render ---

- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) return;

    double now = CACurrentMediaTime();
    float t = (float)(now - _startTime);
    float dtRaw = (float)(now - _lastFrameTime);
    _lastFrameTime = now;
    if (dtRaw > 0) _smoothedFPS += (1.0f / dtRaw - _smoothedFPS) * 0.05f;

    _simAccum += std::min(dtRaw, 0.25f);
    const double kStep = 1.0 / 60.0;
    while (_simAccum >= kStep) {
        [self simStep:(float)kStep];
        _simAccum -= kStep;
    }

    // Battle-cam: fixed, raised, looking down the field.
    float aspect = (float)(view.drawableSize.width / view.drawableSize.height);
    float pitch = 47.0f * (float)M_PI / 180.0f;
    float fovy = 33.0f * (float)M_PI / 180.0f;
    float tanH = tanf(fovy * 0.5f);
    float distX = (kFieldW * 0.5f + 6.0f) / (tanH * aspect);
    float distZ = (kFieldH * 0.5f * sinf(pitch) + 10.0f) / tanH;
    float dist = std::max(distX, distZ);
    simd_float3 target = simd_make_float3(kFieldW * 0.5f, 0, -kFieldH * 0.5f);
    simd_float3 eye = target + simd_make_float3(0, sinf(pitch), cosf(pitch)) * dist;
    simd_float3 fwd = simd_normalize(target - eye);
    simd_float3 right = simd_normalize(simd_cross(fwd, simd_make_float3(0, 1, 0)));
    simd_float3 up = simd_cross(right, fwd);
    simd_float4x4 proj = Perspective(fovy, aspect, 1.0f, dist * 3.0f);
    _viewProj = simd_mul(proj, LookAt(eye, right, up, fwd));
    _haveVP = true;

    struct {
        simd_float4x4 viewProj;
        simd_float2 resolution;
        float time;
        float phase;
    } uni = {
        _viewProj,
        simd_make_float2((float)view.drawableSize.width, (float)view.drawableSize.height),
        t,
        (float)_phase,
    };

    dispatch_semaphore_wait(_frameSemaphore, DISPATCH_TIME_FOREVER);
    _flatScratch.clear();
    _unitScratch.clear();

    // ---- Flat decals: splats first, then shadows, then corpses on top.
    for (const Splat &s : _splats) {
        float fade = 1.0f - std::min(s.age / 30.0f, 1.0f);
        if (fade <= 0) continue;
        _flatScratch.push_back({s.pos.x, s.pos.y, s.size, s.size * 0.8f,
                                s.seed * 6.28f, 1,
                                0.30f, 0.02f, 0.01f, 0.55f * fade,
                                s.seed, 0, 0, 0});
    }
    for (const Unit &u : _units) {
        const UnitSpec &spec = kSpecs[u.type];
        if (u.alive) {
            float sh = spec.radius * 2.3f;
            _flatScratch.push_back({u.pos.x, u.pos.y, sh, sh * 0.7f, 0, 0,
                                    0.02f, 0.02f, 0.03f, 0.38f, 0, 0, 0, 0});
        } else if (u.deathT > 0.55f) {
            float fade = 1.0f - std::clamp((u.deathT - 22.0f) / 5.0f, 0.0f, 1.0f);
            if (fade <= 0) continue;
            simd_float4 c = kArmyColor[u.army] * 0.35f;
            _flatScratch.push_back({u.pos.x, u.pos.y,
                                    spec.height * 0.55f, spec.width * 0.45f,
                                    u.seed * 6.28f, 2,
                                    c.x, c.y, c.z, 0.85f * fade,
                                    u.seed, 0, 0, 0});
        }
        if (_flatScratch.size() >= (size_t)kMaxFlats - 4) break;
    }

    // ---- Billboards: living units, dying units, arrows, blood.
    for (const Unit &u : _units) {
        if (!u.alive && (u.deathT <= 0 || u.deathT > 0.55f)) continue;
        const UnitSpec &spec = kSpecs[u.type];
        float speed = simd_length(u.vel);
        float bob = (u.alive && speed > 0.3f) ? fabsf(sinf(u.bobPhase)) * 0.07f : 0.0f;
        if (_phase == kPhaseDone && u.alive && _winner == u.army)
            bob = fabsf(sinf(t * 6.0f + u.bobPhase)) * 0.25f;   // victory hops
        float rot = 0, sink = 0;
        if (!u.alive) {   // death fall
            float f = std::min(u.deathT / 0.55f, 1.0f);
            rot = (u.seed > 0.5f ? 1.0f : -1.0f) * f * 1.45f;
            sink = f * 0.25f;
        }
        float facing = 1.0f;
        if (u.target >= 0 && u.target < (int)_units.size())
            facing = (_units[u.target].pos.x >= u.pos.x) ? 1.0f : -1.0f;
        else facing = (u.army == 0) ? 1.0f : -1.0f;
        simd_float4 c = kArmyColor[u.army];
        _unitScratch.push_back({u.pos.x, u.pos.y, bob - sink,
                                spec.width, spec.height, rot,
                                (float)u.type, facing,
                                c.x, c.y, c.z, 1.0f,
                                u.attackAnim, u.seed, 0, 0});
        if (_unitScratch.size() >= 5800) break;   // keep clear of the blood region
    }
    for (const Arrow &a : _arrows) {
        // Screen-plane rotation approximated from world velocity.
        float sx = a.vel.x;
        float sy = a.vel.y * 0.68f - a.vel.z * 0.73f;
        float rot = atan2f(sy, sx);
        _unitScratch.push_back({a.pos.x, a.pos.z, a.pos.y - 0.35f,
                                0.7f, 0.7f, rot, 4, 1,
                                0.4f, 0.3f, 0.2f, 1.0f,
                                0, 0, 0, 0});
        if (_unitScratch.size() >= 5800) break;
    }

    id<MTLBuffer> flatBuf = _flatBuffers[_frameIndex];
    id<MTLBuffer> unitBuf = _unitBuffers[_frameIndex];
    NSUInteger flatCount = _flatScratch.size();
    NSUInteger unitCount = _unitScratch.size();
    if (flatCount) memcpy([flatBuf contents], _flatScratch.data(), flatCount * sizeof(FInstC));
    if (unitCount) memcpy([unitBuf contents], _unitScratch.data(), unitCount * sizeof(BInstC));

    // Blood puffs go in a second, non-depth-writing draw of the unit pipeline?
    // No — they need soft blending; reuse the flat pipeline as billboards is
    // wrong. Simplest: blood as unit-shape 5 in a separate small buffer drawn
    // with the flat blend states. Build it now (reusing scratch after copy).
    _unitScratch.clear();
    for (const Blood &b : _blood) {
        float f = 1.0f - b.age / b.life;
        _unitScratch.push_back({b.pos.x, b.pos.y, b.y - b.size,
                                b.size * 2.0f, b.size * 2.0f, 0, 5, 1,
                                1, 1, 1, f,
                                0, 0, 0, 0});
        if (_unitScratch.size() >= 2000) break;
    }
    NSUInteger bloodCount = _unitScratch.size();
    id<MTLBuffer> bloodBuf = nil;
    static const NSUInteger kBloodOffset = (NSUInteger)(kMaxBillboards - 2100) * sizeof(BInstC);
    if (bloodCount) {
        bloodBuf = unitBuf;
        memcpy((char *)[unitBuf contents] + kBloodOffset,
               _unitScratch.data(), bloodCount * sizeof(BInstC));
    }

    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [commands renderCommandEncoderWithDescriptor:pass];

    [enc setRenderPipelineState:_groundPipeline];
    [enc setDepthStencilState:_depthWrite];
    [enc setVertexBytes:&uni length:sizeof(uni) atIndex:0];
    [enc setFragmentBytes:&uni length:sizeof(uni) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];

    if (flatCount) {
        [enc setRenderPipelineState:_flatPipeline];
        [enc setDepthStencilState:_depthTest];
        [enc setVertexBuffer:flatBuf offset:0 atIndex:0];
        [enc setVertexBytes:&uni length:sizeof(uni) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                vertexCount:6 instanceCount:flatCount];
    }

    if (unitCount) {
        [enc setRenderPipelineState:_unitPipeline];
        [enc setDepthStencilState:_depthWrite];
        [enc setVertexBuffer:unitBuf offset:0 atIndex:0];
        [enc setVertexBytes:&uni length:sizeof(uni) atIndex:1];
        [enc setFragmentBytes:&uni length:sizeof(uni) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                vertexCount:6 instanceCount:unitCount];
    }

    if (bloodCount) {
        // Soft blood puffs: same unit pipeline (blending is enabled on it),
        // but depth-test-only so soft edges never punch holes in the depth.
        [enc setRenderPipelineState:_unitPipeline];
        [enc setDepthStencilState:_depthTest];
        [enc setVertexBuffer:bloodBuf offset:kBloodOffset atIndex:0];
        [enc setVertexBytes:&uni length:sizeof(uni) atIndex:1];
        [enc setFragmentBytes:&uni length:sizeof(uni) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                vertexCount:6 instanceCount:bloodCount];
    }

    [enc endEncoding];

    dispatch_semaphore_t sem = _frameSemaphore;
    [commands addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        (void)cb;
        dispatch_semaphore_signal(sem);
    }];
    [commands presentDrawable:drawable];
    [commands commit];
    _frameIndex = (_frameIndex + 1) % kMaxInFlight;

    int alive[2] = {0, 0};
    for (const Unit &u : _units) if (u.alive) alive[u.army]++;
    NSString *state;
    if (_phase == kPhaseSetup)
        state = [NSString stringWithFormat:@"SETUP — painting %s (1-4) — SPACE to fight",
                 kSpecs[_selectedType].name];
    else if (_phase == kPhaseBattle)
        state = @"BATTLE";
    else
        state = _winner >= 0
            ? [NSString stringWithFormat:@"%@ WINS — SPACE for rematch", _winner == 0 ? @"RED" : @"BLUE"]
            : @"MUTUAL ANNIHILATION — SPACE for rematch";
    view.window.title = [NSString stringWithFormat:
        @"08 — WAR SIM ▸ RED %d vs BLUE %d ▸ %@ ▸ %.0f fps",
        alive[0], alive[1], state, _smoothedFPS];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

@end

int main() {
    return RunMetalApp(@"08 — WAR SIM", 1280, 760, ^(MTKView *view) {
        return (NSObject<MTKViewDelegate> *)[[WarSimRenderer alloc] initWithView:view];
    });
}
