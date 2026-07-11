// 11 — RAIN DEMO
//
// Six different TOP-DOWN rain treatments shown side by side over the same patch
// of wet ground, so you can compare and pick one. From directly above, rain
// doesn't read as diagonal streaks — it reads as impacts: expanding rings,
// splash crowns, a wet sheen. Each tile is numbered; press 1-6 to blow one up
// fullscreen, 0 (or G) to return to the grid, Space to cycle.
//
//   1 RIPPLE RINGS   2 SPLASH DOTS   3 STREAKS (top-down, the "wrong" look)
//   4 WET SHEEN      5 RINGS+DROPS   6 DOWNPOUR

#include "../common/app.h"
#include <simd/simd.h>

static const char *kShaderSource = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct Uniforms { float2 resolution; float time; float mode; };

struct VSOut { float4 position [[position]]; };
vertex VSOut vertex_main(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VSOut o; o.position = float4(p * 2.0 - 1.0, 0.0, 1.0); return o;
}

float h21(float2 p){ p = fract(p*float2(127.1,311.7)); p += dot(p, p+34.5); return fract(p.x*p.y); }
float2 h22(float2 p){ return float2(h21(p), h21(p+19.19)); }
float vnoise(float2 p){
    float2 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
    return mix(mix(h21(i),h21(i+float2(1,0)),f.x),
               mix(h21(i+float2(0,1)),h21(i+float2(1,1)),f.x), f.y);
}
float fbm(float2 p){ float v=0.0,a=0.5; for(int i=0;i<4;i++){ v+=a*vnoise(p); p*=2.0; a*=0.5; } return v; }

// Shared wet ground: mossy green with a shallow puddle so ripples have somewhere
// to read. Identical in every tile for a fair comparison.
float3 ground(float2 uv){
    float n = fbm(uv*6.0 + 3.0);
    float3 g = mix(float3(0.11,0.20,0.09), float3(0.19,0.31,0.13), n);
    g *= 0.9 + 0.2*fbm(uv*20.0);                          // fine mottle
    float pud = smoothstep(0.22,0.14, length(uv-float2(0.5,0.55)));
    g = mix(g, float3(0.08,0.12,0.15), pud*0.75);          // dark puddle
    return g;
}

// ---- effects: each takes the ground colour, the tile-local uv (0..1) and time ----

float3 fx_rings(float3 base, float2 uv, float t){
    base *= 0.72;                                          // wet darken
    float scale=8.0; float2 gv=uv*scale; float2 id=floor(gv); float b=0.0;
    for(int dy=-1;dy<=1;dy++) for(int dx=-1;dx<=1;dx++){
        float2 cell=id+float2(dx,dy);
        float2 c=cell+0.25+0.5*h22(cell);
        float ph=h21(cell+3.1); float age=fract(t/1.3+ph);
        float rad=age*0.85; float d=length(gv-c);
        b += smoothstep(0.055,0.0,abs(d-rad))*(1.0-age);
    }
    return base + b*float3(0.5,0.6,0.72);
}

float3 fx_splash(float3 base, float2 uv, float t){
    base *= 0.70;
    float scale=11.0; float2 gv=uv*scale; float2 id=floor(gv); float b=0.0;
    for(int dy=-1;dy<=1;dy++) for(int dx=-1;dx<=1;dx++){
        float2 cell=id+float2(dx,dy);
        float2 c=cell+0.25+0.5*h22(cell);
        float ph=h21(cell+7.7); float age=fract(t*1.6+ph);
        float d=length(gv-c);
        float dot=smoothstep(0.13,0.0,d)*smoothstep(0.16,0.0,age);        // brief bright hit
        float crown=smoothstep(0.045,0.0,abs(d-0.19))
                    *smoothstep(0.05,0.16,age)*smoothstep(0.4,0.18,age);  // tiny splash ring
        b += dot*1.3 + crown*0.7;
    }
    return base + b*float3(0.62,0.72,0.85);
}

float3 fx_streaks(float3 base, float2 uv, float t){       // the diagonal-streak look, top-down
    base *= 0.75;
    float2 sp=uv; sp.x += sp.y*0.14;
    float cols=90.0; float c=floor(sp.x*cols); float rnd=h21(float2(c,1.0));
    float drop=fract(sp.y*10.0 + t*(1.0+rnd*0.7) + rnd*7.0);
    base += smoothstep(0.82,1.0,drop)*0.38*float3(0.72,0.80,0.92);
    return base;
}

float3 fx_sheen(float3 base, float2 uv, float t){
    base *= 0.66;
    float film=fbm(uv*8.0 + float2(t*0.25, t*0.6));
    base += smoothstep(0.58,0.86,film)*0.26*float3(0.70,0.80,0.96);       // drifting wet shimmer
    float r=sin(length(uv-0.5)*38.0 - t*3.0)*0.5+0.5;                     // slow broad swell
    base += r*0.035;
    return base;
}

float3 fx_combo(float3 base, float2 uv, float t){         // impact flash then expanding ring
    base *= 0.70;
    float scale=8.0; float2 gv=uv*scale; float2 id=floor(gv); float b=0.0;
    for(int dy=-1;dy<=1;dy++) for(int dx=-1;dx<=1;dx++){
        float2 cell=id+float2(dx,dy);
        float2 c=cell+0.25+0.5*h22(cell);
        float ph=h21(cell+1.9); float age=fract(t/1.25+ph);
        float d=length(gv-c);
        float flash=smoothstep(0.09,0.0,d)*smoothstep(0.12,0.0,age);      // the drop landing
        float rad=age*0.8;
        float ring=smoothstep(0.05,0.0,abs(d-rad))*(1.0-age)*step(0.05,age);
        b += flash*1.4 + ring;
    }
    return base + b*float3(0.56,0.66,0.80);
}

