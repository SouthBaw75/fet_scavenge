// 10 — CRITTER STYLES
// A movement-style gallery: six procedurally-animated organism designs, each
// wandering in its own labeled cell so you can compare how they LOCOMOTE —
// serpent (slither), fish (swim), walker (hexapod gait), crawler (peristalsis),
// jelly (pulse-jet), hopper (ballistic hops). A design-review sandbox to pick a
// new body plan for the biome critters. Everything is procedural SDF blobs.
//
// Build:  make build/10-critterstyles && ./build/10-critterstyles
// Keys:   Space pause   R reroll wander targets

#include "../common/app.h"
#include <simd/simd.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <random>
#include <vector>

static const float kWorldW = 96.0f, kWorldH = 54.0f;
static const int   kCols = 4, kRows = 3;
static const float kCellW = kWorldW / kCols;   // 24
static const float kCellH = kWorldH / kRows;   // 18
static const int   kMaxInstances = 12288;
static const int   kInFlight = 3;
static const int   kNumStyles = 10;

enum { ST_SERPENT, ST_FISH, ST_WALKER, ST_CRAWLER, ST_JELLY,
       ST_HOPPER, ST_FATWORM, ST_AMOEBA, ST_CELL, ST_MOUSE };
static const char *kStyleName[10] = { "SERPENT","FISH","WALKER","CRAWLER","JELLY",
                                      "HOPPER","FAT WORM","AMOEBA","CELL","MOUSE" };

struct InstC { float cx,cy,hx,hy,rot,shape, r,g,b,a, p0,p1,p2,p3; };

struct Creature {
    int style, nspine;
    simd_float2 pos, vel;
    float heading, phase, speed, size, hopT, retarget;
    simd_float3 color;
    simd_float2 spine[10];
    simd_float2 target, cmin, cmax;
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
  float cx=floor(w.x/24.0), cy=floor(w.y/18.0);
  float checker=fmod(cx+cy,2.0);
  float3 col=mix(float3(0.09,0.13,0.08), float3(0.12,0.17,0.10), checker);
  col*=0.82+0.34*fbm(w*0.5);
  col+=0.03*(fbm(w*2.0+3.0)-0.5);
  return float4(gammaOut(col),1.0);
}

