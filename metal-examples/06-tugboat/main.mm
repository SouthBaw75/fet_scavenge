// 06 — Tugboat
//
// A tiny game: drive a tugboat across a Gerstner-wave ocean, viewed from a
// chase camera angled 30° down, and collect the orange buoys. The water and
// buoys are procedural, and the boat is loaded from a real USDZ model via
// Model I/O (assets/Tugboat.usdz) with a procedural box-boat fallback if the
// file is missing. Everything samples the SAME wave function on the CPU so it
// genuinely rides the swells (bob, pitch, roll). Distance haze blends the
// water edge into the sky at the horizon.
//
// Pass a model path as argv[1] to override, e.g. ./06-tugboat myboat.usdz
//
// Two billboard particle systems add life: dark smoke puffing from the funnel
// (heavier under throttle) and white foam churning off the stern into a wake.
// Both are alpha-blended camera-facing quads, triple-buffered so the CPU can
// build the next frame's geometry while the GPU draws this one. The wake is
// layered under the boat and the smoke over it.
//
// Controls:
//   W / Up      throttle up          A / Left    rudder left
//   S / Down    throttle down        D / Right   rudder right
//   Space       cut throttle         R           reset boat
//
// The rudder needs water flowing past it: steering barely works when you're
// not moving, just like a real boat. Score and throttle live in the title bar.

#include "../common/app.h"
#import <ModelIO/ModelIO.h>
#import <MetalKit/MetalKit.h>
#include <simd/simd.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <random>
#include <string>
#include <vector>

// Optional path to a boat model (USDZ/OBJ), from argv[1]. When present and
// loadable it replaces the procedural box-boat; otherwise we fall back.
static NSString *gModelPath = nil;

// --- Tuning for the loaded boat asset (tweak after seeing it on screen) ---
static const float kBoatTargetLength = 8.0f;  // scale the model's footprint to this many meters
static const float kBoatYawDeg = 0.0f;         // spin the model to face forward (-z) if needed
static const float kBoatPitchDeg = 0.0f;       // tilt (use -90 if the model is Z-up, not Y-up)
static const float kBoatDraft = 0.5f;          // how far the hull bottom sits below the waterline

static const int kGrid = 360;        // water quads per side (wide enough that the
static const float kSpacing = 0.5f;  // grid edges sit past the horizon haze)
static const int kBuoyCount = 8;
static const float kCollectRadius = 2.5f;
static const int kMaxParticles = 1400;  // smoke + wake combined
static const int kMaxInFlight = 3;      // triple-buffered particle geometry

// Single source of truth for the waves — the shader constant array is
// generated from this table, and the CPU buoyancy code below reads it too.
// dir.x, dir.z, amplitude, wavelength. A calm sea so driving is pleasant.
static const float kWaveTable[6][4] = {
    {1.0f,  0.20f, 0.22f, 14.0f},
    {0.7f,  0.60f, 0.14f,  8.5f},
    {1.0f, -0.50f, 0.10f,  5.0f},
    {0.5f,  0.90f, 0.06f,  3.0f},
    {0.9f, -0.80f, 0.035f, 1.8f},
    {0.3f,  1.00f, 0.02f,  1.0f},
};

static const char *kShaderSource = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 mvp;
    float4x4 model;
    float4 camPos;  // xyz
    float4 sun;     // xyz = direction to sun, w = time
    float4 misc;    // xy = water grid origin (world xz)
};

struct Wave {
    float3 pos;
    float3 normal;
    float  crest;
};

Wave gerstner(float2 xz, float time) {
    float3 p = float3(xz.x, 0.0, xz.y);
    float3 n = float3(0.0, 1.0, 0.0);
    float ampSum = 0.0;
    for (int i = 0; i < 6; i++) {
        float2 D = normalize(kWaves[i].xy);
        float A = kWaves[i].z;
        float k = 2.0 * M_PI_F / kWaves[i].w;
        float omega = sqrt(9.8 * k);
        float Q = 0.5 / (k * A * 6.0);
        float theta = k * dot(D, xz) - omega * time;
        float s = sin(theta), c = cos(theta);
        p.x += Q * A * D.x * c;
        p.z += Q * A * D.y * c;
        p.y += A * s;
        n.x -= D.x * k * A * c;
        n.z -= D.y * k * A * c;
        n.y -= Q * k * A * s;
        ampSum += A;
    }
    Wave w;
    w.pos = p;
    w.normal = normalize(n);
    w.crest = p.y / ampSum;
    return w;
}

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
    for (int i = 0; i < 3; i++) { v += a * vnoise(p); p *= 2.13; a *= 0.5; }
    return v;
}

// ---------------- Water ----------------

struct WaterVSOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float  crest;
};

constant uint2 kCorner[6] = {
    uint2(0, 0), uint2(1, 0), uint2(1, 1),
    uint2(0, 0), uint2(1, 1), uint2(0, 1),
};

vertex WaterVSOut water_vertex(uint vid [[vertex_id]],
                               constant Uniforms &u [[buffer(0)]]) {
    uint quad = vid / 6;
    uint2 corner = kCorner[vid % 6];
    float2 xz = u.misc.xy +
                (float2(quad % GRID + corner.x, quad / GRID + corner.y)
                 - GRID * 0.5) * SPACING;
    Wave w = gerstner(xz, u.sun.w);
    WaterVSOut out;
    out.position = u.mvp * float4(w.pos, 1.0);
    out.world = w.pos;
    out.normal = w.normal;
    out.crest = w.crest;
    return out;
}

fragment float4 water_fragment(WaterVSOut in [[stage_in]],
                               constant Uniforms &u [[buffer(0)]]) {
    float time = u.sun.w;
    float3 sun = u.sun.xyz;
    float3 V = normalize(u.camPos.xyz - in.world);

    // Ripple detail on top of the geometric wave normal.
    float2 dp = in.world.xz * 1.6 + float2(time * 0.4, time * 0.25);
    float hC = fbm(dp);
    float hX = fbm(dp + float2(0.3, 0.0));
    float hZ = fbm(dp + float2(0.0, 0.3));
    float3 n = normalize(normalize(in.normal) + float3(hC - hX, 0.0, hC - hZ) * 0.8);

    float fresnel = 0.02 + 0.98 * pow(1.0 - max(dot(n, V), 0.0), 5.0);
    float3 skyRef = mix(float3(0.45, 0.62, 0.78), float3(0.25, 0.45, 0.70),
                        saturate(n.y));

    float3 deep = float3(0.03, 0.16, 0.22);
    float3 shallow = float3(0.05, 0.30, 0.32);
    float3 body = mix(deep, shallow, max(in.crest, 0.0) * 0.6);

    float3 color = mix(body, skyRef, fresnel);

    // Sun sparkle off the ripples.
    float3 R = reflect(-V, n);
    color += float3(1.0, 0.95, 0.8) * pow(max(dot(R, sun), 0.0), 180.0) * 1.2;

    // Foam on the crests.
    float foamMask = fbm(in.world.xz * 0.9 + float2(time * 0.2, -time * 0.15));
    float foam = smoothstep(0.45, 0.85, in.crest) *
                 smoothstep(0.35, 0.75, foamMask + 0.25 * in.crest);
    color = mix(color, float3(0.90, 0.93, 0.95), foam * 0.6);

    // Distance haze: blends the far edge of the water grid into the sky so
    // the oblique camera angle doesn't reveal a hard seam at the grid border.
    float dist = length(u.camPos.xyz - in.world);
    color = mix(color, float3(0.55, 0.68, 0.82), smoothstep(60.0, 95.0, dist));

    return float4(pow(color, float3(0.4545)), 1.0);
}

