// 01 — Hello Triangle
//
// The minimal Metal pipeline: one draw call, three vertices generated in the
// vertex shader (no vertex buffer at all), interpolated colors, animated with
// a time uniform passed via setVertexBytes.

#include "../common/app.h"

static const char *kShaderSource = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float time;
    float aspect;
};

struct VSOut {
    float4 position [[position]];
    float3 color;
};

vertex VSOut vertex_main(uint vid [[vertex_id]],
                         constant Uniforms &u [[buffer(0)]]) {
    // Three points of an equilateral triangle, rotating over time.
    float angle = u.time + float(vid) * (2.0 * M_PI_F / 3.0);
    float2 p = float2(cos(angle), sin(angle)) * 0.8;
    p.x /= u.aspect;

    // Breathe a little so it feels alive.
    p *= 0.85 + 0.15 * sin(u.time * 2.0);

    VSOut out;
    out.position = float4(p, 0.0, 1.0);
    const float3 colors[3] = {
        float3(1.00, 0.20, 0.30),
        float3(0.20, 1.00, 0.40),
        float3(0.25, 0.40, 1.00),
    };
    out.color = colors[vid % 3];
    return out;
}

fragment float4 fragment_main(VSOut in [[stage_in]]) {
    return float4(in.color, 1.0);
}
)METAL";

struct Uniforms {
    float time;
    float aspect;
};

@interface TriangleRenderer : NSObject <MTKViewDelegate>
- (instancetype)initWithView:(MTKView *)view;
@end

@implementation TriangleRenderer {
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    double _startTime;
    FPSCounter _fps;
}

- (instancetype)initWithView:(MTKView *)view {
    if (!(self = [super init])) return nil;

    id<MTLDevice> device = view.device;
    _queue = [device newCommandQueue];
    view.clearColor = MTLClearColorMake(0.05, 0.05, 0.08, 1.0);

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
        .time = (float)(CACurrentMediaTime() - _startTime),
        .aspect = (float)(view.drawableSize.width / view.drawableSize.height),
    };

    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [commands renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:_pipeline];
    [enc setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    [commands presentDrawable:drawable];
    [commands commit];

    _fps.tick(view.window, @"01 — Hello Triangle");
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

@end

int main() {
    return RunMetalApp(@"01 — Hello Triangle", 800, 600, ^(MTKView *view) {
        return (NSObject<MTKViewDelegate> *)[[TriangleRenderer alloc] initWithView:view];
    });
}
