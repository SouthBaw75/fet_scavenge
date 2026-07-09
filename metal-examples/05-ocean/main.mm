// 05 — Ocean
//
// How games render water, in one file. A flat grid of ~780k vertices is
// displaced every frame by a sum of six Gerstner waves in the vertex shader —
// the classic technique from GPU Gems that shipped in countless games. The
// fragment shader then does the things that make water read as water:
//
//   * Fresnel — water is a mirror at grazing angles, transparent looking down
//   * Sky reflection and a low sun with a hot specular glint
//   * A touch of subsurface scattering through backlit wave crests
//   * Procedural foam on the crests, broken up with value noise
//   * Distance fog that dissolves the mesh edge into the horizon
//
// The sky itself is a second, bufferless fullscreen pass. No textures, no
// assets — every pixel is math.

#include "../common/app.h"
#include <simd/simd.h>
#include <algorithm>
#include <string>

static const int kGrid = 360;        // quads per side
static const float kSpacing = 0.55f; // meters per quad

static const char *kShaderSource = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 mvp;
    float4 camPos;   // xyz = position
    float4 camRight; // xyz = basis
    float4 camUp;
    float4 camFwd;   // xyz = basis, w = focal length (1/tan(fov/2))
    float4 sun;      // xyz = direction to sun, w = time
    float4 misc;     // xy = drawable resolution, z = wave intensity
};

// dir.x, dir.z, amplitude, wavelength — a swell plus five layers of chop.
constant float4 kWaves[6] = {
    float4(1.00,  0.15, 0.85, 26.0),
    float4(0.80,  0.45, 0.42, 15.0),
    float4(1.00, -0.35, 0.28,  9.5),
    float4(0.60,  0.80, 0.15,  5.5),
    float4(0.90, -0.70, 0.08,  3.2),
    float4(0.40,  1.00, 0.045, 1.8),
};

struct Wave {
    float3 pos;
    float3 normal;
    float  crest;   // -1..1, how near the top of the combined wave we are
};

// Gerstner waves (GPU Gems ch.1): points move in circles, so crests get
// sharp and troughs get flat — the shape that makes it read as ocean
// instead of rippling jelly. Deep-water dispersion: omega = sqrt(g*k),
// so long waves travel faster than short ones, like the real sea.
Wave gerstner(float2 xz, float time, float intensity) {
    float3 p = float3(xz.x, 0.0, xz.y);
    float3 n = float3(0.0, 1.0, 0.0);
    float ampSum = 0.0;
    for (int i = 0; i < 6; i++) {
        float2 D = normalize(kWaves[i].xy);
        float A = kWaves[i].z * intensity;
        float k = 2.0 * M_PI_F / kWaves[i].w;
        float omega = sqrt(9.8 * k);
        float Q = 0.62 / (k * A * 6.0);   // steepness, spread across the sum
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

// --- Value noise, for foam breakup and fine normal detail ---

float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 3; i++) {
        v += a * vnoise(p);
        p *= 2.13;
        a *= 0.5;
    }
    return v;
}

float3 skyColor(float3 rd, float3 sun) {
    float3 col = mix(float3(0.75, 0.80, 0.85),           // haze at the horizon
                     float3(0.18, 0.38, 0.66),           // zenith blue
                     saturate(rd.y * 1.6 + 0.05));
    float sd = max(dot(rd, sun), 0.0);
    col += float3(1.0, 0.75, 0.50) * pow(sd, 6.0) * 0.35;   // warm glow
    col += float3(1.0, 0.90, 0.70) * pow(sd, 1200.0) * 18.0; // the disc itself
    return col;
}

float3 tonemap(float3 c) {
    // ACES-ish curve so the sun glint rolls off instead of clipping.
    return saturate((c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14));
}

// ---------------- Sky pass: one fullscreen triangle ----------------

struct SkyVSOut {
    float4 position [[position]];
};

vertex SkyVSOut sky_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    SkyVSOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

fragment float4 sky_fragment(SkyVSOut in [[stage_in]],
                             constant Uniforms &u [[buffer(0)]]) {
    float2 res = u.misc.xy;
    float2 ndc = float2(2.0 * in.position.x / res.x - 1.0,
                        1.0 - 2.0 * in.position.y / res.y);
    float aspect = res.x / res.y;
    float focal = u.camFwd.w;
    float3 rd = normalize(u.camFwd.xyz +
                          u.camRight.xyz * (ndc.x * aspect / focal) +
                          u.camUp.xyz * (ndc.y / focal));
    float3 col = skyColor(rd, u.sun.xyz);
    return float4(pow(tonemap(col), float3(0.4545)), 1.0);
}

// ---------------- Ocean pass: the displaced grid ----------------

struct OceanVSOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float  crest;
};

constant uint2 kCorner[6] = {
    uint2(0, 0), uint2(1, 0), uint2(1, 1),
    uint2(0, 0), uint2(1, 1), uint2(0, 1),
};