constant ushort kFont[26][7] = {
  {0x0E,0x11,0x11,0x1F,0x11,0x11,0x11},{0x1E,0x11,0x11,0x1E,0x11,0x11,0x1E},
  {0x0E,0x11,0x10,0x10,0x10,0x11,0x0E},{0x1E,0x11,0x11,0x11,0x11,0x11,0x1E},
  {0x1F,0x10,0x10,0x1E,0x10,0x10,0x1F},{0x1F,0x10,0x10,0x1E,0x10,0x10,0x10},
  {0x0E,0x11,0x10,0x17,0x11,0x11,0x0F},{0x11,0x11,0x11,0x1F,0x11,0x11,0x11},
  {0x0E,0x04,0x04,0x04,0x04,0x04,0x0E},{0x07,0x02,0x02,0x02,0x02,0x12,0x0C},
  {0x11,0x12,0x14,0x18,0x14,0x12,0x11},{0x10,0x10,0x10,0x10,0x10,0x10,0x1F},
  {0x11,0x1B,0x15,0x15,0x11,0x11,0x11},{0x11,0x11,0x19,0x15,0x13,0x11,0x11},
  {0x0E,0x11,0x11,0x11,0x11,0x11,0x0E},{0x1E,0x11,0x11,0x1E,0x10,0x10,0x10},
  {0x0E,0x11,0x11,0x11,0x15,0x12,0x0D},{0x1E,0x11,0x11,0x1E,0x14,0x12,0x11},
  {0x0F,0x10,0x10,0x0E,0x01,0x01,0x1E},{0x1F,0x04,0x04,0x04,0x04,0x04,0x04},
  {0x11,0x11,0x11,0x11,0x11,0x11,0x0E},{0x11,0x11,0x11,0x11,0x11,0x0A,0x04},
  {0x11,0x11,0x11,0x15,0x15,0x1B,0x11},{0x11,0x11,0x0A,0x04,0x0A,0x11,0x11},
  {0x11,0x11,0x0A,0x04,0x04,0x04,0x04},{0x1F,0x01,0x02,0x04,0x08,0x10,0x1F},
};

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
  if (shape==0){ a=smoothstep(1.0,0.1,length(p)); }
  else if (shape==1){                                   // crisp eye with a glint
    float r=length(p); float aa=fwidth(r);
    float m=smoothstep(0.92+aa,0.92-aa,r); if(m<0.01) discard_fragment();
    float3 c=(r<0.46)?float3(0.05):float3(0.97);
    c=max(c, float3(smoothstep(0.26,0.0,length(p-float2(-0.22,0.26)))));  // highlight
    return float4(gammaOut(c)*m, m); }
  else if (shape==2){ int code=clamp(int(in.params.x+0.5),0,25);
    int cx=clamp(int((p.x*0.5+0.5)*5.0),0,4); int cy=clamp(int((1.0-(p.y*0.5+0.5))*7.0),0,6);
    uint bit=(uint(kFont[code][cy])>>uint(4-cx))&1u; if(bit==0u) discard_fragment();
    return float4(gammaOut(in.color.rgb), in.color.a); }
  else if (shape==3){                                   // fluid translucent CELL (x=seed,y=time)
    float seed=in.params.x, t=in.params.y;
    float r=length(p), ang=atan2(p.y,p.x), aa=fwidth(r);
    // Membrane morphs over time — a soft amoeboid wobble, crisp edge.
    float edge=0.84 + 0.07*sin(ang*3.0 + t*0.8 + seed)
                    + 0.05*sin(ang*5.0 - t*0.6 + seed*1.3)
                    + 0.03*sin(ang*2.0 + t*1.2);
    float mask=smoothstep(edge+aa, edge-aa, r); if(mask<0.01) discard_fragment();
    // Translucent cytoplasm with a faint interior stream.
    float3 col=in.color.rgb * (0.9 + 0.18*fbm(p*3.0+float2(t*0.15,seed)));
    float A = 0.60;                                       // see-through, but crisp-edged
    // Brighter, more-solid membrane rim (lipid bilayer).
    float rim = smoothstep(edge-0.10, edge-0.015, r);
    col = mix(col, in.color.rgb*1.7+0.12, rim*0.85);
    A = mix(A, 0.9, rim);
    // A single central nucleus that gently jiggles, with a nucleolus.
    float2 nucC = 0.05*float2(sin(t*0.5+seed), cos(t*0.4));
    float nd = length(p - nucC);
    col = mix(col, in.color.rgb*0.5 + float3(0.06,0.03,0.10), smoothstep(0.32,0.27,nd)*0.9);
    A = mix(A, 0.92, smoothstep(0.32,0.27,nd)*0.85);
    float nolus = smoothstep(0.09,0.06, length(p - nucC - float2(0.04,0.03)));
    col = mix(col, float3(0.05), nolus*0.7); A = mix(A, 0.96, nolus*0.7);
    A *= mask;
    return float4(gammaOut(col)*A, A); }
  else if (shape==4){                                   // crisp solid disc (rim-shaded)
    float r=length(p), aa=fwidth(r);
    float m=smoothstep(0.95+aa,0.95-aa,r); if(m<0.01) discard_fragment();
    float3 col=in.color.rgb*(1.05 - 0.3*smoothstep(0.45,0.95,r));
    return float4(gammaOut(col)*m*in.color.a, m*in.color.a); }
  else if (shape==5){                                   // furry body (x=seed)
    float seed=in.params.x;
    float r=length(p), ang=atan2(p.y,p.x);
    float sid = floor((ang+3.14159)/6.2831853 * 96.0);   // 96 fur strands around
    float rnd = fract(sin(sid*12.9898 + seed*7.0)*43758.5453);
    float rnd2= fract(sin(sid*4.1414 + seed*3.0)*24634.6345);
    float edge = 0.62 + 0.20*rnd;                        // strands of varied length
    float aa = fwidth(r) + 0.006;
    float mask = smoothstep(edge+aa, edge-aa, r); if(mask<0.01) discard_fragment();
    float3 col = in.color.rgb * (0.72 + 0.42*rnd2);      // strand-to-strand tone
    col *= 0.7 + 0.45*smoothstep(0.25, edge, r);         // brighter at the fur tips
    return float4(gammaOut(col)*mask, mask); }
  return float4(gammaOut(in.color.rgb)*a*in.color.a, a*in.color.a);
}
)METAL";