// ---------------- Solid objects (boat, buoys) ----------------

struct SolidVertexIn {
    packed_float3 position;
    packed_float3 normal;
    packed_float3 color;
};

struct SolidVSOut {
    float4 position [[position]];
    float3 normal;
    float3 color;
};

vertex SolidVSOut solid_vertex(uint vid [[vertex_id]],
                               const device SolidVertexIn *verts [[buffer(0)]],
                               constant Uniforms &u [[buffer(1)]]) {
    SolidVertexIn v = verts[vid];
    SolidVSOut out;
    out.position = u.mvp * float4(float3(v.position), 1.0);
    out.normal = (u.model * float4(float3(v.normal), 0.0)).xyz;
    out.color = float3(v.color);
    return out;
}

fragment float4 solid_fragment(SolidVSOut in [[stage_in]],
                               constant Uniforms &u [[buffer(0)]]) {
    float3 n = normalize(in.normal);
    float diffuse = max(dot(n, u.sun.xyz), 0.0);
    float3 color = in.color * (0.35 + 0.75 * diffuse);
    return float4(pow(color, float3(0.4545)), 1.0);
}

// ---------------- Textured mesh (loaded boat asset) ----------------
// Uses [[stage_in]] with a vertex descriptor so it can consume whatever
// interleaved position/normal/uv buffer Model I/O produces, and samples a
// per-submesh base-color texture.

struct BoatIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 uv       [[attribute(2)]];
};

struct BoatVSOut {
    float4 position [[position]];
    float3 normal;
    float2 uv;
};

vertex BoatVSOut boat_vertex(BoatIn in [[stage_in]],
                             constant Uniforms &u [[buffer(1)]]) {
    BoatVSOut out;
    out.position = u.mvp * float4(in.position, 1.0);
    out.normal = (u.model * float4(in.normal, 0.0)).xyz;
    out.uv = in.uv;
    return out;
}

fragment float4 boat_fragment(BoatVSOut in [[stage_in]],
                              constant Uniforms &u [[buffer(0)]],
                              texture2d<float> baseColor [[texture(0)]],
                              sampler samp [[sampler(0)]]) {
    // sRGB textures are converted to linear on sample; light in linear, then
    // gamma-encode at the end to match the other passes.
    float3 albedo = baseColor.sample(samp, in.uv).rgb;
    float3 n = normalize(in.normal);
    float diffuse = max(dot(n, u.sun.xyz), 0.0);
    float3 color = albedo * (0.35 + 0.8 * diffuse);
    return float4(pow(color, float3(0.4545)), 1.0);
}

// ---------------- Particles: smoke and wake foam ----------------
// Camera-facing billboards built on the CPU. Each vertex already carries its
// world position, a 0..1 UV, and an RGBA color; the fragment softens it into a
// round puff with a radial alpha falloff.

struct PVertex {
    packed_float3 position;
    packed_float2 uv;
    packed_float4 color;
};

struct ParticleVSOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

vertex ParticleVSOut particle_vertex(uint vid [[vertex_id]],
                                     const device PVertex *verts [[buffer(0)]],
                                     constant Uniforms &u [[buffer(1)]]) {
    PVertex pv = verts[vid];
    ParticleVSOut out;
    out.position = u.mvp * float4(float3(pv.position), 1.0);
    out.uv = float2(pv.uv);
    out.color = float4(pv.color);
    return out;
}

fragment float4 particle_fragment(ParticleVSOut in [[stage_in]]) {
    float d = length(in.uv - 0.5) * 2.0;             // 0 center .. 1 edge
    float a = in.color.a * smoothstep(1.0, 0.0, d);  // soft round falloff
    return float4(in.color.rgb, a);
}
)METAL";

struct Uniforms {
    simd_float4x4 mvp;
    simd_float4x4 model;
    simd_float4 camPos;
    simd_float4 sun;
    simd_float4 misc;
};

struct SolidVertex {
    float px, py, pz;
    float nx, ny, nz;
    float cr, cg, cb;
};

// Matches the shader's PVertex exactly: 9 contiguous floats.
struct ParticleVertex {
    float px, py, pz;
    float u, v;
    float r, g, b, a;
};

struct Particle {
    simd_float3 pos;
    simd_float3 vel;
    float age;
    float life;
    float size0, size1;      // world-space diameter, start -> end
    simd_float4 color0, color1;
    int kind;                // 0 = smoke, 1 = wake foam
};

// --- CPU copy of the wave function, for buoyancy. Must match the shader. ---

struct WaveSample {
    float height;
    simd_float3 normal;
};

static WaveSample SampleWaves(simd_float2 xz, float time) {
    float h = 0.0f;
    simd_float3 n = simd_make_float3(0, 1, 0);
    for (int i = 0; i < 6; i++) {
        simd_float2 D = simd_normalize(simd_make_float2(kWaveTable[i][0], kWaveTable[i][1]));
        float A = kWaveTable[i][2];
        float k = 2.0f * (float)M_PI / kWaveTable[i][3];
        float omega = sqrtf(9.8f * k);
        float Q = 0.5f / (k * A * 6.0f);
        float theta = k * simd_dot(D, xz) - omega * time;
        float s = sinf(theta), c = cosf(theta);
        h += A * s;
        n.x -= D.x * k * A * c;
        n.z -= D.y * k * A * c;
        n.y -= Q * k * A * s;
    }
    return { h, simd_normalize(n) };
}

// --- Matrices ---