vertex OceanVSOut ocean_vertex(uint vid [[vertex_id]],
                               constant Uniforms &u [[buffer(0)]]) {
    // No vertex buffer: derive the grid position from the vertex index.
    uint quad = vid / 6;
    uint2 corner = kCorner[vid % 6];
    float2 xz = (float2(quad % GRID + corner.x, quad / GRID + corner.y)
                 - GRID * 0.5) * SPACING;

    Wave w = gerstner(xz, u.sun.w, u.misc.z);
    OceanVSOut out;
    out.position = u.mvp * float4(w.pos, 1.0);
    out.world = w.pos;
    out.normal = w.normal;
    out.crest = w.crest;
    return out;
}

fragment float4 ocean_fragment(OceanVSOut in [[stage_in]],
                               constant Uniforms &u [[buffer(0)]]) {
    float time = u.sun.w;
    float3 sun = u.sun.xyz;
    float3 toCam = u.camPos.xyz - in.world;
    float dist = length(toCam);
    float3 V = toCam / dist;

    // Fine ripple detail on top of the interpolated geometric normal.
    float2 dp = in.world.xz * 1.3 + float2(time * 0.4, time * 0.25);
    float hC = fbm(dp);
    float hX = fbm(dp + float2(0.33, 0.0));
    float hZ = fbm(dp + float2(0.0, 0.33));
    float3 n = normalize(normalize(in.normal) + float3(hC - hX, 0.0, hC - hZ) * 0.9);

    // Fresnel: ~2% reflective looking straight down, a mirror at grazing angles.
    float fresnel = 0.02 + 0.98 * pow(1.0 - max(dot(n, V), 0.0), 5.0);

    // What the mirror sees.
    float3 R = reflect(-V, n);
    R.y = max(R.y, 0.03);
    float3 reflection = skyColor(normalize(R), sun);

    // What's under the surface: deep water, plus light scattering through
    // the top of backlit crests.
    float3 deep = float3(0.02, 0.11, 0.16);
    float scatter = pow(max(dot(-V, sun), 0.0), 3.0) * max(in.crest, 0.0);
    float3 body = deep + float3(0.0, 0.25, 0.20) * scatter * 0.9;

    float3 color = mix(body, reflection, fresnel);

    // Sun glint.
    color += float3(1.0, 0.85, 0.6) * pow(max(dot(R, sun), 0.0), 250.0) * (2.5 * fresnel + 0.3);

    // Foam where the crest is high, broken up by noise so it isn't a stripe.
    // Heavier seas break more: whitecaps multiply with intensity.
    float rough = clamp(u.misc.z, 0.25, 2.5);
    float foamMask = fbm(in.world.xz * 0.7 + float2(time * 0.2, -time * 0.15));
    float foam = smoothstep(0.35, 0.8, in.crest * (0.55 + 0.45 * rough))
               * smoothstep(0.35, 0.75, foamMask + 0.25 * in.crest);
    color = mix(color, float3(0.90, 0.93, 0.95), foam * 0.75);

    // Fade the far edge of the grid into the sky so it has no visible border.
    float3 rd = -V;
    float3 horizon = skyColor(normalize(float3(rd.x, 0.015, rd.z)), sun);
    color = mix(color, horizon, smoothstep(60.0, 95.0, dist));

    return float4(pow(tonemap(color), float3(0.4545)), 1.0);
}
)METAL";

struct Uniforms {
    simd_float4x4 mvp;
    simd_float4 camPos;
    simd_float4 camRight;
    simd_float4 camUp;
    simd_float4 camFwd;
    simd_float4 sun;
    simd_float4 misc;
};

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

@interface OceanRenderer : NSObject <MTKViewDelegate>
- (instancetype)initWithView:(MTKView *)view;
@end

@implementation OceanRenderer {
    float _intensity;        // sea state: 0.2 calm .. 2.5 storm
    float _intensityShown;   // eased value actually sent to the GPU
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _skyPipeline;
    id<MTLRenderPipelineState> _oceanPipeline;
    id<MTLDepthStencilState> _skyDepth;
    id<MTLDepthStencilState> _oceanDepth;
    double _startTime;
    FPSCounter _fps;
}

