// 10 — GLIMMER
// A single focused organism: a translucent glass-membrane swimmer. Its bulbous,
// speckled, glossy body glows with internal sparkle; two big dark navy eyes sit
// up front; and four little webbed, veined fins PADDLE to push it along — the
// body lurches forward on each power stroke and glides between. A few of them
// drift around a dim underwater arena so the design and its motion can be
// reviewed up close. Everything is procedural SDF — no art.
//
// Build:  make build/10-critterstyles && ./build/10-critterstyles
// Keys:   Space pause   R send them somewhere new

#include "../common/app.h"
#include <simd/simd.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <random>
#include <vector>

static const float kWorldW = 64.0f, kWorldH = 40.0f;
static const int   kCount = 4;                 // how many swim in the arena
static const int   kMaxInstances = 8192;
static const int   kInFlight = 3;

struct InstC { float cx,cy,hx,hy,rot,shape, r,g,b,a, p0,p1,p2,p3; };

struct Critter {
    simd_float2 pos, vel;
    float heading, phase, size, seed, retarget;
    simd_float3 color;
    simd_float2 target;
};

static const char *kShaderSource = R"METAL(
#include <metal_stdlib>
using namespace metal;
struct Uni { float2 scale; float2 offset; float2 res; float time; float pad; };
float hash21(float2 p){ p=fract(p*float2(123.34,456.21)); p+=dot(p,p+45.32); return fract(p.x*p.y); }
float vnoise(float2 p){ float2 i=floor(p),f=fract(p); f=f*f*(3.0-2.0*f);
  return mix(mix(hash21(i),hash21(i+float2(1,0)),f.x), mix(hash21(i+float2(0,1)),hash21(i+float2(1,1)),f.x), f.y); }
float fbm(float2 p){ float v=0,a=0.5; for(int i=0;i<4;i++){v+=a*vnoise(p);p*=2.03;a*=0.5;} return v; }
float3 gammaOut(float3 c){ return pow(max(c,0.0), float3(0.4545)); }

struct FSOut { float4 position [[position]]; float2 uv; };
vertex FSOut fs_vertex(uint vid [[vertex_id]]){ float2 p=float2((vid<<1)&2, vid&2);
  FSOut o; o.position=float4(p*2.0-1.0,0,1); o.uv=float2(p.x,1.0-p.y); return o; }
fragment float4 ground_fragment(FSOut in [[stage_in]], constant Uni &u [[buffer(0)]]){
  float2 ndc=float2(in.uv.x*2.0-1.0, 1.0-in.uv.y*2.0);
  float2 w=(ndc-u.offset)/u.scale;
  float caust = fbm(w*0.12 + float2(u.time*0.05, u.time*0.03));
  caust = 0.6*caust + 0.4*fbm(w*0.28 - u.time*0.04);
  float3 col = mix(float3(0.03,0.07,0.10), float3(0.06,0.13,0.16), caust);
  col += 0.03*(fbm(w*0.7)-0.5);
  float2 d = min(w-float2(0.0), float2(64.0,40.0)-w);
  col *= 0.6 + 0.4*smoothstep(0.0, 8.0, min(d.x,d.y));   // soft edge vignette
  return float4(gammaOut(col),1.0);
}

