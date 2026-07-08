// 02 — Spinning Cube
//
// The real 3D pipeline: a vertex buffer, model/view/projection matrices built
// with simd, a depth buffer, back-face culling, and per-pixel directional
// lighting. This is the skeleton every 3D game renderer grows from.

#include "../common/app.h"
#include <simd/simd.h>
#include <vector>

static const char *kShaderSource = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    packed_float3 position;
    packed_float3 normal;
};

struct Uniforms {
    float4x4 mvp;
    float4x4 model;
};

struct VSOut {
    float4 position [[position]];
    float3 normal;
};

vertex VSOut vertex_main(uint vid [[vertex_id]],
                         const device VertexIn *vertices [[buffer(0)]],
                         constant Uniforms &u [[buffer(1)]]) {
    VertexIn v = vertices[vid];
    VSOut out;
    out.position = u.mvp * float4(float3(v.position), 1.0);
    out.normal = (u.model * float4(float3(v.normal), 0.0)).xyz;
    return out;
}

fragment float4 fragment_main(VSOut in [[stage_in]]) {
    float3 n = normalize(in.normal);
    float3 lightDir = normalize(float3(0.6, 1.0, 0.8));
    float diffuse = max(dot(n, lightDir), 0.0);
    float3 base = n * 0.5 + 0.5;          // color each face by its normal
    float3 color = base * (0.25 + 0.75 * diffuse);
    return float4(color, 1.0);
}
)METAL";

struct Vertex {
    float px, py, pz;
    float nx, ny, nz;
};

struct Uniforms {
    simd_float4x4 mvp;
    simd_float4x4 model;
};

// --- Matrix helpers (column-major, Metal clip space: depth 0..1) ---

static simd_float4x4 Perspective(float fovyRadians, float aspect, float nearZ, float farZ) {
    float ys = 1.0f / tanf(fovyRadians * 0.5f);
    float xs = ys / aspect;
    float zs = farZ / (nearZ - farZ);
    return simd_matrix(simd_make_float4(xs, 0, 0, 0),
                       simd_make_float4(0, ys, 0, 0),
                       simd_make_float4(0, 0, zs, -1),
                       simd_make_float4(0, 0, nearZ * zs, 0));
}

static simd_float4x4 RotationX(float a) {
    float c = cosf(a), s = sinf(a);
    return simd_matrix(simd_make_float4(1, 0, 0, 0),
                       simd_make_float4(0, c, s, 0),
                       simd_make_float4(0, -s, c, 0),
                       simd_make_float4(0, 0, 0, 1));
}

static simd_float4x4 RotationY(float a) {
    float c = cosf(a), s = sinf(a);
    return simd_matrix(simd_make_float4(c, 0, -s, 0),
                       simd_make_float4(0, 1, 0, 0),
                       simd_make_float4(s, 0, c, 0),
                       simd_make_float4(0, 0, 0, 1));
}

static simd_float4x4 Translation(float x, float y, float z) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[3] = simd_make_float4(x, y, z, 1);
    return m;
}

// Builds 36 vertices (6 faces x 2 triangles), counter-clockwise from outside.
static std::vector<Vertex> MakeCube() {
    struct Face { simd_float3 n, u, v; };
    const Face faces[6] = {
        { { 0,  0,  1}, { 1, 0,  0}, {0, 1,  0} },
        { { 0,  0, -1}, {-1, 0,  0}, {0, 1,  0} },
        { { 1,  0,  0}, { 0, 0, -1}, {0, 1,  0} },
        { {-1,  0,  0}, { 0, 0,  1}, {0, 1,  0} },
        { { 0,  1,  0}, { 1, 0,  0}, {0, 0, -1} },
        { { 0, -1,  0}, { 1, 0,  0}, {0, 0,  1} },
    };
    std::vector<Vertex> verts;
    verts.reserve(36);
    for (const Face &f : faces) {
        const simd_float3 corners[4] = {
            f.n - f.u - f.v, f.n + f.u - f.v,
            f.n + f.u + f.v, f.n - f.u + f.v,
        };
        const int indices[6] = {0, 1, 2, 0, 2, 3};
        for (int i : indices) {
            simd_float3 p = corners[i];
            verts.push_back({p.x, p.y, p.z, f.n.x, f.n.y, f.n.z});
        }
    }
    return verts;
}

@interface CubeRenderer : NSObject <MTKViewDelegate>
- (instancetype)initWithView:(MTKView *)view;
@end

@implementation CubeRenderer {
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLDepthStencilState> _depthState;
    id<MTLBuffer> _vertexBuffer;
    NSUInteger _vertexCount;
    double _startTime;
    FPSCounter _fps;
}

- (instancetype)initWithView:(MTKView *)view {
    if (!(self = [super init])) return nil;

    id<MTLDevice> device = view.device;
    _queue = [device newCommandQueue];
    view.clearColor = MTLClearColorMake(0.05, 0.05, 0.08, 1.0);
    view.depthStencilPixelFormat = MTLPixelFormatDepth32Float;

    id<MTLLibrary> library = CompileLibrary(device, kShaderSource);
    if (!library) return nil;

    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [library newFunctionWithName:@"vertex_main"];
    desc.fragmentFunction = [library newFunctionWithName:@"fragment_main"];
    desc.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    desc.depthAttachmentPixelFormat = view.depthStencilPixelFormat;

    NSError *error = nil;
    _pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!_pipeline) {
        fprintf(stderr, "Pipeline error: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }

    MTLDepthStencilDescriptor *depthDesc = [MTLDepthStencilDescriptor new];
    depthDesc.depthCompareFunction = MTLCompareFunctionLess;
    depthDesc.depthWriteEnabled = YES;
    _depthState = [device newDepthStencilStateWithDescriptor:depthDesc];

    std::vector<Vertex> cube = MakeCube();
    _vertexCount = cube.size();
    _vertexBuffer = [device newBufferWithBytes:cube.data()
                                        length:cube.size() * sizeof(Vertex)
                                       options:MTLResourceStorageModeShared];

    _startTime = CACurrentMediaTime();
    return self;
}

- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) return;

    float t = (float)(CACurrentMediaTime() - _startTime);
    float aspect = (float)(view.drawableSize.width / view.drawableSize.height);

    simd_float4x4 model = simd_mul(RotationY(t * 0.9f), RotationX(t * 0.6f));
    simd_float4x4 viewM = Translation(0, 0, -4.0f);
    simd_float4x4 proj = Perspective(60.0f * (float)M_PI / 180.0f, aspect, 0.1f, 100.0f);

    Uniforms uniforms = {
        .mvp = simd_mul(proj, simd_mul(viewM, model)),
        .model = model,
    };

    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [commands renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:_pipeline];
    [enc setDepthStencilState:_depthState];
    [enc setFrontFacingWinding:MTLWindingCounterClockwise];
    [enc setCullMode:MTLCullModeBack];
    [enc setVertexBuffer:_vertexBuffer offset:0 atIndex:0];
    [enc setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:_vertexCount];
    [enc endEncoding];
    [commands presentDrawable:drawable];
    [commands commit];

    _fps.tick(view.window, @"02 — Spinning Cube");
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

@end

int main() {
    return RunMetalApp(@"02 — Spinning Cube", 800, 600, ^(MTKView *view) {
        return (NSObject<MTKViewDelegate> *)[[CubeRenderer alloc] initWithView:view];
    });
}