@interface StyleRenderer : NSObject <MTKViewDelegate> @end

@implementation StyleRenderer {
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _ground, _entity;
    id<MTLBuffer> _buffers[kInFlight];
    int _frameIndex;
    dispatch_semaphore_t _sem;
    std::vector<InstC> _scratch;
    std::vector<Creature> _crits;
    std::mt19937 _rng;
    simd_float2 _uScale, _uOffset;
    double _startTime, _lastFrame;
    float _fps; bool _paused; float _time;
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
    _rng.seed(0xC0FFEE);

    simd_float3 cols[10] = {
        simd_make_float3(0.32f,0.72f,0.34f), simd_make_float3(0.32f,0.56f,0.88f),
        simd_make_float3(0.85f,0.56f,0.24f), simd_make_float3(0.72f,0.76f,0.26f),
        simd_make_float3(0.74f,0.50f,0.88f), simd_make_float3(0.28f,0.78f,0.66f),
        simd_make_float3(0.86f,0.52f,0.55f), simd_make_float3(0.55f,0.78f,0.42f),
        simd_make_float3(0.55f,0.82f,0.72f), simd_make_float3(0.55f,0.42f,0.30f),
    };
    int nsp[10] = { 8, 7, 0, 6, 0, 0, 6, 0, 7, 6 };
    float sizes[10] = { 1.05f,1.05f,1.05f,1.05f,1.05f,1.05f,1.25f,1.30f,1.15f,1.15f };
    std::uniform_real_distribution<float> u(0,1);
    for (int i=0;i<kNumStyles;i++){
        Creature c = {};
        c.style = i; c.nspine = nsp[i];
        int col = i % kCols, row = i / kCols;
        c.cmin = simd_make_float2(col*kCellW, row*kCellH);
        c.cmax = simd_make_float2((col+1)*kCellW, (row+1)*kCellH);
        c.pos = (c.cmin + c.cmax) * 0.5f;
        c.vel = simd_make_float2(0,0);
        c.heading = u(_rng)*6.28f;
        c.phase = u(_rng)*6.28f;
        c.hopT = u(_rng);
        c.size = sizes[i];
        c.speed = (i==ST_FISH?6.5f : i==ST_SERPENT?5.0f : i==ST_HOPPER?7.0f :
                   i==ST_JELLY?4.5f : i==ST_CRAWLER?3.2f : i==ST_FATWORM?2.8f :
                   i==ST_AMOEBA?2.0f : i==ST_CELL?4.2f : i==ST_MOUSE?5.5f : 4.0f);
        c.color = cols[i];
        c.target = c.pos;
        c.retarget = 0;
        for (int s=0;s<10;s++) c.spine[s] = c.pos;
        _crits.push_back(c);
    }

    __unsafe_unretained StyleRenderer *weak = self;
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent*(NSEvent*e){
        if (e.modifierFlags & NSEventModifierFlagCommand) return e;
        if (e.keyCode==49){ weak->_paused=!weak->_paused; return nil; }   // space
        if (e.keyCode==15){ for (auto&c:weak->_crits) c.retarget=0; return nil; } // R
        return e;
    }];

    printf("10 — CRITTER STYLES — ten movement styles side by side.\n"
           "Space pause · R reroll wander targets. Pick a favorite to build out.\n");
    _startTime = CACurrentMediaTime(); _lastFrame = _startTime; _fps = 60; _paused = NO;
    return self;
}