struct EInst { packed_float2 c; packed_float2 h; float rot; float shape; packed_float4 col; packed_float4 params; };
struct EOut { float4 position [[position]]; float2 lp; float4 color; float4 params; float shape; };
constant float2 kCorners[6] = { float2(-1,-1),float2(1,-1),float2(1,1),float2(-1,-1),float2(1,1),float2(-1,1) };
vertex EOut entity_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device EInst *insts [[buffer(0)]], constant Uni &u [[buffer(1)]]){
  EInst it=insts[iid]; float2 lp=kCorners[vid]; float2 p=lp*float2(it.h);
  float cs=cos(it.rot), sn=sin(it.rot);
  float2 world=float2(it.c)+float2(p.x*cs-p.y*sn, p.x*sn+p.y*cs);
  EOut o; o.position=float4(world*u.scale+u.offset,0,1);
  o.lp=lp; o.color=float4(it.col); o.params=float4(it.params); o.shape=it.shape; return o;
}
fragment float4 entity_fragment(EOut in [[stage_in]]){
  float2 p=in.lp; int shape=int(in.shape+0.5); float a=0.0;
  if (shape==0){ a=smoothstep(1.0,0.1,length(p)); }                    // soft blob (shadow)
  else if (shape==1){                                                  // glossy dark eye
    float r=length(p), aa=fwidth(r);
    float m=smoothstep(0.95+aa,0.95-aa,r); if(m<0.01) discard_fragment();
    float3 col=float3(0.03,0.04,0.14)*(0.7+0.6*smoothstep(1.0,0.2,r));  // deep navy, rounded
    col=max(col, float3(0.85,0.9,1.0)*smoothstep(0.34,0.0,length(p-float2(-0.28,0.30)))); // glint
    return float4(gammaOut(col)*m, m); }
  else if (shape==3){                                                  // translucent body (x=seed,y=time)
    float seed=in.params.x, t=in.params.y;
    float r=length(p), ang=atan2(p.y,p.x), aa=fwidth(r);
    float edge=0.90*(1.0 - 0.09*cos(ang)) + 0.02*sin(ang*4.0+t*0.6);   // round, slightly tapered front
    float mask=smoothstep(edge+aa, edge-aa, r); if(mask<0.01) discard_fragment();
    float3 base=in.color.rgb;
    float A=0.50;                                                      // see-through membrane
    float3 col=base*(0.92+0.08*cos(ang*6.0))*(0.85+0.22*fbm(p*3.0+seed)); // faint ribs + tissue
    col*=0.88+0.32*smoothstep(0.25,edge,r);                           // thin rim brighter
    float2 gp=floor(p*15.0+seed*3.0);                                  // internal sparkle (glitter)
    float sp=fract(sin(dot(gp,float2(12.9898,78.233)))*43758.5453);
    float glit=smoothstep(0.90,0.99,sp);
    col+=glit*float3(1.0,1.0,0.85)*0.75; A=max(A,glit*0.9);
    float gloss=smoothstep(0.6,0.0,length(p-float2(-0.16,0.42)));      // top specular sheen
    col+=gloss*0.5; A=mix(A,0.8,gloss*0.55);
    float rim=smoothstep(edge-0.13,edge-0.005,r);                      // bright membrane edge
    col=mix(col, base*1.6+0.18, rim*0.55); A=mix(A,0.72,rim);
    A*=mask; return float4(gammaOut(col)*A, A); }
  else if (shape==6){                                                  // translucent webbed fin (x=seed)
    float up=clamp(p.y*0.5+0.5, 0.0, 1.0);                             // 0 base .. 1 tip
    float halfw=0.12 + 0.9*up*(1.0-0.28*up);                           // widen, round the tip
    float aa=fwidth(p.x)+0.01;
    float side=smoothstep(halfw+aa, halfw-aa, abs(p.x));
    float vert=smoothstep(-1.0,-0.92,p.y)*(1.0-smoothstep(0.9,1.0,up));
    float mask=side*vert; if(mask<0.01) discard_fragment();
    float vx=p.x/max(halfw,0.01);                                      // -1..1 across fin
    float vein=smoothstep(0.12,0.0, abs(fract(vx*2.5+0.5)-0.5));       // ~5 radiating rays
    float3 col=in.color.rgb*(0.75+0.55*up);
    col=mix(col, in.color.rgb*1.7+0.18, vein*0.55*up);                 // glowing vein tips
    float A=(0.30+0.30*up)*mask;                                       // sheer at base, fuller at tip
    return float4(gammaOut(col)*A, A); }
  return float4(gammaOut(in.color.rgb)*a*in.color.a, a*in.color.a);
}
)METAL";

@interface GlimmerRenderer : NSObject <MTKViewDelegate> @end

@implementation GlimmerRenderer {
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _ground, _entity;
    id<MTLBuffer> _buffers[kInFlight];
    int _frameIndex;
    dispatch_semaphore_t _sem;
    std::vector<InstC> _scratch;
    std::vector<Critter> _crits;
    std::mt19937 _rng;
    simd_float2 _uScale, _uOffset;
    double _startTime, _lastFrame;
    float _fps, _time; bool _paused;
}