- (instancetype)initWithView:(MTKView *)view {
    if (!(self = [super init])) return nil;

    id<MTLDevice> device = view.device;
    _queue = [device newCommandQueue];
    view.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    view.clearColor = MTLClearColorMake(0.18, 0.38, 0.66, 1.0);

    std::string source = "#define GRID " + std::to_string(kGrid) +
                         "\n#define SPACING " + std::to_string(kSpacing) + "f\n" +
                         kShaderSource;
    id<MTLLibrary> library = CompileLibrary(device, source.c_str());
    if (!library) return nil;

    NSError *error = nil;

    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    desc.depthAttachmentPixelFormat = view.depthStencilPixelFormat;

    desc.vertexFunction = [library newFunctionWithName:@"sky_vertex"];
    desc.fragmentFunction = [library newFunctionWithName:@"sky_fragment"];
    _skyPipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!_skyPipeline) {
        fprintf(stderr, "Sky pipeline error: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }

    desc.vertexFunction = [library newFunctionWithName:@"ocean_vertex"];
    desc.fragmentFunction = [library newFunctionWithName:@"ocean_fragment"];
    _oceanPipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!_oceanPipeline) {
        fprintf(stderr, "Ocean pipeline error: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }

    MTLDepthStencilDescriptor *depthDesc = [MTLDepthStencilDescriptor new];
    depthDesc.depthCompareFunction = MTLCompareFunctionAlways;
    depthDesc.depthWriteEnabled = NO;
    _skyDepth = [device newDepthStencilStateWithDescriptor:depthDesc];

    depthDesc.depthCompareFunction = MTLCompareFunctionLess;
    depthDesc.depthWriteEnabled = YES;
    _oceanDepth = [device newDepthStencilStateWithDescriptor:depthDesc];

    _intensity = 1.0f;
    _intensityShown = 1.0f;

    // Sea-state controls: up/down arrows (or +/-) adjust smoothly, 1-5 are
    // presets from glassy calm to full storm.
    __unsafe_unretained OceanRenderer *weakSelf = self;
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                          handler:^NSEvent *(NSEvent *event) {
        if (event.modifierFlags & NSEventModifierFlagCommand) return event;
        unsigned short c = event.keyCode;
        float &inten = weakSelf->_intensity;
        if (c == 126 || c == 24) { inten = std::min(inten * 1.15f, 2.5f); return nil; } // up / =
        if (c == 125 || c == 27) { inten = std::max(inten / 1.15f, 0.2f); return nil; } // down / -
        if (c == 18) { inten = 0.30f; return nil; }   // 1 glassy
        if (c == 19) { inten = 0.65f; return nil; }   // 2 light chop
        if (c == 20) { inten = 1.00f; return nil; }   // 3 default
        if (c == 21) { inten = 1.60f; return nil; }   // 4 heavy
        if (c == 23) { inten = 2.40f; return nil; }   // 5 storm
        return event;
    }];
    printf("Sea state: Up/Down (or +/-) adjust wave intensity, 1-5 presets.\n");

    _startTime = CACurrentMediaTime();
    return self;
}

- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) return;

    float t = (float)(CACurrentMediaTime() - _startTime);
    float aspect = (float)(view.drawableSize.width / view.drawableSize.height);

    // Glide toward the requested sea state so changes swell in smoothly.
    _intensityShown += (_intensity - _intensityShown) * 0.06f;

    // A boat-like camera: fixed position with a gentle bob (heavier seas
    // toss the boat harder), slowly panning back and forth across the sun.
    float bob = 0.25f * _intensityShown;
    simd_float3 eye = simd_make_float3(0.0f, 5.5f + bob * sinf(t * 0.5f), 0.0f);
    float yaw = 0.6f + 0.45f * sinf(t * 0.07f);
    simd_float3 fwd = simd_normalize(simd_make_float3(cosf(yaw), -0.10f, sinf(yaw)));
    simd_float3 right = simd_normalize(simd_cross(fwd, simd_make_float3(0, 1, 0)));
    simd_float3 up = simd_cross(right, fwd);

    float fovy = 55.0f * (float)M_PI / 180.0f;
    float focal = 1.0f / tanf(fovy * 0.5f);
    simd_float4x4 proj = Perspective(fovy, aspect, 0.1f, 500.0f);
    simd_float4x4 viewM = LookAt(eye, right, up, fwd);

    Uniforms uniforms = {
        .mvp = simd_mul(proj, viewM),
        .camPos = simd_make_float4(eye, 0),
        .camRight = simd_make_float4(right, 0),
        .camUp = simd_make_float4(up, 0),
        .camFwd = simd_make_float4(fwd, focal),
        .sun = simd_make_float4(simd_normalize(simd_make_float3(0.8f, 0.12f, 0.55f)), t),
        .misc = simd_make_float4((float)view.drawableSize.width,
                                 (float)view.drawableSize.height,
                                 _intensityShown, 0),
    };

    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [commands renderCommandEncoderWithDescriptor:pass];

    [enc setRenderPipelineState:_skyPipeline];
    [enc setDepthStencilState:_skyDepth];
    [enc setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];

    [enc setRenderPipelineState:_oceanPipeline];
    [enc setDepthStencilState:_oceanDepth];
    [enc setCullMode:MTLCullModeNone];
    [enc setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [enc setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle
             vertexStart:0
             vertexCount:(NSUInteger)kGrid * kGrid * 6];

    [enc endEncoding];
    [commands presentDrawable:drawable];
    [commands commit];

    const char *seaName = _intensity < 0.45f ? "glassy" :
                          _intensity < 0.85f ? "light chop" :
                          _intensity < 1.30f ? "moderate" :
                          _intensity < 2.00f ? "heavy" : "STORM";
    _fps.tick(view.window, [NSString stringWithFormat:
        @"05 — Ocean ▸ Sea state x%.2f (%s) [↑/↓, 1-5]", _intensity, seaName]);
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

@end

int main() {
    return RunMetalApp(@"05 — Ocean", 1100, 650, ^(MTKView *view) {
        return (NSObject<MTKViewDelegate> *)[[OceanRenderer alloc] initWithView:view];
    });
}
