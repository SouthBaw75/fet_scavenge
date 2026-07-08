// 04 — Raymarched Scene
//
// No geometry at all: two triangles cover the screen and the fragment shader
// ray-marches a signed-distance-field world for every pixel — a bouncing
// sphere and an orbiting torus over a checkerboard floor, with soft shadows,
// ambient occlusion, fog, and an orbiting camera. At Retina resolution that's
// millions of ray marches per frame, every frame. Demoscene-style GPU flexing.

#include "../common/app.h"
#include <simd/simd.h>

static const char *kShaderSource = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 resolution;
    float  time;
};

struct VSOut {
    float4 position [[position]];
};

// One triangle big enough to cover the whole screen — no vertex buffer.
vertex VSOut vertex_main(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VSOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

// --- Signed distance functions ---

float sdSphere(float3 p, float r) { return length(p) - r; }

float sdTorus(float3 p, float2 t) {
    float2 q = float2(length(p.xz) - t.x, p.y);
    return length(q) - t.y;
}

float3x3 rotX(float a) {
    float c = cos(a), s = sin(a);
    return float3x3(float3(1, 0, 0), float3(0, c, s), float3(0, -s, c));
}

float3x3 rotY(float a) {
    float c = cos(a), s = sin(a);
    return float3x3(float3(c, 0, -s), float3(0, 1, 0), float3(s, 0, c));
}

// Returns (distance, materialId). Materials: 1 = floor, 2 = sphere, 3 = torus.
float2 map(float3 p, float time) {
    float2 res = float2(p.y + 1.0, 1.0);

    float3 sphereCenter = float3(0.0, 0.35 * abs(sin(time * 1.6)), 0.0);
    float dSphere = sdSphere(p - sphereCenter, 0.7);
    if (dSphere < res.x) res = float2(dSphere, 2.0);

    float3 q = rotX(time * 0.7) * (rotY(time * 0.5) * p);
    float dTorus = sdTorus(q, float2(1.3, 0.16));
    if (dTorus < res.x) res = float2(dTorus, 3.0);

    return res;
}

float3 calcNormal(float3 p, float time) {
    const float2 e = float2(0.001, 0.0);
    return normalize(float3(
        map(p + e.xyy, time).x - map(p - e.xyy, time).x,
        map(p + e.yxy, time).x - map(p - e.yxy, time).x,
        map(p + e.yyx, time).x - map(p - e.yyx, time).x));
}

float softShadow(float3 ro, float3 rd, float time) {
    float res = 1.0;
    float t = 0.02;
    for (int i = 0; i < 48; i++) {
        float h = map(ro + rd * t, time).x;
        res = min(res, 10.0 * h / t);
        t += clamp(h, 0.01, 0.25);
        if (res < 0.002 || t > 12.0) break;
    }
    return saturate(res);
}

float ambientOcclusion(float3 p, float3 n, float time) {
    float occ = 0.0, weight = 1.0;
    for (int i = 1; i <= 5; i++) {
        float h = 0.05 * float(i);
        occ += (h - map(p + n * h, time).x) * weight;
        weight *= 0.6;
    }
    return saturate(1.0 - 2.5 * occ);
}

fragment float4 fragment_main(VSOut in [[stage_in]],
                              constant Uniforms &u [[buffer(0)]]) {
    // Pixel -> camera ray. position.xy is in pixels, origin top-left.
    float2 frag = in.position.xy;
    float2 uv = (2.0 * frag - u.resolution) / u.resolution.y;
    uv.y = -uv.y;

    float time = u.time;
    float3 ro = float3(3.6 * cos(time * 0.3), 1.4, 3.6 * sin(time * 0.3));
    float3 target = float3(0.0, 0.0, 0.0);
    float3 fwd = normalize(target - ro);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);
    float3 rd = normalize(uv.x * right + uv.y * up + 1.6 * fwd);

    // March.
    float t = 0.0;
    float material = 0.0;
    for (int i = 0; i < 128; i++) {
        float2 h = map(ro + rd * t, time);
        if (h.x < 0.001) { material = h.y; break; }
        t += h.x;
        if (t > 30.0) break;
    }

    // Sky.
    float3 color = mix(float3(0.35, 0.45, 0.65), float3(0.05, 0.08, 0.15),
                       saturate(rd.y * 1.5 + 0.3));

    if (material > 0.5) {
        float3 p = ro + rd * t;
        float3 n = calcNormal(p, time);
        float3 lightDir = normalize(float3(0.7, 0.9, 0.4));

        float3 albedo;
        if (material < 1.5) {
            float checker = abs(fmod(floor(p.x) + floor(p.z), 2.0));
            albedo = mix(float3(0.22), float3(0.85), checker);
        } else if (material < 2.5) {
            albedo = float3(0.95, 0.30, 0.25);
        } else {
            albedo = float3(0.25, 0.55, 0.95);
        }

        float diffuse = max(dot(n, lightDir), 0.0) * softShadow(p + n * 0.01, lightDir, time);
        float3 h = normalize(lightDir - rd);
        float specular = pow(max(dot(n, h), 0.0), 48.0) * diffuse;
        float ao = ambientOcclusion(p, n, time);

        color = albedo * (0.15 * ao + 0.95 * diffuse) + specular * 0.6;
        color = mix(color, float3(0.35, 0.45, 0.65), 1.0 - exp(-0.015 * t * t)); // fog
    }

    color = pow(color, float3(0.4545)); // gamma
    return float4(color, 1.0);
}
)METAL";

struct Uniforms {
    simd_float2 resolution;
    float time;
};

@interface RaymarchRenderer : NSObject <MTKViewDelegate>
- (instancetype)initWithView:(MTKView *)view;
@end

@implementation RaymarchRenderer {
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    double _startTime;
    FPSCounter _fps;
}

- (instancetype)initWithView:(MTKView *)view {
    if (!(self = [super init])) return nil;

    id<MTLDevice> device = view.device;
    _queue = [device newCommandQueue];

    id<MTLLibrary> library = CompileLibrary(device, kShaderSource);
    if (!library) return nil;

    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [library newFunctionWithName:@"vertex_main"];
    desc.fragmentFunction = [library newFunctionWithName:@"fragment_main"];
    desc.colorAttachments[0].pixelFormat = view.colorPixelFormat;

    NSError *error = nil;
    _pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!_pipeline) {
        fprintf(stderr, "Pipeline error: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }

    _startTime = CACurrentMediaTime();
    return self;
}

- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) return;

    Uniforms uniforms = {
        .resolution = simd_make_float2((float)view.drawableSize.width,
                                       (float)view.drawableSize.height),
        .time = (float)(CACurrentMediaTime() - _startTime),
    };

    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [commands renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:_pipeline];
    [enc setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    [commands presentDrawable:drawable];
    [commands commit];

    _fps.tick(view.window, @"04 — Raymarched Scene");
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

@end

int main() {
    return RunMetalApp(@"04 — Raymarched Scene", 960, 640, ^(MTKView *view) {
        return (NSObject<MTKViewDelegate> *)[[RaymarchRenderer alloc] initWithView:view];
    });
}
