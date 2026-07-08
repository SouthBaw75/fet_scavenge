// 03 — One Million GPU Particles
//
// This is where Metal on Apple Silicon shows off. A compute shader integrates
// physics for 1,000,000 particles every frame, entirely on the GPU; the render
// pass then draws them as additively-blended points. The CPU does almost
// nothing. Move your mouse over the window — the particles chase it. When the
// cursor leaves, the attractor wanders on its own.

#include "../common/app.h"
#include <simd/simd.h>
#include <random>
#include <vector>
#include <algorithm>

static const uint32_t kParticleCount = 1000000;

static const char *kShaderSource = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct Particle {
    float2 pos;
    float2 vel;
};

struct SimParams {
    float2 attractor;
    float  dt;
    uint   count;
    float  aspect;
};

kernel void simulate(device Particle *particles [[buffer(0)]],
                     constant SimParams &p [[buffer(1)]],
                     uint id [[thread_position_in_grid]]) {
    if (id >= p.count) return;
    Particle part = particles[id];

    float2 d = p.attractor - part.pos;
    float dist = max(length(d), 0.05);
    float2 accel = (d / dist) * (1.5 / dist);   // inverse-distance gravity

    part.vel = (part.vel + accel * p.dt) * 0.998; // slight damping
    float speed = length(part.vel);
    if (speed > 3.0) part.vel *= 3.0 / speed;

    part.pos += part.vel * p.dt;
    particles[id] = part;
}

struct VSOut {
    float4 position [[position]];
    float  pointSize [[point_size]];
    half4  color;
};

vertex VSOut vertex_main(uint vid [[vertex_id]],
                         const device Particle *particles [[buffer(0)]],
                         constant SimParams &p [[buffer(1)]]) {
    Particle part = particles[vid];
    VSOut out;
    out.position = float4(part.pos.x / p.aspect, part.pos.y, 0.0, 1.0);
    out.pointSize = 2.0;

    // Slow particles glow deep blue, fast ones run hot orange.
    float t = saturate(length(part.vel) / 2.5);
    float3 c = mix(float3(0.10, 0.25, 1.00), float3(1.00, 0.55, 0.15), t);
    out.color = half4(half3(c) * 0.30h, 0.30h); // premultiplied, faint: they add up
    return out;
}

fragment half4 fragment_main(VSOut in [[stage_in]]) {
    return in.color;
}
)METAL";

struct Particle {
    simd_float2 pos;
    simd_float2 vel;
};

struct SimParams {
    simd_float2 attractor;
    float dt;
    uint32_t count;
    float aspect;
};

@interface ParticleRenderer : NSObject <MTKViewDelegate>
- (instancetype)initWithView:(MTKView *)view;
@end

@implementation ParticleRenderer {
    id<MTLCommandQueue> _queue;
    id<MTLComputePipelineState> _simulatePipeline;
    id<MTLRenderPipelineState> _renderPipeline;
    id<MTLBuffer> _particleBuffer;
    double _startTime;
    double _lastFrameTime;
    FPSCounter _fps;
}

- (instancetype)initWithView:(MTKView *)view {
    if (!(self = [super init])) return nil;

    id<MTLDevice> device = view.device;
    _queue = [device newCommandQueue];
    view.clearColor = MTLClearColorMake(0.0, 0.0, 0.02, 1.0);

    id<MTLLibrary> library = CompileLibrary(device, kShaderSource);
    if (!library) return nil;

    NSError *error = nil;
    _simulatePipeline =
        [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"simulate"]
                                              error:&error];
    if (!_simulatePipeline) {
        fprintf(stderr, "Compute pipeline error: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }

    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [library newFunctionWithName:@"vertex_main"];
    desc.fragmentFunction = [library newFunctionWithName:@"fragment_main"];
    desc.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    // Additive blending so overlapping particles build up into glow.
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;

    _renderPipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!_renderPipeline) {
        fprintf(stderr, "Render pipeline error: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }

    // Seed particles in a disc with tangential velocity so they start orbiting.
    // Unified memory on Apple Silicon: the GPU reads this buffer directly.
    std::vector<Particle> particles(kParticleCount);
    std::mt19937 rng(42);
    std::uniform_real_distribution<float> uniform(0.0f, 1.0f);
    for (Particle &p : particles) {
        float radius = 0.15f + 0.75f * sqrtf(uniform(rng));
        float angle = uniform(rng) * 2.0f * (float)M_PI;
        p.pos = { radius * cosf(angle), radius * sinf(angle) };
        float orbit = 0.9f / sqrtf(radius);
        p.vel = { -sinf(angle) * orbit, cosf(angle) * orbit };
    }
    _particleBuffer = [device newBufferWithBytes:particles.data()
                                          length:particles.size() * sizeof(Particle)
                                         options:MTLResourceStorageModeShared];

    _startTime = CACurrentMediaTime();
    _lastFrameTime = _startTime;
    return self;
}

- (simd_float2)attractorForView:(MTKView *)view time:(float)t aspect:(float)aspect {
    NSPoint mouse = [view.window mouseLocationOutsideOfEventStream];
    NSPoint local = [view convertPoint:mouse fromView:nil];
    if (NSPointInRect(local, view.bounds)) {
        NSSize size = view.bounds.size;
        return simd_make_float2(
            (float)(local.x / size.width * 2.0 - 1.0) * aspect,
            (float)(local.y / size.height * 2.0 - 1.0));
    }
    // No mouse? Wander in a Lissajous curve.
    return simd_make_float2(aspect * 0.55f * cosf(t * 0.7f), 0.55f * sinf(t * 1.1f));
}

- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) return;

    double now = CACurrentMediaTime();
    float t = (float)(now - _startTime);
    float dt = std::min((float)(now - _lastFrameTime), 1.0f / 30.0f);
    _lastFrameTime = now;
    float aspect = (float)(view.drawableSize.width / view.drawableSize.height);

    SimParams params = {
        .attractor = [self attractorForView:view time:t aspect:aspect],
        .dt = dt,
        .count = kParticleCount,
        .aspect = aspect,
    };

    id<MTLCommandBuffer> commands = [_queue commandBuffer];

    id<MTLComputeCommandEncoder> sim = [commands computeCommandEncoder];
    [sim setComputePipelineState:_simulatePipeline];
    [sim setBuffer:_particleBuffer offset:0 atIndex:0];
    [sim setBytes:&params length:sizeof(params) atIndex:1];
    [sim dispatchThreads:MTLSizeMake(kParticleCount, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
    [sim endEncoding];

    id<MTLRenderCommandEncoder> enc = [commands renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:_renderPipeline];
    [enc setVertexBuffer:_particleBuffer offset:0 atIndex:0];
    [enc setVertexBytes:&params length:sizeof(params) atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:kParticleCount];
    [enc endEncoding];

    [commands presentDrawable:drawable];
    [commands commit];

    _fps.tick(view.window, @"03 — 1,000,000 GPU Particles (move the mouse)");
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

@end

int main() {
    return RunMetalApp(@"03 — 1,000,000 GPU Particles (move the mouse)", 1024, 768, ^(MTKView *view) {
        return (NSObject<MTKViewDelegate> *)[[ParticleRenderer alloc] initWithView:view];
    });
}