static simd_float4x4 Perspective(float fovyRadians, float aspect, float nearZ, float farZ) {
    float ys = 1.0f / tanf(fovyRadians * 0.5f);
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

static simd_float4x4 ModelMatrix(simd_float3 right, simd_float3 up, simd_float3 back,
                                 simd_float3 position) {
    return simd_matrix(simd_make_float4(right, 0),
                       simd_make_float4(up, 0),
                       simd_make_float4(back, 0),
                       simd_make_float4(position, 1));
}

static simd_float4x4 ScaleMat(float s) {
    return simd_matrix(simd_make_float4(s, 0, 0, 0),
                       simd_make_float4(0, s, 0, 0),
                       simd_make_float4(0, 0, s, 0),
                       simd_make_float4(0, 0, 0, 1));
}

static simd_float4x4 TransMat(simd_float3 t) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[3] = simd_make_float4(t.x, t.y, t.z, 1);
    return m;
}

static simd_float4x4 RotYMat(float a) {
    float c = cosf(a), s = sinf(a);
    return simd_matrix(simd_make_float4(c, 0, -s, 0),
                       simd_make_float4(0, 1, 0, 0),
                       simd_make_float4(s, 0, c, 0),
                       simd_make_float4(0, 0, 0, 1));
}

static simd_float4x4 RotXMat(float a) {
    float c = cosf(a), s = sinf(a);
    return simd_matrix(simd_make_float4(1, 0, 0, 0),
                       simd_make_float4(0, c, s, 0),
                       simd_make_float4(0, -s, c, 0),
                       simd_make_float4(0, 0, 0, 1));
}

// Emit the six vertices of a camera-facing quad for one particle, sized and
// tinted by its age. camR/camU are the camera's right/up axes in world space.
static void AppendBillboard(std::vector<ParticleVertex> &out, const Particle &p,
                            simd_float3 camR, simd_float3 camU) {
    float frac = p.age / p.life;
    float size = p.size0 + (p.size1 - p.size0) * frac;
    simd_float4 c = p.color0 + (p.color1 - p.color0) * frac;
    simd_float3 r = camR * (size * 0.5f);
    simd_float3 u = camU * (size * 0.5f);
    simd_float3 C = p.pos;
    simd_float3 p0 = C - r + u, p1 = C + r + u, p2 = C + r - u, p3 = C - r - u;
    auto push = [&](simd_float3 v, float uu, float vv) {
        out.push_back({v.x, v.y, v.z, uu, vv, c.x, c.y, c.z, c.w});
    };
    push(p0, 0, 0); push(p1, 1, 0); push(p2, 1, 1);
    push(p0, 0, 0); push(p2, 1, 1); push(p3, 0, 1);
}

// --- Procedural meshes from colored boxes ---

static void AddBox(std::vector<SolidVertex> &verts, simd_float3 center,
                   simd_float3 size, simd_float3 color) {
    struct Face { simd_float3 n, u, v; };
    const Face faces[6] = {
        { { 0,  0,  1}, { 1, 0,  0}, {0, 1,  0} },
        { { 0,  0, -1}, {-1, 0,  0}, {0, 1,  0} },
        { { 1,  0,  0}, { 0, 0, -1}, {0, 1,  0} },
        { {-1,  0,  0}, { 0, 0,  1}, {0, 1,  0} },
        { { 0,  1,  0}, { 1, 0,  0}, {0, 0, -1} },
        { { 0, -1,  0}, { 1, 0,  0}, {0, 0,  1} },
    };
    simd_float3 h = size * 0.5f;
    for (const Face &f : faces) {
        simd_float3 fn = f.n * h, fu = f.u * h, fv = f.v * h;
        const simd_float3 corners[4] = {
            center + fn - fu - fv, center + fn + fu - fv,
            center + fn + fu + fv, center + fn - fu + fv,
        };
        const int indices[6] = {0, 1, 2, 0, 2, 3};
        for (int i : indices) {
            simd_float3 p = corners[i];
            verts.push_back({p.x, p.y, p.z, f.n.x, f.n.y, f.n.z, color.x, color.y, color.z});
        }
    }
}

// Local convention: forward = -z, up = +y. Origin at the waterline.
static std::vector<SolidVertex> MakeTugboat() {
    std::vector<SolidVertex> v;
    const simd_float3 red = simd_make_float3(0.75f, 0.15f, 0.12f);
    const simd_float3 wood = simd_make_float3(0.55f, 0.38f, 0.22f);
    const simd_float3 white = simd_make_float3(0.92f, 0.92f, 0.95f);
    const simd_float3 dark = simd_make_float3(0.20f, 0.20f, 0.22f);
    const simd_float3 black = simd_make_float3(0.12f, 0.12f, 0.14f);
    AddBox(v, simd_make_float3(0, 0.45f,  0.1f), simd_make_float3(2.2f, 0.9f, 5.6f), red);   // hull
    AddBox(v, simd_make_float3(0, 0.45f, -3.1f), simd_make_float3(1.4f, 0.9f, 0.8f), red);   // bow
    AddBox(v, simd_make_float3(0, 0.95f,  0.1f), simd_make_float3(2.0f, 0.12f, 5.2f), wood); // deck
    AddBox(v, simd_make_float3(0, 1.55f,  0.8f), simd_make_float3(1.5f, 1.1f, 1.8f), white); // cabin
    AddBox(v, simd_make_float3(0, 2.15f,  0.8f), simd_make_float3(1.7f, 0.12f, 2.0f), dark); // roof
    AddBox(v, simd_make_float3(0, 2.00f,  2.1f), simd_make_float3(0.6f, 1.4f, 0.6f), black); // funnel
    AddBox(v, simd_make_float3(0, 2.75f,  2.1f), simd_make_float3(0.64f, 0.3f, 0.64f), red); // funnel stripe
    return v;
}

static std::vector<SolidVertex> MakeBuoy() {
    std::vector<SolidVertex> v;
    const simd_float3 orange = simd_make_float3(1.0f, 0.45f, 0.05f);
    const simd_float3 white = simd_make_float3(0.95f, 0.95f, 0.95f);
    const simd_float3 light = simd_make_float3(1.0f, 0.9f, 0.3f);
    AddBox(v, simd_make_float3(0, 0.25f, 0), simd_make_float3(1.0f, 0.5f, 1.0f), orange);
    AddBox(v, simd_make_float3(0, 0.70f, 0), simd_make_float3(0.55f, 0.5f, 0.55f), orange);
    AddBox(v, simd_make_float3(0, 1.15f, 0), simd_make_float3(0.30f, 0.5f, 0.30f), white);
    AddBox(v, simd_make_float3(0, 1.50f, 0), simd_make_float3(0.18f, 0.2f, 0.18f), light);
    return v;
}