float3 fx_downpour(float3 base, float2 uv, float t){
    base *= 0.55;                                          // heavy grey-out
    float sheet=fbm(float2(uv.x*3.0, uv.y*3.0 - t*2.5));
    base += smoothstep(0.55,0.82,sheet)*0.12;              // moving sheets
    float scale=16.0; float2 gv=uv*scale; float2 id=floor(gv); float b=0.0;
    for(int dy=-1;dy<=1;dy++) for(int dx=-1;dx<=1;dx++){
        float2 cell=id+float2(dx,dy);
        float2 c=cell+0.25+0.5*h22(cell);
        float ph=h21(cell+5.3); float age=fract(t*2.3+ph);
        b += smoothstep(0.12,0.0,length(gv-c))*smoothstep(0.2,0.0,age);   // dense stipple hits
    }
    base += b*0.5*float3(0.60,0.70,0.86);
    float2 sp=uv; float drop=fract(sp.y*18.0 + t*3.2 + h21(float2(floor(sp.x*140.0),1.0))*5.0);
    base += smoothstep(0.9,1.0,drop)*0.16;                 // faint fast fall
    return base;
}

float3 applyEffect(int eff, float2 uv, float t){
    float3 g = ground(uv);
    if (eff==0) return fx_rings(g,uv,t);
    if (eff==1) return fx_splash(g,uv,t);
    if (eff==2) return fx_streaks(g,uv,t);
    if (eff==3) return fx_sheen(g,uv,t);
    if (eff==4) return fx_combo(g,uv,t);
    return fx_downpour(g,uv,t);
}

fragment float4 fragment_main(VSOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]){
    float2 uv = in.position.xy / u.resolution;            // 0..1, y=0 at top
    int mode = int(u.mode + 0.5);
    float3 col;
    if (mode == 0) {
        // 3 x 2 grid of the six effects.
        float2 g = uv * float2(3.0, 2.0);
        int col_i = int(floor(g.x)), row_i = int(floor(g.y));
        int eff = row_i*3 + col_i;
        float2 luv = fract(g);
        col = applyEffect(eff, luv, u.time);
        // numbered pips (eff+1 of them) in the top-left of each tile
        for (int i=0;i<6;i++) if (i<=eff) {
            float2 pc = float2(0.035 + float(i)*0.032, 0.055);
            if (all(abs(luv-pc) < 0.012)) col = float3(1.0);
        }
        // tile border
        float2 b = min(luv, 1.0-luv);
        col = mix(float3(0.0), col, smoothstep(0.0,0.006, min(b.x,b.y)));
    } else {
        col = applyEffect(mode-1, uv, u.time);
    }
    col = pow(max(col,0.0), float3(0.4545));               // gamma
    return float4(col, 1.0);
}
)METAL";

struct Uniforms { simd_float2 resolution; float time; float mode; };

@interface RainRenderer : NSObject <MTKViewDelegate>
- (instancetype)initWithView:(MTKView *)view;
@end

@implementation RainRenderer {
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    double _startTime;
    int _mode;              // 0 = grid, 1..6 = one effect fullscreen
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
    if (!_pipeline) { fprintf(stderr, "Pipeline: %s\n", error.localizedDescription.UTF8String); return nil; }

    _startTime = CACurrentMediaTime();
    _mode = 0;

    __unsafe_unretained RainRenderer *weak = self;
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent*(NSEvent *e){
        if (e.modifierFlags & NSEventModifierFlagCommand) return e;
        NSString *c = e.charactersIgnoringModifiers;
        if (c.length) {
            unichar ch = [c characterAtIndex:0];
            if (ch >= '1' && ch <= '6') { weak->_mode = ch - '0'; return nil; }
            if (ch == '0' || ch == 'g' || ch == 'G') { weak->_mode = 0; return nil; }
            if (ch == ' ') { weak->_mode = (weak->_mode + 1) % 7; return nil; }
        }
        return e;
    }];

    printf("11 — RAIN DEMO. Top-down rain treatments — pick your favourite.\n"
           "  1 RIPPLE RINGS    2 SPLASH DOTS    3 STREAKS (top-down, the 'wrong' look)\n"
           "  4 WET SHEEN       5 RINGS+DROPS    6 DOWNPOUR\n"
           "Keys: 1-6 fullscreen an effect, 0/G grid, Space cycles.\n");
    return self;
}

- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) return;
    Uniforms uniforms = {
        .resolution = simd_make_float2((float)view.drawableSize.width, (float)view.drawableSize.height),
        .time = (float)(CACurrentMediaTime() - _startTime),
        .mode = (float)_mode,
    };
    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [commands renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:_pipeline];
    [enc setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    [commands presentDrawable:drawable];
    [commands commit];

    static const char *names[7] = {"grid","RIPPLE RINGS","SPLASH DOTS","STREAKS",
                                   "WET SHEEN","RINGS+DROPS","DOWNPOUR"};
    _fps.tick(view.window, [NSString stringWithFormat:@"11 — RAIN DEMO ▸ %s (1-6/0/space)", names[_mode]]);
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}
@end

int main() {
    return RunMetalApp(@"11 — RAIN DEMO", 1200, 800, ^(MTKView *view) {
        return (NSObject<MTKViewDelegate> *)[[RainRenderer alloc] initWithView:view];
    });
}