- (instancetype)initWithView:(MTKView *)view {
    if (!(self = [super init])) return nil;
    id<MTLDevice> dev = view.device;
    _queue = [dev newCommandQueue];
    id<MTLLibrary> lib = CompileLibrary(dev, kShaderSource);
    if (!lib) return nil;
    NSError *err = nil;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    d.vertexFunction = [lib newFunctionWithName:@"fs_vertex"];
    d.fragmentFunction = [lib newFunctionWithName:@"ground_fragment"];
    _ground = [dev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!_ground){ fprintf(stderr,"ground: %s\n", err.localizedDescription.UTF8String); return nil; }
    d.colorAttachments[0].blendingEnabled = YES;
    d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    d.vertexFunction = [lib newFunctionWithName:@"entity_vertex"];
    d.fragmentFunction = [lib newFunctionWithName:@"entity_fragment"];
    _entity = [dev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!_entity){ fprintf(stderr,"entity: %s\n", err.localizedDescription.UTF8String); return nil; }

    for (int i=0;i<kInFlight;i++)
        _buffers[i] = [dev newBufferWithLength:kMaxInstances*sizeof(InstC) options:MTLResourceStorageModeShared];
    _sem = dispatch_semaphore_create(kInFlight);
    _scratch.reserve(kMaxInstances);
    _rng.seed(0x61A55);
    std::uniform_real_distribution<float> u(0,1);
    for (int i=0;i<kCount;i++){
        Critter c = {};
        c.pos = simd_make_float2(8+u(_rng)*(kWorldW-16), 6+u(_rng)*(kWorldH-12));
        c.vel = simd_make_float2(0,0);
        c.heading = u(_rng)*6.28f;
        c.phase = u(_rng)*6.28f;
        c.size = 2.1f + u(_rng)*0.6f;
        c.seed = u(_rng)*10.0f;
        // teal / aqua family, slight variation
        c.color = simd_make_float3(0.30f+0.12f*u(_rng), 0.66f+0.14f*u(_rng), 0.64f+0.12f*u(_rng));
        c.target = c.pos; c.retarget = 0;
        _crits.push_back(c);
    }

    __unsafe_unretained GlimmerRenderer *weak = self;
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent*(NSEvent*e){
        if (e.modifierFlags & NSEventModifierFlagCommand) return e;
        if (e.keyCode==49){ weak->_paused=!weak->_paused; return nil; }        // space
        if (e.keyCode==15){ for (auto&c:weak->_crits) c.retarget=0; return nil; } // R
        return e;
    }];
    printf("10 — GLIMMER — a translucent fin-paddling swimmer. Space pause, R redirect.\n");
    _startTime = CACurrentMediaTime(); _lastFrame = _startTime; _fps = 60; _paused = NO;
    return self;
}

- (void)push:(simd_float2)c half:(simd_float2)h rot:(float)rot shape:(float)s
       color:(simd_float4)col p0:(float)p0 p1:(float)p1 {
    if ((int)_scratch.size() >= kMaxInstances) return;
    _scratch.push_back({c.x,c.y,h.x,h.y,rot,s, col.x,col.y,col.z,col.w, p0,p1,0,0});
}

// A veined fin fanning out from `base` in direction `ang`.
- (void)fin:(simd_float2)base ang:(float)ang len:(float)l width:(float)w
      color:(simd_float4)col seed:(float)seed {
    simd_float2 dir = simd_make_float2(cosf(ang), sinf(ang));
    [self push:base + dir*(l*0.5f) half:simd_make_float2(w, l*0.5f)
           rot:ang - 1.57080f shape:6 color:col p0:seed p1:0];
}

- (void)updateCritter:(Critter&)c dt:(float)dt {
    std::uniform_real_distribution<float> u(0,1);
    c.retarget -= dt;
    if (c.retarget <= 0 || simd_distance(c.pos, c.target) < 4.0f) {
        c.target = simd_make_float2(6+u(_rng)*(kWorldW-12), 5+u(_rng)*(kWorldH-10));
        c.retarget = 2.5f + u(_rng)*3.5f;
    }
    // turn toward the target
    simd_float2 to = c.target - c.pos;
    float desired = atan2f(to.y, to.x);
    float dh = desired - c.heading;
    while (dh >  3.14159f) dh -= 6.28318f;
    while (dh < -3.14159f) dh += 6.28318f;
    c.heading += std::clamp(dh, -1.8f*dt, 1.8f*dt);
    // paddle propulsion: thrust pulses on each fin power stroke, glide between
    c.phase += dt * 4.2f;
    float thrust = std::max(0.0f, sinf(c.phase));
    simd_float2 fwd = simd_make_float2(cosf(c.heading), sinf(c.heading));
    c.vel += fwd * (thrust * thrust) * 14.0f * dt;
    c.vel -= c.vel * std::min(1.7f*dt, 1.0f);                 // water drag → glides to rest
    c.pos += c.vel * dt;
    c.pos.x = std::clamp(c.pos.x, 3.0f, kWorldW-3.0f);
    c.pos.y = std::clamp(c.pos.y, 3.0f, kWorldH-3.0f);
}