// Key codes (ANSI layout).
enum {
    kKeyA = 0, kKeyS = 1, kKeyD = 2, kKeyW = 13, kKeyR = 15, kKeySpace = 49,
    kKeyLeft = 123, kKeyRight = 124, kKeyDown = 125, kKeyUp = 126,
};

@interface TugboatRenderer : NSObject <MTKViewDelegate>
- (instancetype)initWithView:(MTKView *)view;
@end

@implementation TugboatRenderer {
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _waterPipeline;
    id<MTLRenderPipelineState> _solidPipeline;
    id<MTLRenderPipelineState> _particlePipeline;
    id<MTLRenderPipelineState> _boatPipeline;      // textured asset boat
    id<MTLDepthStencilState> _depthState;
    id<MTLDepthStencilState> _noDepthState;
    id<MTLSamplerState> _sampler;
    id<MTLBuffer> _boatMesh;                        // procedural fallback boat
    NSUInteger _boatVertexCount;
    id<MTLBuffer> _buoyMesh;
    NSUInteger _buoyVertexCount;

    // Loaded boat asset (empty -> use the procedural box-boat instead).
    NSMutableArray<MTKMesh *> *_boatMeshes;
    NSMutableArray<NSArray<id<MTLTexture>> *> *_boatSubmeshTextures;
    std::vector<simd_float4x4> _boatMeshXforms;     // fixup * node transform, per mesh

    // Triple-buffered particle geometry so the CPU can build the next frame
    // while the GPU still reads the current one.
    id<MTLBuffer> _particleBuffers[kMaxInFlight];
    int _frameIndex;
    dispatch_semaphore_t _frameSemaphore;

    // Game state
    bool _keys[128];
    simd_float2 _boatPos;
    float _heading;      // radians; 0 = up-screen (-z)
    float _speed;        // m/s along heading
    float _throttle;     // -0.4 .. 1.0
    simd_float2 _buoys[kBuoyCount];
    int _score;
    std::mt19937 _rng;

    // Smoke + wake particles, and the boat transform they share with rendering.
    std::vector<Particle> _particles;
    std::vector<ParticleVertex> _particleScratch;
    float _smokeAccum;
    float _wakeAccum;
    simd_float3 _boatRight, _boatUp, _boatBack, _boatWorldPos;

    double _startTime;
    double _lastFrameTime;
    float _smoothedFPS;
}

- (instancetype)initWithView:(MTKView *)view {
    if (!(self = [super init])) return nil;

    id<MTLDevice> device = view.device;
    _queue = [device newCommandQueue];
    view.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    // Pale haze that the water fogs into at the horizon (gamma-encoded to match
    // the water shader's manual gamma, so the grid edge blends seamlessly).
    view.clearColor = MTLClearColorMake(0.76, 0.84, 0.91, 1.0);

    // Generate the shader's wave table from the C++ table so the CPU
    // buoyancy math and the GPU water can never drift apart.
    std::string waves = "constant float4 kWaves[6] = {\n";
    for (int i = 0; i < 6; i++) {
        char line[128];
        snprintf(line, sizeof(line), "    float4(%f, %f, %f, %f),\n",
                 kWaveTable[i][0], kWaveTable[i][1], kWaveTable[i][2], kWaveTable[i][3]);
        waves += line;
    }
    waves += "};\n";

    std::string source = "#define GRID " + std::to_string(kGrid) +
                         "\n#define SPACING " + std::to_string(kSpacing) + "f\n";
    std::string body(kShaderSource);
    // The wave table must appear after `using namespace metal;` — inject it
    // at the start of the shader body, which begins after the header lines.
    size_t insertAt = body.find("struct Uniforms");
    body.insert(insertAt, waves);
    source += body;

    id<MTLLibrary> library = CompileLibrary(device, source.c_str());
    if (!library) return nil;

    NSError *error = nil;
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    desc.depthAttachmentPixelFormat = view.depthStencilPixelFormat;

    desc.vertexFunction = [library newFunctionWithName:@"water_vertex"];
    desc.fragmentFunction = [library newFunctionWithName:@"water_fragment"];
    _waterPipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!_waterPipeline) {
        fprintf(stderr, "Water pipeline error: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }

    desc.vertexFunction = [library newFunctionWithName:@"solid_vertex"];
    desc.fragmentFunction = [library newFunctionWithName:@"solid_fragment"];
    _solidPipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!_solidPipeline) {
        fprintf(stderr, "Solid pipeline error: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }

    MTLDepthStencilDescriptor *depthDesc = [MTLDepthStencilDescriptor new];
    depthDesc.depthCompareFunction = MTLCompareFunctionLess;
    depthDesc.depthWriteEnabled = YES;
    _depthState = [device newDepthStencilStateWithDescriptor:depthDesc];

    // Particles: alpha-blended billboards, no depth writes (they're drawn in
    // back-to-front layers by hand — wake under the boat, smoke over it).
    MTLRenderPipelineDescriptor *pdesc = [MTLRenderPipelineDescriptor new];
    pdesc.vertexFunction = [library newFunctionWithName:@"particle_vertex"];
    pdesc.fragmentFunction = [library newFunctionWithName:@"particle_fragment"];
    pdesc.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    pdesc.depthAttachmentPixelFormat = view.depthStencilPixelFormat;
    pdesc.colorAttachments[0].blendingEnabled = YES;
    pdesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    pdesc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    pdesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    pdesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
    pdesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pdesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    _particlePipeline = [device newRenderPipelineStateWithDescriptor:pdesc error:&error];
    if (!_particlePipeline) {
        fprintf(stderr, "Particle pipeline error: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }

    MTLDepthStencilDescriptor *noDepth = [MTLDepthStencilDescriptor new];
    noDepth.depthCompareFunction = MTLCompareFunctionAlways;
    noDepth.depthWriteEnabled = NO;
    _noDepthState = [device newDepthStencilStateWithDescriptor:noDepth];

    for (int i = 0; i < kMaxInFlight; i++) {
        _particleBuffers[i] =
            [device newBufferWithLength:(NSUInteger)kMaxParticles * 6 * sizeof(ParticleVertex)
                                options:MTLResourceStorageModeShared];
    }
    _frameIndex = 0;
    _frameSemaphore = dispatch_semaphore_create(kMaxInFlight);
    _particles.reserve(kMaxParticles);
    _smokeAccum = 0;
    _wakeAccum = 0;

    std::vector<SolidVertex> boat = MakeTugboat();
    _boatVertexCount = boat.size();
    _boatMesh = [device newBufferWithBytes:boat.data()
                                    length:boat.size() * sizeof(SolidVertex)
                                   options:MTLResourceStorageModeShared];

    std::vector<SolidVertex> buoy = MakeBuoy();
    _buoyVertexCount = buoy.size();
    _buoyMesh = [device newBufferWithBytes:buoy.data()
                                    length:buoy.size() * sizeof(SolidVertex)
                                   options:MTLResourceStorageModeShared];

    // Texture sampler for the loaded boat.
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = MTLSamplerMinMagFilterLinear;
    sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.mipFilter = MTLSamplerMipFilterLinear;
    sd.sAddressMode = MTLSamplerAddressModeRepeat;
    sd.tAddressMode = MTLSamplerAddressModeRepeat;
    _sampler = [device newSamplerStateWithDescriptor:sd];

    // Try to load a real boat model; fall back to the box-boat if absent.
    _boatMeshes = [NSMutableArray array];
    _boatSubmeshTextures = [NSMutableArray array];
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    if (gModelPath) [candidates addObject:gModelPath];
    [candidates addObjectsFromArray:@[
        @"06-tugboat/assets/Tugboat.usdz",
        @"assets/Tugboat.usdz",
        @"metal-examples/06-tugboat/assets/Tugboat.usdz",
    ]];
    for (NSString *path in candidates) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [self loadBoatFromURL:[NSURL fileURLWithPath:path]
                           device:device library:library view:view];
            break;
        }
    }
    if (_boatMeshes.count == 0)
        printf("No boat model found; using the procedural box-boat.\n");

    _boatPos = simd_make_float2(0, 0);
    _heading = 0;
    _speed = 0;
    _throttle = 0;
    _score = 0;
    _rng.seed(7);
    for (int i = 0; i < kBuoyCount; i++) [self respawnBuoy:i];

    // Keyboard: a local event monitor beats subclassing the view.
    memset(_keys, 0, sizeof(_keys));
    __unsafe_unretained TugboatRenderer *weakSelf = self;
    [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskKeyDown | NSEventMaskKeyUp)
                                          handler:^NSEvent *(NSEvent *event) {
        if (event.modifierFlags & NSEventModifierFlagCommand) return event; // keep Cmd+Q
        unsigned short code = event.keyCode;
        if (code < 128) {
            weakSelf->_keys[code] = (event.type == NSEventTypeKeyDown);
            return nil;
        }
        return event;
    }];

    printf("Controls:\n"
           "  W/Up  throttle up     A/Left   rudder left\n"
           "  S/Down throttle down  D/Right  rudder right\n"
           "  Space cut throttle    R        reset boat\n");

    _startTime = CACurrentMediaTime();
    _lastFrameTime = _startTime;
    _smoothedFPS = 60;
    return self;
}

- (void)respawnBuoy:(int)i {
    std::uniform_real_distribution<float> angleDist(0.0f, 2.0f * (float)M_PI);
    std::uniform_real_distribution<float> radiusDist(18.0f, 55.0f);
    float a = angleDist(_rng);
    float r = radiusDist(_rng);
    _buoys[i] = _boatPos + simd_make_float2(r * cosf(a), r * sinf(a));
}

// A 1x1 linear texture of a flat color, for submeshes whose material has a
// base color value rather than an image (keeps the shader to one code path).
- (id<MTLTexture>)solidTexture:(simd_float4)c device:(id<MTLDevice>)device {
    MTLTextureDescriptor *d =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:1 height:1 mipmapped:NO];
    id<MTLTexture> t = [device newTextureWithDescriptor:d];
    uint8_t px[4] = {
        (uint8_t)(std::clamp(c.x, 0.0f, 1.0f) * 255.0f),
        (uint8_t)(std::clamp(c.y, 0.0f, 1.0f) * 255.0f),
        (uint8_t)(std::clamp(c.z, 0.0f, 1.0f) * 255.0f),
        255,
    };
    [t replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:px bytesPerRow:4];
    return t;
}