- (void)push:(simd_float2)c half:(simd_float2)h rot:(float)rot shape:(float)s
       color:(simd_float4)col p:(float)p0 {
    if ((int)_scratch.size() >= kMaxInstances) return;
    _scratch.push_back({c.x,c.y,h.x,h.y,rot,s, col.x,col.y,col.z,col.w, p0,0,0,0});
}
- (void)blob:(simd_float2)c r:(float)r color:(simd_float4)col {
    [self push:c half:simd_make_float2(r,r) rot:0 shape:0 color:col p:0];
}
- (void)push2:(simd_float2)c half:(simd_float2)h rot:(float)rot shape:(float)s
        color:(simd_float4)col p0:(float)p0 p1:(float)p1 {
    if ((int)_scratch.size() >= kMaxInstances) return;
    _scratch.push_back({c.x,c.y,h.x,h.y,rot,s, col.x,col.y,col.z,col.w, p0,p1,0,0});
}

// world-space label, centered on x=cx
- (void)label:(const char*)s cx:(float)cx y:(float)y h:(float)h color:(simd_float4)col {
    float gw = h*0.6f, adv = gw + h*0.30f;
    float total = (float)strlen(s) * adv - h*0.30f;
    float x = cx - total*0.5f;
    for (const char *p=s; *p; ++p){
        char ch=*p; int code=-1;
        if (ch>='A'&&ch<='Z') code=ch-'A'; else if (ch>='a'&&ch<='z') code=ch-'a';
        if (code>=0) [self push:simd_make_float2(x+gw*0.5f, y) half:simd_make_float2(gw*0.5f,h*0.5f)
                            rot:0 shape:2 color:col p:(float)code];
        x += adv;
    }
}

// ---------------------------------------------------------------- update ---
- (void)updateCreature:(Creature&)c dt:(float)dt {
    std::uniform_real_distribution<float> u(0,1);
    float m = 2.2f;
    c.retarget -= dt;
    if (c.retarget <= 0 || simd_distance(c.pos, c.target) < 1.6f) {
        c.target = simd_make_float2(c.cmin.x+m + u(_rng)*(c.cmax.x-c.cmin.x-2*m),
                                    c.cmin.y+m + u(_rng)*(c.cmax.y-c.cmin.y-2*m-3.0f));
        c.retarget = 2.0f + u(_rng)*3.0f;
    }
    simd_float2 dir = c.target - c.pos;
    float dl = simd_length(dir); if (dl > 1e-3f) dir /= dl;

    if (c.style == ST_HOPPER) {
        c.hopT += dt / 1.05f; if (c.hopT >= 1.0f) c.hopT -= 1.0f;
        float mv = (c.hopT > 0.2f && c.hopT < 0.72f) ? 1.0f : 0.0f;
        simd_float2 want = dir * c.speed * 1.7f * mv;
        c.vel += (want - c.vel) * std::min((mv>0?7.0f:2.5f)*dt, 1.0f);
    } else if (c.style == ST_JELLY) {
        float thrust = std::max(0.0f, sinf(c.phase*3.0f));       // jet on contraction
        simd_float2 want = dir * c.speed * (0.25f + 1.7f*thrust);
        c.vel += (want - c.vel) * std::min(2.0f*dt, 1.0f);
    } else {
        float gait = 1.0f, accel = 3.0f;
        if (c.style == ST_CRAWLER) gait = 0.5f + 0.7f*std::max(0.0f, sinf(c.phase*4.0f)); // surges
        if (c.style == ST_MOUSE) { gait = 0.55f + 0.6f*std::max(0.0f, sinf(c.phase*3.0f)); accel = 6.0f; } // scurry
        simd_float2 want = dir * c.speed * gait;
        c.vel += (want - c.vel) * std::min(accel*dt, 1.0f);
    }
    c.pos += c.vel * dt;
    if (simd_length(c.vel) > 0.05f) c.heading = atan2f(c.vel.y, c.vel.x);
    c.pos.x = std::clamp(c.pos.x, c.cmin.x+m, c.cmax.x-m);
    c.pos.y = std::clamp(c.pos.y, c.cmin.y+m, c.cmax.y-m-3.0f);

    float rate = (c.style==ST_FISH?7.5f : c.style==ST_SERPENT?6.0f :
                  c.style==ST_CRAWLER?5.0f : c.style==ST_WALKER?6.5f : c.style==ST_JELLY?1.0f :
                  c.style==ST_FATWORM?3.6f : c.style==ST_AMOEBA?1.5f : c.style==ST_CELL?9.0f :
                  c.style==ST_MOUSE?7.0f : 6.0f);
    c.phase += dt * rate;

    if (c.nspine > 0) {
        c.spine[0] = c.pos;
        simd_float2 perp = simd_make_float2(-sinf(c.heading), cosf(c.heading));
        float mv = simd_length(c.vel) / std::max(c.speed, 0.1f);
        for (int i=1;i<c.nspine;i++){
            simd_float2 dd = c.spine[i] - c.spine[i-1];
            float dlen = simd_length(dd);
            float link = (c.style==ST_FATWORM ? 0.62f : c.style==ST_CELL ? 0.40f : 0.52f) * c.size;
            if (c.style == ST_CRAWLER) link *= (0.62f + 0.55f*sinf(c.phase*4.0f - i*0.9f)); // peristalsis
            if (c.style == ST_FATWORM) link *= (0.82f + 0.22f*sinf(c.phase*3.0f - i*0.8f)); // stretch/bunch
            if (dlen > 1e-4f) c.spine[i] = c.spine[i-1] + dd/dlen*link;
            float amp = (c.style==ST_FISH ? 0.14f*(i/(float)c.nspine)
                        : c.style==ST_SERPENT ? 0.11f
                        : c.style==ST_FATWORM ? 0.06f
                        : c.style==ST_CELL ? 0.24f*(i/(float)c.nspine)
                        : c.style==ST_MOUSE ? 0.05f : 0.0f) * c.size;
            c.spine[i] += perp * sinf(c.phase - i*0.8f) * amp * (0.4f + mv);
        }
    }
}