- (void)renderCritter:(const Critter&)c {
    float S = c.size;
    simd_float2 fwd = simd_make_float2(cosf(c.heading), sinf(c.heading));
    simd_float2 perp = simd_make_float2(-fwd.y, fwd.x);
    float sweep = 0.45f * sinf(c.phase);                       // fin stroke
    simd_float4 finCol = simd_make_float4(c.color*1.05f + simd_make_float3(0.04f,0.06f,0.05f), 1.0f);

    // four webbed fins (drawn first; the body overlaps their roots)
    // rear pair — the main paddles
    [self fin:c.pos - fwd*0.35f*S + perp*0.60f*S ang:c.heading + 2.15f + sweep
           len:1.25f*S width:0.42f*S color:finCol seed:c.seed];
    [self fin:c.pos - fwd*0.35f*S - perp*0.60f*S ang:c.heading - 2.15f - sweep
           len:1.25f*S width:0.42f*S color:finCol seed:c.seed+3.0f];
    // front pair — smaller
    [self fin:c.pos + fwd*0.30f*S + perp*0.55f*S ang:c.heading + 1.05f + sweep*0.7f
           len:0.95f*S width:0.34f*S color:finCol seed:c.seed+6.0f];
    [self fin:c.pos + fwd*0.30f*S - perp*0.55f*S ang:c.heading - 1.05f - sweep*0.7f
           len:0.95f*S width:0.34f*S color:finCol seed:c.seed+9.0f];

    // translucent membrane body (round, slightly tapered toward the face)
    [self push:c.pos half:simd_make_float2(S*1.05f, S*1.02f) rot:c.heading shape:3
          color:simd_make_float4(c.color,1.0f) p0:c.seed p1:_time];
    // small snout bump at the front
    [self push:c.pos + fwd*0.72f*S half:simd_make_float2(S*0.42f, S*0.36f) rot:c.heading shape:3
          color:simd_make_float4(c.color*1.02f,1.0f) p0:c.seed+2.0f p1:_time];
    // two big dark navy eyes up front
    float er = S*0.30f;
    [self push:c.pos + fwd*0.60f*S + perp*0.40f*S half:simd_make_float2(er,er) rot:0 shape:1
          color:simd_make_float4(1,1,1,1) p0:0 p1:0];
    [self push:c.pos + fwd*0.60f*S - perp*0.40f*S half:simd_make_float2(er,er) rot:0 shape:1
          color:simd_make_float4(1,1,1,1) p0:0 p1:0];
}

- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) return;
    double now = CACurrentMediaTime();
    float dt = (float)(now - _lastFrame); _lastFrame = now;
    _time = (float)(now - _startTime);
    if (dt > 0) _fps += (1.0f/dt - _fps)*0.05f;
    if (!_paused) { float sd = std::min(dt, 0.05f); for (auto&c:_crits) [self updateCritter:c dt:sd]; }

    float aspect = (float)(view.drawableSize.width / view.drawableSize.height);
    float s = std::min(2.0f*aspect/kWorldW, 2.0f/kWorldH) * 0.96f;
    _uScale = simd_make_float2(s/aspect, s);
    _uOffset = simd_make_float2(-kWorldW*0.5f*s/aspect, -kWorldH*0.5f*s);
    struct { simd_float2 scale,offset,res; float time,pad; } uni = {
        _uScale,_uOffset, simd_make_float2((float)view.drawableSize.width,(float)view.drawableSize.height),
        _time, 0 };

    dispatch_semaphore_wait(_sem, DISPATCH_TIME_FOREVER);
    _scratch.clear();
    for (const Critter &c : _crits)                                   // soft shadows first
        [self push:c.pos + simd_make_float2(0.3f,-0.3f) half:simd_make_float2(c.size*1.1f,c.size*0.95f)
               rot:0 shape:0 color:simd_make_float4(0,0,0,0.20f) p0:0 p1:0];
    for (const Critter &c : _crits) [self renderCritter:c];
    id<MTLBuffer> ib = _buffers[_frameIndex];
    NSUInteger ic = _scratch.size();
    if (ic) memcpy([ib contents], _scratch.data(), ic*sizeof(InstC));

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:_ground];
    [enc setFragmentBytes:&uni length:sizeof(uni) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    if (ic) {
        [enc setRenderPipelineState:_entity];
        [enc setVertexBuffer:ib offset:0 atIndex:0];
        [enc setVertexBytes:&uni length:sizeof(uni) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:ic];
    }
    [enc endEncoding];
    dispatch_semaphore_t sem = _sem;
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> cb){ (void)cb; dispatch_semaphore_signal(sem); }];
    [cmd presentDrawable:drawable];
    [cmd commit];
    _frameIndex = (_frameIndex + 1) % kInFlight;
    view.window.title = [NSString stringWithFormat:@"10 — GLIMMER ▸ translucent fin-swimmer%s ▸ %.0f fps",
                         _paused?" ▸ PAUSED":"", _fps];
}
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}
@end

int main() {
    return RunMetalApp(@"10 — GLIMMER", 1280, 800, ^(MTKView *view){
        return (NSObject<MTKViewDelegate> *)[[GlimmerRenderer alloc] initWithView:view];
    });
}