// Resolve a submesh's base-color to an MTLTexture: the material's image if it
// has one, otherwise a flat color, otherwise neutral grey.
- (id<MTLTexture>)textureForMaterial:(MDLMaterial *)material
                              loader:(MTKTextureLoader *)loader
                              device:(id<MTLDevice>)device {
    id<MTLTexture> tex = nil;
    MDLMaterialProperty *bc = [material propertyWithSemantic:MDLMaterialSemanticBaseColor];
    if (bc) {
        if (bc.type == MDLMaterialPropertyTypeTexture && bc.textureSamplerValue.texture) {
            CGImageRef img = [bc.textureSamplerValue.texture imageFromTexture];
            if (img) {
                NSError *e = nil;
                tex = [loader newTextureWithCGImage:img
                                            options:@{MTKTextureLoaderOptionSRGB: @YES,
                                                      MTKTextureLoaderOptionGenerateMipmaps: @YES}
                                              error:&e];
                CGImageRelease(img);
            }
        } else if (bc.type == MDLMaterialPropertyTypeFloat3) {
            tex = [self solidTexture:simd_make_float4(bc.float3Value.x, bc.float3Value.y,
                                                      bc.float3Value.z, 1)
                              device:device];
        } else if (bc.type == MDLMaterialPropertyTypeFloat4) {
            tex = [self solidTexture:bc.float4Value device:device];
        }
    }
    if (!tex) tex = [self solidTexture:simd_make_float4(0.6f, 0.6f, 0.62f, 1) device:device];
    return tex;
}