// ---------------------------------------------------------------- render ---
- (void)renderCreature:(const Creature&)c {
    simd_float2 fwd = simd_make_float2(cosf(c.heading), sinf(c.heading));
    simd_float2 perp = simd_make_float2(-fwd.y, fwd.x);
    simd_float4 col = simd_make_float4(c.color, 1.0f);
    simd_float4 dark = simd_make_float4(c.color*0.55f, 1.0f);
    float S = c.size;

    if (c.style==ST_SERPENT || c.style==ST_FISH || c.style==ST_CRAWLER || c.style==ST_FATWORM) {
        for (int i = c.nspine-1; i >= 0; i--) {
            float un = i/(float)(c.nspine-1);
            float taper, base, seg = 1.0f;
            if (c.style == ST_CRAWLER) { taper = 1.0f-0.25f*un; base = 0.42f;
                seg = 1.0f + 0.16f*sinf(c.phase*4.0f - i); }
            else if (c.style == ST_FATWORM) { taper = 1.0f-0.14f*un; base = 0.66f;
                seg = 1.0f + 0.12f*sinf(c.phase*3.0f - i);
                if (i==0 || i==c.nspine-1) taper *= 0.82f; }             // rounded ends
            else { taper = 1.0f-0.6f*un; base = 0.42f; }
            float r = S*base*taper*seg;
            [self blob:c.spine[i] r:r color:simd_make_float4(c.color*(0.75f+0.25f*(1.0f-un)),1.0f)];
        }
        if (c.style == ST_FATWORM && c.nspine > 2)                // pale saddle band
            [self blob:c.spine[2] r:S*0.56f color:simd_make_float4(c.color*1.25f+simd_make_float3(0.1f,0.1f,0.1f),1.0f)];
        if (c.style == ST_FISH) {                                 // tail fin
            simd_float2 tp = c.spine[c.nspine-1];
            simd_float2 tperp = c.spine[c.nspine-1] - c.spine[c.nspine-2];
            float tl = simd_length(tperp); tperp = tl>1e-3f ? tperp/tl : fwd;
            simd_float2 fperp = simd_make_float2(-tperp.y, tperp.x);
            float sweep = sinf(c.phase)*0.4f;
            [self blob:tp - tperp*0.4f*S + fperp*(0.35f+sweep)*S r:S*0.2f color:dark];
            [self blob:tp - tperp*0.4f*S - fperp*(0.35f-sweep)*S r:S*0.2f color:dark];
        }
        // eyes at head
        [self push:c.pos + fwd*0.18f*S + perp*0.22f*S half:simd_make_float2(S*0.15f,S*0.15f)
              rot:0 shape:1 color:col p:0];
        [self push:c.pos + fwd*0.18f*S - perp*0.22f*S half:simd_make_float2(S*0.15f,S*0.15f)
              rot:0 shape:1 color:col p:0];
    }
    else if (c.style == ST_WALKER) {
        float bob = 1.0f + 0.05f*sinf(c.phase*2.0f);
        for (int k=-1;k<=1;k++)                                   // oval body
            [self blob:c.pos + fwd*(k*0.5f*S) r:S*(0.55f-0.08f*(k<0?-k:k))*bob color:col];
        for (int li=0; li<6; li++) {                             // 6 legs, tripod gait
            int side = (li < 3) ? 1 : -1;
            int seg  = li % 3;
            float along = (seg-1)*0.62f*S;
            simd_float2 attach = c.pos + fwd*along + perp*side*0.42f*S;
            bool groupA = ((side>0) != (seg==1));
            float lp = c.phase*2.0f + (groupA ? 0.0f : 3.14159f);
            float step = sinf(lp), lift = cosf(lp);
            simd_float2 foot = attach + perp*side*0.85f*S + fwd*step*0.5f*S;
            simd_float2 knee = (attach+foot)*0.5f + perp*side*0.1f*S;
            [self blob:knee r:S*0.14f color:dark];
            [self blob:foot r:S*0.16f*(lift>0?0.75f:1.0f) color:dark];
        }
        [self push:c.pos + fwd*0.5f*S + perp*0.2f*S half:simd_make_float2(S*0.15f,S*0.15f)
              rot:0 shape:1 color:col p:0];
        [self push:c.pos + fwd*0.5f*S - perp*0.2f*S half:simd_make_float2(S*0.15f,S*0.15f)
              rot:0 shape:1 color:col p:0];
    }
    else if (c.style == ST_JELLY) {
        float pulse = std::max(0.0f, sinf(c.phase*3.0f));        // 0..1 contraction
        float R = S*(1.15f - 0.30f*pulse);
        simd_float2 back = -fwd;
        for (int t=0;t<5;t++) {                                  // trailing tentacles
            float toff = (t-2)*0.32f;
            simd_float2 base = c.pos + back*R*0.55f + perp*toff*S;
            for (int s=1;s<=4;s++) {
                simd_float2 tp = base + back*(s*0.36f*S)
                    + perp*sinf(c.phase*2.0f + s*0.7f + t)*0.16f*S;
                [self blob:tp r:S*0.11f*(1.0f-0.15f*s)
                     color:simd_make_float4(c.color, 0.55f)];
            }
        }
        [self blob:c.pos r:R color:simd_make_float4(c.color, 0.42f)];        // bell
        [self blob:c.pos r:R*0.62f color:simd_make_float4(c.color*1.3f, 0.5f)];
        [self blob:c.pos + fwd*R*0.2f r:R*0.28f color:simd_make_float4(c.color*1.5f, 0.55f)];
    }
    else if (c.style == ST_HOPPER) {
        float ph = c.hopT;
        float crouch = expf(-powf((ph-0.06f)/0.11f,2.0f)) + expf(-powf((ph-0.9f)/0.1f,2.0f));
        float air = std::clamp((ph-0.2f)/0.2f,0.0f,1.0f) * (1.0f - std::clamp((ph-0.62f)/0.2f,0.0f,1.0f));
        float sx = 1.0f + 0.45f*air - 0.22f*crouch;              // stretch along heading
        float sy = 1.0f - 0.32f*air + 0.34f*crouch;              // squash across
        [self blob:c.pos + fwd*0.28f*S*sx r:S*0.5f*sy color:col];
        [self blob:c.pos - fwd*0.14f*S*sx r:S*0.42f*sy color:col];
        for (int side=-1; side<=1; side+=2) {                    // 2 back legs
            simd_float2 hip = c.pos - fwd*0.28f*S + perp*side*0.28f*S;
            simd_float2 foot = hip - fwd*(0.2f+0.6f*air)*S + perp*side*0.15f*S;
            [self blob:(hip+foot)*0.5f r:S*0.13f color:dark];
            [self blob:foot r:S*0.15f color:dark];
        }
        [self push:c.pos + fwd*0.42f*S*sx + perp*0.18f*S half:simd_make_float2(S*0.14f,S*0.14f)
              rot:0 shape:1 color:col p:0];
        [self push:c.pos + fwd*0.42f*S*sx - perp*0.18f*S half:simd_make_float2(S*0.14f,S*0.14f)
              rot:0 shape:1 color:col p:0];
    }
    else if (c.style == ST_AMOEBA) {
        // Translucent oozing blob: a wobbling membrane with a pseudopod that
        // reaches toward the direction of travel.
        const int N = 11;
        for (int k=0;k<N;k++) {
            float ang = k/(float)N * 6.2831853f;
            simd_float2 nd = simd_make_float2(cosf(ang), sinf(ang));
            float wob = 0.72f + 0.32f*sinf(ang*3.0f + c.phase*2.0f)
                              + 0.14f*sinf(ang*5.0f - c.phase*1.5f);
            float fdot = nd.x*fwd.x + nd.y*fwd.y;
            float pseudo = 0.45f * std::max(0.0f, fdot);            // reach forward
            float rr = S*(wob + pseudo);
            [self blob:c.pos + nd*rr*0.62f r:S*0.44f color:simd_make_float4(c.color, 0.40f)];
        }
        [self blob:c.pos r:S*0.55f color:simd_make_float4(c.color*0.8f, 0.55f)];       // cytoplasm
        [self blob:c.pos + fwd*0.15f*S r:S*0.26f color:simd_make_float4(c.color*1.4f, 0.6f)]; // nucleus
    }
    else if (c.style == ST_CELL) {
        // Fluid translucent cell: it stretches along its heading as it swims,
        // trails a flagellum, and has a single central nucleus + eyespots.
        float seed = c.style*2.3f + 1.1f;
        float mv = simd_length(c.vel) / std::max(c.speed, 0.1f);
        for (int i = c.nspine-1; i >= 1; i--) {                   // flagellum (behind)
            float un = i/(float)(c.nspine-1);
            float tr = S*0.18f*(1.0f - 0.7f*un);
            [self push:c.spine[i] half:simd_make_float2(tr,tr) rot:0 shape:4
                  color:simd_make_float4(c.color*0.7f, 0.9f) p:0];
        }
        float br = S*1.7f;
        simd_float2 hb = simd_make_float2(br*(1.0f+0.28f*mv), br*(1.0f-0.16f*mv)); // stretch
        [self push2:c.pos half:hb rot:c.heading shape:3
              color:simd_make_float4(c.color,1.0f) p0:seed p1:_time];
        float er = S*0.24f;                                       // two eyespots up front
        [self push:c.pos + fwd*hb.x*0.44f + perp*hb.y*0.34f half:simd_make_float2(er,er)
              rot:0 shape:1 color:simd_make_float4(0.95f,0.97f,1.0f,1.0f) p:0];
        [self push:c.pos + fwd*hb.x*0.44f - perp*hb.y*0.34f half:simd_make_float2(er,er)
              rot:0 shape:1 color:simd_make_float4(0.95f,0.97f,1.0f,1.0f) p:0];
    }
    else if (c.style == ST_MOUSE) {
        // Small furry mammal: fuzzy body + head, round ears, eyes, pink nose,
        // and a long thin tail. Fur is a strand-edged shader shape.
        float seed = c.style*3.3f + 2.0f;
        float bob = 1.0f + 0.04f*sinf(c.phase*2.0f);
        for (int i = c.nspine-1; i >= 1; i--) {                   // long thin tail
            float un = i/(float)(c.nspine-1);
            float tr = S*0.13f*(1.0f - 0.55f*un);
            [self push:c.spine[i] half:simd_make_float2(tr,tr) rot:0 shape:4
                  color:simd_make_float4(simd_make_float3(0.5f,0.36f,0.30f), 1.0f) p:0];
        }
        // furry body (oval), then a smaller furry head up front
        [self push2:c.pos - fwd*0.15f*S half:simd_make_float2(S*0.95f, S*0.78f*bob)
              rot:c.heading shape:5 color:simd_make_float4(c.color,1.0f) p0:seed p1:0];
        simd_float2 head = c.pos + fwd*0.72f*S;
        [self push2:head half:simd_make_float2(S*0.52f, S*0.50f) rot:c.heading shape:5
              color:simd_make_float4(c.color*1.08f,1.0f) p0:seed+4.0f p1:0];
        // round ears
        for (int sd=-1; sd<=1; sd+=2)
            [self push2:head + perp*sd*0.42f*S + fwd*0.05f*S half:simd_make_float2(S*0.26f,S*0.26f)
                  rot:c.heading shape:5 color:simd_make_float4(c.color*0.92f,1.0f) p0:seed+(float)sd p1:0];
        // beady eyes + pink nose
        for (int sd=-1; sd<=1; sd+=2)
            [self push:head + fwd*0.30f*S + perp*sd*0.24f*S half:simd_make_float2(S*0.11f,S*0.11f)
                  rot:0 shape:4 color:simd_make_float4(0.05f,0.04f,0.05f,1.0f) p:0];
        [self push:head + fwd*0.52f*S half:simd_make_float2(S*0.10f,S*0.10f) rot:0 shape:4
              color:simd_make_float4(0.95f,0.55f,0.62f,1.0f) p:0];
    }
}

- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) return;

    double now = CACurrentMediaTime();
    float dt = (float)(now - _lastFrame); _lastFrame = now;
    _time = (float)(now - _startTime);
    if (dt > 0) _fps += (1.0f/dt - _fps)*0.05f;
    if (!_paused) { float sd = std::min(dt, 0.05f); for (auto&c:_crits) [self updateCreature:c dt:sd]; }

    float aspect = (float)(view.drawableSize.width / view.drawableSize.height);
    float s = std::min(2.0f*aspect/kWorldW, 2.0f/kWorldH) * 0.96f;
    _uScale = simd_make_float2(s/aspect, s);
    _uOffset = simd_make_float2(-kWorldW*0.5f*s/aspect, -kWorldH*0.5f*s);
    struct { simd_float2 scale,offset,res; float time,pad; } uni = {
        _uScale,_uOffset, simd_make_float2((float)view.drawableSize.width,(float)view.drawableSize.height),
        (float)(now-_startTime), 0 };

    dispatch_semaphore_wait(_sem, DISPATCH_TIME_FOREVER);
    _scratch.clear();
    for (const Creature &c : _crits) {
        // soft shadow
        [self push:c.pos + simd_make_float2(0.2f,-0.2f) half:simd_make_float2(c.size*0.6f,c.size*0.6f)
              rot:0 shape:0 color:simd_make_float4(0,0,0,0.22f) p:0];
        [self renderCreature:c];
        float cxm = (c.cmin.x + c.cmax.x)*0.5f;
        [self label:kStyleName[c.style] cx:cxm y:c.cmax.y-1.6f h:1.5f
               color:simd_make_float4(0.85f,0.9f,0.95f,1.0f)];
    }
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

    view.window.title = [NSString stringWithFormat:@"10 — CRITTER STYLES ▸ 10 movement styles%s ▸ %.0f fps",
                         _paused?" ▸ PAUSED":"", _fps];
}
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}
@end

int main() {
    return RunMetalApp(@"10 — CRITTER STYLES", 1280, 776, ^(MTKView *view){
        return (NSObject<MTKViewDelegate> *)[[StyleRenderer alloc] initWithView:view];
    });
}