- (BOOL)loadBoatFromURL:(NSURL *)url
                 device:(id<MTLDevice>)device
                library:(id<MTLLibrary>)library
                   view:(MTKView *)view {
    MTKMeshBufferAllocator *allocator =
        [[MTKMeshBufferAllocator alloc] initWithDevice:device];

    // Interleaved position/normal/uv, the layout the boat pipeline expects.
    MDLVertexDescriptor *vd = [[MDLVertexDescriptor alloc] init];
    vd.attributes[0] = [[MDLVertexAttribute alloc] initWithName:MDLVertexAttributePosition
                                                         format:MDLVertexFormatFloat3
                                                         offset:0 bufferIndex:0];
    vd.attributes[1] = [[MDLVertexAttribute alloc] initWithName:MDLVertexAttributeNormal
                                                         format:MDLVertexFormatFloat3
                                                         offset:12 bufferIndex:0];
    vd.attributes[2] = [[MDLVertexAttribute alloc] initWithName:MDLVertexAttributeTextureCoordinate
                                                         format:MDLVertexFormatFloat2
                                                         offset:24 bufferIndex:0];
    vd.layouts[0] = [[MDLVertexBufferLayout alloc] initWithStride:32];

    MDLAsset *asset = [[MDLAsset alloc] initWithURL:url
                                   vertexDescriptor:vd
                                    bufferAllocator:allocator];
    [asset loadTextures];

    NSArray<MDLMesh *> *mdlMeshes = [asset childObjectsOfClass:[MDLMesh class]];
    if (mdlMeshes.count == 0) {
        printf("Boat asset has no meshes; using the procedural box-boat.\n");
        return NO;
    }

    // Pipeline that consumes the Model I/O vertex layout.
    NSError *error = nil;
    MTLRenderPipelineDescriptor *pdesc = [MTLRenderPipelineDescriptor new];
    pdesc.vertexFunction = [library newFunctionWithName:@"boat_vertex"];
    pdesc.fragmentFunction = [library newFunctionWithName:@"boat_fragment"];
    pdesc.vertexDescriptor = MTKMetalVertexDescriptorFromModelIO(vd);
    pdesc.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    pdesc.depthAttachmentPixelFormat = view.depthStencilPixelFormat;
    _boatPipeline = [device newRenderPipelineStateWithDescriptor:pdesc error:&error];
    if (!_boatPipeline) {
        fprintf(stderr, "Boat pipeline error: %s\n", error.localizedDescription.UTF8String);
        return NO;
    }

    MTKTextureLoader *loader = [[MTKTextureLoader alloc] initWithDevice:device];
    for (MDLMesh *m in mdlMeshes) {
        MTKMesh *mtk = [[MTKMesh alloc] initWithMesh:m device:device error:&error];
        if (!mtk) {
            fprintf(stderr, "MTKMesh error: %s\n", error.localizedDescription.UTF8String);
            continue;
        }
        simd_float4x4 world = [MDLTransform globalTransformWithObject:m atTime:0.0];
        NSMutableArray<id<MTLTexture>> *texs = [NSMutableArray array];
        for (MDLSubmesh *sm in m.submeshes) {
            [texs addObject:[self textureForMaterial:sm.material loader:loader device:device]];
        }
        [_boatMeshes addObject:mtk];
        [_boatSubmeshTextures addObject:texs];
        _boatMeshXforms.push_back(world);
    }
    if (_boatMeshes.count == 0) return NO;

    // Fixup: recenter, scale the footprint to a sensible size, orient, and set
    // the draft so the hull rides at the waterline. Folded into each mesh's
    // node transform once, up front.
    MDLAxisAlignedBoundingBox bb = asset.boundingBox;
    simd_float3 mn = bb.minBounds, mx = bb.maxBounds;
    simd_float3 center = (mn + mx) * 0.5f;
    simd_float3 sz = mx - mn;
    float footprint = fmaxf(sz.x, fmaxf(sz.y, sz.z));  // largest dim = boat length
    if (footprint < 1e-4f) footprint = 1.0f;
    float s = kBoatTargetLength / footprint;
    float yaw = kBoatYawDeg * (float)M_PI / 180.0f;
    float pitch = kBoatPitchDeg * (float)M_PI / 180.0f;

    // Recenter -> scale -> orient, then measure the oriented model's lowest
    // point so the draft is correct no matter which axis was "up".
    simd_float4x4 rs = simd_mul(simd_mul(RotYMat(yaw), RotXMat(pitch)),
                                simd_mul(ScaleMat(s), TransMat(-center)));
    float minY = 1e30f;
    for (int c = 0; c < 8; c++) {
        simd_float3 corner = simd_make_float3((c & 1) ? mx.x : mn.x,
                                              (c & 2) ? mx.y : mn.y,
                                              (c & 4) ? mx.z : mn.z);
        simd_float4 p = simd_mul(rs, simd_make_float4(corner, 1));
        minY = fminf(minY, p.y);
    }
    simd_float4x4 fixup =
        simd_mul(TransMat(simd_make_float3(0, -minY - kBoatDraft, 0)), rs);
    for (simd_float4x4 &m : _boatMeshXforms) m = simd_mul(fixup, m);

    printf("Boat loaded: %lu mesh(es), bbox (%.2f x %.2f x %.2f), scale %.4f\n",
           (unsigned long)_boatMeshes.count, sz.x, sz.y, sz.z, s);
    return YES;
}

- (void)stepGame:(float)dt time:(float)t {
    float throttleInput = (_keys[kKeyW] || _keys[kKeyUp] ? 1.0f : 0.0f) -
                          (_keys[kKeyS] || _keys[kKeyDown] ? 1.0f : 0.0f);
    _throttle = std::clamp(_throttle + throttleInput * 0.7f * dt, -0.4f, 1.0f);
    if (_keys[kKeySpace]) _throttle *= expf(-6.0f * dt);
    if (_keys[kKeyR]) {
        _boatPos = simd_make_float2(0, 0); _heading = 0; _speed = 0; _throttle = 0;
        _particles.clear();
    }

    float steer = (_keys[kKeyD] || _keys[kKeyRight] ? 1.0f : 0.0f) -
                  (_keys[kKeyA] || _keys[kKeyLeft] ? 1.0f : 0.0f);

    // Rudder authority grows with speed; reverses when backing up.
    float flow = std::min(fabsf(_speed) / 4.0f + 0.15f, 1.0f);
    _heading += steer * 1.5f * flow * dt * (_speed >= 0 ? 1.0f : -1.0f);

    // Throttle drives, drag brakes. Tugs are torquey but slow.
    _speed += (_throttle * 6.0f - _speed * 0.8f) * dt;

    simd_float2 fwd = simd_make_float2(sinf(_heading), -cosf(_heading));
    _boatPos += fwd * _speed * dt;

    // Cache the boat's floating transform so rendering and particle emission
    // agree on where the funnel and stern are this frame.
    WaveSample ws = SampleWaves(_boatPos, t);
    simd_float3 worldUp = simd_make_float3(0, 1, 0);
    _boatUp = simd_normalize(worldUp + (ws.normal - worldUp) * 0.5f);
    simd_float3 bFwd0 = simd_make_float3(sinf(_heading), 0, -cosf(_heading));
    _boatRight = simd_normalize(simd_cross(bFwd0, _boatUp));
    _boatBack = simd_cross(_boatRight, _boatUp);
    _boatWorldPos = simd_make_float3(_boatPos.x, ws.height - 0.25f, _boatPos.y);

    [self emitSmoke:dt];
    [self emitWake:dt time:t];
    [self stepParticles:dt time:t];

    for (int i = 0; i < kBuoyCount; i++) {
        if (simd_distance(_boatPos, _buoys[i]) < kCollectRadius) {
            _score++;
            printf("Buoy collected! Total: %d\n", _score);
            [self respawnBuoy:i];
        }
    }
}

// Transform a point in the boat's local frame (forward = -z, up = +y, origin
// at the waterline) into world space using the cached floating transform.
- (simd_float3)localToWorld:(simd_float3)p {
    return _boatWorldPos + _boatRight * p.x + _boatUp * p.y + _boatBack * p.z;
}

- (void)emitSmoke:(float)dt {
    std::uniform_real_distribution<float> pm(-1.0f, 1.0f);
    std::uniform_real_distribution<float> u01(0.0f, 1.0f);
    // Idles gently, belches when you open the throttle.
    float rate = 16.0f + 42.0f * std::max(_throttle, 0.0f);
    _smokeAccum += dt * rate;
    simd_float3 fwdH = simd_make_float3(sinf(_heading), 0, -cosf(_heading));
    while (_smokeAccum >= 1.0f) {
        _smokeAccum -= 1.0f;
        if ((int)_particles.size() >= kMaxParticles) break;
        Particle p;
        p.kind = 0;
        // Funnel mouth: local (0, ~3.05, 2.1), with a little scatter.
        simd_float3 local = simd_make_float3(pm(_rng) * 0.15f, 3.05f, 2.1f + pm(_rng) * 0.15f);
        p.pos = [self localToWorld:local];
        p.vel = simd_make_float3(0, 1.5f, 0)          // rises
              + (-fwdH) * (_speed * 0.35f)            // trails behind the boat
              + simd_make_float3(0.5f, 0, 0.25f)      // a light breeze
              + simd_make_float3(pm(_rng), 0.4f * u01(_rng), pm(_rng)) * 0.35f;
        p.age = 0;
        p.life = 2.6f + u01(_rng) * 0.8f;
        p.size0 = 0.5f;
        p.size1 = 3.2f + u01(_rng);
        p.color0 = simd_make_float4(0.20f, 0.20f, 0.22f, 0.55f);   // dark diesel puff
        p.color1 = simd_make_float4(0.55f, 0.56f, 0.60f, 0.0f);    // thins out pale
        _particles.push_back(p);
    }
}

- (void)emitWake:(float)dt time:(float)t {
    if (fabsf(_speed) < 0.4f) return;   // no wash when barely moving
    std::uniform_real_distribution<float> pm(-1.0f, 1.0f);
    std::uniform_real_distribution<float> u01(0.0f, 1.0f);
    float rate = fabsf(_speed) * 9.0f;  // faster boat -> denser foam
    _wakeAccum += dt * rate;
    simd_float3 fwdH = simd_make_float3(sinf(_heading), 0, -cosf(_heading));
    simd_float3 rightH = simd_normalize(simd_cross(fwdH, simd_make_float3(0, 1, 0)));
    while (_wakeAccum >= 1.0f) {
        _wakeAccum -= 1.0f;
        if ((int)_particles.size() >= kMaxParticles) break;
        float side = (u01(_rng) < 0.5f) ? -1.0f : 1.0f;
        Particle p;
        p.kind = 1;
        // Two streams off the stern quarters spread into a V.
        simd_float3 local = simd_make_float3(side * (0.5f + u01(_rng) * 0.3f), 0.1f, 2.7f);
        simd_float3 world = [self localToWorld:local];
        WaveSample sw = SampleWaves(simd_make_float2(world.x, world.z), t);
        world.y = sw.height + 0.06f;
        p.pos = world;
        p.vel = rightH * (side * (0.7f + u01(_rng) * 0.5f))   // fan outward
              + (-fwdH) * 0.25f                                // settle astern
              + simd_make_float3(pm(_rng), 0, pm(_rng)) * 0.15f;
        p.vel.y = 0;
        p.age = 0;
        p.life = 1.6f + u01(_rng) * 0.9f;
        p.size0 = 0.35f;
        p.size1 = 2.2f + u01(_rng) * 0.8f;
        p.color0 = simd_make_float4(0.92f, 0.96f, 1.0f, 0.55f);   // bright foam
        p.color1 = simd_make_float4(0.80f, 0.88f, 0.95f, 0.0f);   // fades to nothing
        _particles.push_back(p);
    }
}

- (void)stepParticles:(float)dt time:(float)t {
    for (Particle &p : _particles) {
        p.age += dt;
        p.pos += p.vel * dt;
        if (p.kind == 0) {
            p.vel.y *= expf(-0.6f * dt);   // buoyant rise eases off
            p.vel.x *= expf(-0.3f * dt);
            p.vel.z *= expf(-0.3f * dt);
        } else {
            // Foam clings to the moving water surface and spreads then settles.
            WaveSample sw = SampleWaves(simd_make_float2(p.pos.x, p.pos.z), t);
            p.pos.y = sw.height + 0.06f;
            p.vel *= expf(-1.2f * dt);
        }
    }
    _particles.erase(std::remove_if(_particles.begin(), _particles.end(),
                     [](const Particle &p) { return p.age >= p.life; }),
                     _particles.end());
}

- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) return;

    double now = CACurrentMediaTime();
    float t = (float)(now - _startTime);
    float dtRaw = (float)(now - _lastFrameTime);
    _lastFrameTime = now;
    float dt = std::min(dtRaw, 1.0f / 30.0f);
    if (dtRaw > 0) _smoothedFPS += (1.0f / dtRaw - _smoothedFPS) * 0.05f;

    [self stepGame:dt time:t];

    // Chase camera looking down at the boat at a 30° angle above the water.
    const float depression = 30.0f * (float)M_PI / 180.0f;
    const float camDist = 42.0f;
    simd_float3 target = simd_make_float3(_boatPos.x, 0.6f, _boatPos.y);
    simd_float3 eye = target +
        simd_make_float3(0.0f, sinf(depression), cosf(depression)) * camDist;
    simd_float3 fwd = simd_normalize(target - eye);
    simd_float3 right = simd_normalize(simd_cross(fwd, simd_make_float3(0, 1, 0)));
    simd_float3 up = simd_cross(right, fwd);

    float aspect = (float)(view.drawableSize.width / view.drawableSize.height);
    simd_float4x4 proj = Perspective(55.0f * (float)M_PI / 180.0f, aspect, 1.0f, 300.0f);
    simd_float4x4 viewProj = simd_mul(proj, LookAt(eye, right, up, fwd));

    simd_float4 sun = simd_make_float4(simd_normalize(simd_make_float3(0.5f, 0.75f, 0.35f)), t);

    // Water grid follows the boat, snapped to the grid so vertices don't swim.
    simd_float2 gridOrigin = {
        floorf(_boatPos.x / kSpacing) * kSpacing,
        floorf(_boatPos.y / kSpacing) * kSpacing,
    };

    // Build this frame's particle billboards into the next ring buffer. Wake
    // foam goes first, then smoke, so we can draw them in separate layers
    // (wake below the boat, smoke above it) from one buffer.
    dispatch_semaphore_wait(_frameSemaphore, DISPATCH_TIME_FOREVER);
    id<MTLBuffer> particleBuffer = _particleBuffers[_frameIndex];
    _particleScratch.clear();
    for (const Particle &p : _particles)
        if (p.kind == 1) AppendBillboard(_particleScratch, p, right, up);
    NSUInteger wakeVerts = _particleScratch.size();
    for (const Particle &p : _particles)
        if (p.kind == 0) AppendBillboard(_particleScratch, p, right, up);
    NSUInteger totalVerts = _particleScratch.size();
    NSUInteger smokeVerts = totalVerts - wakeVerts;
    if (totalVerts > 0) {
        memcpy([particleBuffer contents], _particleScratch.data(),
               totalVerts * sizeof(ParticleVertex));
    }

    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [commands renderCommandEncoderWithDescriptor:pass];
    [enc setCullMode:MTLCullModeNone];

    // Water
    Uniforms u = {};
    u.mvp = viewProj;
    u.model = matrix_identity_float4x4;
    u.camPos = simd_make_float4(eye, 0);
    u.sun = sun;
    u.misc = simd_make_float4(gridOrigin.x, gridOrigin.y, 0, 0);
    [enc setDepthStencilState:_depthState];
    [enc setRenderPipelineState:_waterPipeline];
    [enc setVertexBytes:&u length:sizeof(u) atIndex:0];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle
             vertexStart:0
             vertexCount:(NSUInteger)kGrid * kGrid * 6];

    // Wake foam: on the water, beneath the boat.
    if (wakeVerts > 0) {
        [enc setRenderPipelineState:_particlePipeline];
        [enc setDepthStencilState:_noDepthState];
        [enc setVertexBuffer:particleBuffer offset:0 atIndex:0];
        [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:wakeVerts];
    }

    // Boat: the loaded asset if we have one, else the procedural box-boat.
    // Both ride the same cached floating transform.
    simd_float4x4 floatTransform = ModelMatrix(_boatRight, _boatUp, _boatBack, _boatWorldPos);
    [enc setDepthStencilState:_depthState];
    if (_boatMeshes.count > 0) {
        [enc setRenderPipelineState:_boatPipeline];
        [enc setFragmentSamplerState:_sampler atIndex:0];
        for (NSUInteger mi = 0; mi < _boatMeshes.count; mi++) {
            MTKMesh *mesh = _boatMeshes[mi];
            NSArray<id<MTLTexture>> *texs = _boatSubmeshTextures[mi];
            simd_float4x4 model = simd_mul(floatTransform, _boatMeshXforms[mi]);
            Uniforms bu = u;
            bu.mvp = simd_mul(viewProj, model);
            bu.model = model;
            for (NSUInteger bi = 0; bi < mesh.vertexBuffers.count; bi++) {
                id vbObj = mesh.vertexBuffers[bi];
                if (![vbObj isKindOfClass:[MTKMeshBuffer class]]) continue;
                MTKMeshBuffer *vb = vbObj;
                [enc setVertexBuffer:vb.buffer offset:vb.offset atIndex:bi];
            }
            [enc setVertexBytes:&bu length:sizeof(bu) atIndex:1];
            [enc setFragmentBytes:&bu length:sizeof(bu) atIndex:0];
            NSUInteger j = 0;
            for (MTKSubmesh *sm in mesh.submeshes) {
                id<MTLTexture> tex = (j < texs.count) ? texs[j] : nil;
                [enc setFragmentTexture:tex atIndex:0];
                [enc drawIndexedPrimitives:sm.primitiveType
                                indexCount:sm.indexCount
                                 indexType:sm.indexType
                               indexBuffer:sm.indexBuffer.buffer
                         indexBufferOffset:sm.indexBuffer.offset];
                j++;
            }
        }
    } else {
        [enc setRenderPipelineState:_solidPipeline];
        Uniforms bu = u;
        bu.mvp = simd_mul(viewProj, floatTransform);
        bu.model = floatTransform;
        [enc setVertexBuffer:_boatMesh offset:0 atIndex:0];
        [enc setVertexBytes:&bu length:sizeof(bu) atIndex:1];
        [enc setFragmentBytes:&bu length:sizeof(bu) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:_boatVertexCount];
    }

    // Buoys: bob and slowly spin.
    [enc setRenderPipelineState:_solidPipeline];
    [enc setVertexBuffer:_buoyMesh offset:0 atIndex:0];
    for (int i = 0; i < kBuoyCount; i++) {
        WaveSample ws = SampleWaves(_buoys[i], t);
        float spin = t * 0.8f + (float)i * 1.3f;
        simd_float3 worldUp = simd_make_float3(0, 1, 0);
        simd_float3 bRight = simd_make_float3(cosf(spin), 0, sinf(spin));
        simd_float3 bUp = simd_normalize(worldUp + (ws.normal - worldUp) * 0.7f);
        simd_float3 bBack = simd_normalize(simd_cross(bRight, bUp));
        bRight = simd_cross(bUp, bBack);
        simd_float3 pos = simd_make_float3(_buoys[i].x, ws.height - 0.15f, _buoys[i].y);
        simd_float4x4 model = ModelMatrix(bRight, bUp, bBack, pos);

        Uniforms su = u;
        su.mvp = simd_mul(viewProj, model);
        su.model = model;
        [enc setVertexBytes:&su length:sizeof(su) atIndex:1];
        [enc setFragmentBytes:&su length:sizeof(su) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:_buoyVertexCount];
    }

    // Smoke: over everything.
    if (smokeVerts > 0) {
        [enc setRenderPipelineState:_particlePipeline];
        [enc setDepthStencilState:_noDepthState];
        [enc setVertexBuffer:particleBuffer offset:0 atIndex:0];
        [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:wakeVerts vertexCount:smokeVerts];
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

    view.window.title = [NSString stringWithFormat:
        @"06 — Tugboat ⚓ Buoys: %d — Throttle %+d%% — %.0f fps",
        _score, (int)lroundf(_throttle * 100), _smoothedFPS];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

@end

int main(int argc, const char *argv[]) {
    if (argc > 1) gModelPath = [NSString stringWithUTF8String:argv[1]];
    return RunMetalApp(@"06 — Tugboat", 1100, 700, ^(MTKView *view) {
        return (NSObject<MTKViewDelegate> *)[[TugboatRenderer alloc] initWithView:view];
    });
}
