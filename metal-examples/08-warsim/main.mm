// 08 — WAR SIM (TABS-style battle simulator, v2)
//
// Paint two armies on a battlefield, hit FIGHT, and watch them clash until
// one side is annihilated. Thousands of little procedural soldiers — no art
// assets; every character is SDF shapes on an instanced billboard.
//
//   * Five unit types:
//       1 Infantry   sword & shield line troops
//       2 Archer     ballistic arrow volleys, weak up close
//       3 Cavalry    fast; heavy bonus damage on the charge
//       4 Berserker  huge damage, no armor
//       5 Catapult   lobs flaming balls that EXPLODE on impact
//   * Real HUD: clickable unit buttons (icons are the actual sprites), a
//     FIGHT/rematch button, and live army counters (procedural digit font).
//   * Camera: scroll wheel zooms, LEFT/RIGHT arrows (or Q/E) orbit the
//     field, UP/DOWN tilt. Painting works from any angle.
//   * Juice: knockback, impact sparks, battle dust, camera shake and
//     scorched craters on catapult hits.
//
// Controls:
//   1-5 or click HUD   select unit type
//   Click/drag         stamp a squad (left half = RED, right half = BLUE)
//   Right-click        erase   SPACE/FIGHT: battle   R: clear   D: defaults
//   Scroll             zoom    Arrows / Q,E: orbit + tilt

#include "../common/app.h"
#include <simd/simd.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <random>
#include <string>
#include <vector>

// ---------------------------------------------------------------- Tuning ---

static const float kFieldW = 140.0f;
static const float kFieldH = 80.0f;
static const float kNoMansMin = 58.0f;
static const float kNoMansMax = 82.0f;
static const int kMaxUnits = 3000;
static const int kMaxBillboards = 8192;
static const int kMaxFlats = 12288;
static const int kMaxInFlight = 3;
static const int kUnitCap = 5800;        // billboard budget for units+arrows
static const int kPuffCap = 2000;        // particle budget (reserved region)

enum { kInfantry = 0, kArcher = 1, kCavalry = 2, kBerserker = 3, kCatapult = 4,
       kUnitTypeCount = 5 };
enum { kPhaseSetup = 0, kPhaseBattle = 1, kPhaseDone = 2 };
enum { kPuffBlood = 0, kPuffDust = 1, kPuffSpark = 2, kPuffFire = 3, kPuffSmoke = 4,
       kPuffSplash = 5 };

struct UnitSpec {
    const char *name;
    float hp, damage, reach, speed, radius, cooldown;
    float width, height;
};
static const UnitSpec kSpecs[kUnitTypeCount] = {
    {"Infantry",  100, 22, 0.9f, 2.6f, 0.35f, 1.00f, 1.15f, 1.45f},
    {"Archer",     55,  8, 0.8f, 2.8f, 0.30f, 1.20f, 1.00f, 1.40f},
    {"Cavalry",   160, 30, 1.2f, 7.5f, 0.55f, 1.10f, 2.10f, 1.90f},
    {"Berserker", 140, 45, 1.0f, 3.4f, 0.40f, 0.90f, 1.30f, 1.55f},
    {"Catapult",  220,  6, 1.4f, 0.9f, 1.00f, 1.30f, 2.60f, 2.00f},
};
static const float kArcherRange = 26.0f;
static const float kArcherReload = 2.4f;
static const float kArrowDamage = 28.0f;
static const float kChargeSpeed = 5.5f;
static const float kChargeMult = 3.0f;
static const float kCatMinRange = 14.0f;
static const float kCatMaxRange = 70.0f;
static const float kCatReload = 6.0f;
static const float kBoomRadius = 4.5f;
static const float kBoomKill = 1.9f;      // instakill radius

static const simd_float4 kArmyColor[2] = {
    {0.80f, 0.16f, 0.12f, 1.0f},
    {0.15f, 0.35f, 0.85f, 1.0f},
};

// ---------------------------------------------------------------- Shaders ---

static const char *kShaderSource = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct Uni {
    float4x4 viewProj;
    float2 resolution;
    float time;
    float phase;
    float2 camRight;     // world-space xz of the camera right axis
    float lakeCount;
    float hillCount;
    float4 lakes[3];     // xy center (board), z radius, w seed
    float4 hills[8];     // xy center (board), z radius, w height (+hill/-valley)
};

// Heightfield: sum of gaussian hills/valleys, flattened around lakes so the
// water always sits in level ground. MUST match the CPU heightAt: mirror.
float terrainH(float2 w, constant Uni &u) {
    float h = 0.0;
    for (int i = 0; i < int(u.hillCount + 0.5); i++) {
        float2 d = w - u.hills[i].xy;
        float s = u.hills[i].z * 0.5;
        h += u.hills[i].w * exp(-dot(d, d) / (2.0 * s * s));
    }
    for (int i = 0; i < int(u.lakeCount + 0.5); i++) {
        float dl = length(w - u.lakes[i].xy);
        h *= smoothstep(u.lakes[i].z * 0.95, u.lakes[i].z * 1.8, dl);
    }
    return h;
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
    for (int i = 0; i < 3; i++) { v += a * vnoise(p); p *= 2.17; a *= 0.5; }
    return v;
}

float3 gammaOut(float3 c) { return pow(max(c, 0.0), float3(0.4545)); }

float sdSeg(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    float t = clamp(dot(p - a, ab) / dot(ab, ab), 0.0, 1.0);
    return length(p - a - ab * t);
}

// ---------------- Ground ----------------
struct GroundVSOut {
    float4 position [[position]];
    float2 w;
};

// Tessellated ground mesh: vertices carry board coords; the heightfield is
// applied here so hills and valleys are real displaced geometry.
vertex GroundVSOut ground_vertex(uint vid [[vertex_id]],
                                 const device packed_float2 *verts [[buffer(0)]],
                                 constant Uni &u [[buffer(1)]]) {
    float2 b = float2(verts[vid]);
    GroundVSOut o;
    o.position = u.viewProj * float4(b.x, terrainH(b, u), -b.y, 1.0);
    o.w = b;
    return o;
}

fragment float4 ground_fragment(GroundVSOut in [[stage_in]],
                                constant Uni &u [[buffer(0)]]) {
    float2 w = in.w;
    float n1 = fbm(w * 0.05);
    float n2 = fbm(w * 0.35 + 17.0);
    float3 grass = mix(float3(0.13, 0.24, 0.08), float3(0.22, 0.34, 0.12), n1);
    grass *= 0.85 + 0.3 * n2;

    // Height + slope: hilltops dry out, valleys go lush; sun-facing slopes
    // catch light. Normal from central differences of the heightfield.
    float hC = terrainH(w, u);
    float hX = terrainH(w + float2(0.9, 0.0), u);
    float hY = terrainH(w + float2(0.0, 0.9), u);
    float3 nrm = normalize(float3(-(hX - hC) / 0.9, 1.0, -(hY - hC) / 0.9));
    grass = mix(grass, float3(0.30, 0.29, 0.14), clamp(hC * 0.16, 0.0, 0.5));   // dry tops
    grass = mix(grass, float3(0.08, 0.19, 0.07), clamp(-hC * 0.22, 0.0, 0.5));  // lush dips
    float sun = dot(nrm, normalize(float3(0.45, 1.0, 0.35)));
    grass *= 0.72 + 0.45 * clamp(sun, 0.0, 1.0);

    float mid = smoothstep(18.0, 4.0, abs(w.x - 70.0));
    float patches = smoothstep(0.62, 0.75, fbm(w * 0.13 + 41.0));
    float dirtAmt = max(mid * 0.7, patches * 0.5);
    float3 dirt = float3(0.30, 0.24, 0.15) * (0.8 + 0.3 * n2);
    float3 col = mix(grass, dirt, dirtAmt);

    float2 bd = max(float2(0.0, 0.0) - w, w - float2(140.0, 80.0));
    float outside = max(max(bd.x, bd.y), 0.0);
    col *= 1.0 / (1.0 + outside * 0.12);

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

    // Lakes: irregular noisy shoreline, sandy ring, animated water.
    for (int i = 0; i < int(u.lakeCount + 0.5); i++) {
        float2 lp = w - u.lakes[i].xy;
        float wob = (fbm(w * 0.22 + u.lakes[i].w * 31.0) - 0.5) * 0.30;
        float d = length(lp) / u.lakes[i].z - (0.92 + wob);   // <0 inside
        float sand = smoothstep(0.14, 0.0, abs(d - 0.05));
        col = mix(col, float3(0.42, 0.36, 0.24), sand * 0.8);
        float water = smoothstep(0.015, -0.015, d);
        if (water > 0.0) {
            float depth = smoothstep(0.0, -0.55, d);
            float3 wcol = mix(float3(0.16, 0.32, 0.36), float3(0.05, 0.14, 0.24), depth);
            float ripple = fbm(w * 0.7 + float2(u.time * 0.22, u.time * 0.16)
                               + u.lakes[i].w * 9.0);
            wcol += float3(0.10, 0.14, 0.15) * smoothstep(0.55, 0.85, ripple);
            float shoreFoam = smoothstep(0.05, 0.0, abs(d + 0.03));
            wcol += float3(0.20) * shoreFoam;
            col = mix(col, wcol, water);
        }
    }

    col *= 0.9 + 0.2 * smoothstep(120.0, 0.0, length(w - float2(70.0, 30.0)));
    return float4(gammaOut(col), 1.0);
}

// ---------------- Flat decals ----------------
struct FInst {
    packed_float2 center;
    packed_float2 half2;
    float rot;
    float shape;             // 0 shadow, 1 splat, 2 corpse
    packed_float4 color;
    packed_float4 params;
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
    o.position = u.viewProj * float4(b.x, terrainH(b, u) + 0.05, -b.y, 1.0);
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
    if (shape == 0) {
        a = smoothstep(1.0, 0.35, length(p));
    } else if (shape == 1) {
        float r = length(p);
        float n = fbm(p * 2.5 + in.params.x * 19.0);
        a = smoothstep(0.9, 0.25, r + (n - 0.5) * 0.8);
    } else if (shape == 2) {
        float2 q = float2(p.x, p.y * 2.2);
        float n = fbm(p * 3.0 + in.params.x * 7.0);
        a = smoothstep(1.0, 0.6, length(q) + (n - 0.5) * 0.35);
    }
    float alpha = a * in.color.a;
    return float4(gammaOut(in.color.rgb) * alpha, alpha);
}

// ---------------- Billboards (units, arrows, particles) + HUD ----------------
struct BInst {
    float px, pz;
    float yoff;
    float w, h;
    float rot;
    float shape;
    float facing;
    packed_float4 color;
    float flash;
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
    // Cylindrical billboard standing on the heightfield.
    float ground = terrainH(float2(inst.px, inst.pz), u);
    float3 wp = float3(inst.px + u.camRight.x * q.x,
                       ground + inst.h * 0.5 + q.y + inst.yoff,
                       -inst.pz + u.camRight.y * q.x);
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

// HUD: instances in NDC directly (px,pz = center; w,h = half sizes).
vertex BOut hud_vertex(uint vid [[vertex_id]],
                       uint iid [[instance_id]],
                       const device BInst *insts [[buffer(0)]],
                       constant Uni &u [[buffer(1)]]) {
    BInst inst = insts[iid];
    float2 lp = kCorners[vid];
    BOut o;
    o.position = float4(inst.px + lp.x * inst.w, inst.pz + lp.y * inst.h, 0.0, 1.0);
    o.lp = lp;
    o.color = float4(inst.color);
    o.shape = inst.shape;
    o.facing = inst.facing;
    o.flash = inst.flash;
    o.seed = inst.seed;
    return o;
}

// 5x7 digit bitmaps (5 bits per row, MSB left).
constant ushort kDigitRows[10][7] = {
    {0x0E,0x11,0x13,0x15,0x19,0x11,0x0E}, {0x04,0x0C,0x04,0x04,0x04,0x04,0x0E},
    {0x0E,0x11,0x01,0x06,0x08,0x10,0x1F}, {0x1F,0x02,0x04,0x02,0x01,0x11,0x0E},
    {0x02,0x06,0x0A,0x12,0x1F,0x02,0x02}, {0x1F,0x10,0x1E,0x01,0x01,0x11,0x0E},
    {0x06,0x08,0x10,0x1E,0x11,0x11,0x0E}, {0x1F,0x01,0x02,0x04,0x08,0x08,0x08},
    {0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E}, {0x0E,0x11,0x11,0x0F,0x01,0x02,0x0C},
};

fragment float4 unit_fragment(BOut in [[stage_in]],
                              constant Uni &u [[buffer(0)]]) {
    float2 p = in.lp;
    p.x *= in.facing;
    int shape = int(in.shape + 0.5);
    float3 army = in.color.rgb;
    const float3 skin = float3(0.85, 0.62, 0.45);
    const float3 steel = float3(0.55, 0.58, 0.62);
    const float3 wood = float3(0.35, 0.22, 0.10);
    const float3 darkwood = float3(0.22, 0.13, 0.06);

    // ---- particles ----
    if (shape == 5) {
        // Soft puff. color = tint, color.a = fade, flash = occlusion
        // (1 solid smoke ... 0 pure additive fire/spark).
        float r = length(p);
        float a = smoothstep(1.0, 0.0, r);
        a *= a * in.color.a;
        return float4(in.color.rgb * a, a * in.flash);
    }

    // ---- HUD widgets ----
    if (shape == 10) {                    // rounded panel (button)
        float2 q = abs(p) - float2(0.78, 0.78);
        float d = length(max(q, 0.0)) - 0.22;
        float aa = fwidth(d) * 1.5;
        float body = smoothstep(aa, -aa, d);
        float border = smoothstep(aa, -aa, abs(d) - 0.06);
        float3 bcol = mix(float3(0.35, 0.38, 0.42), float3(1.0, 0.95, 0.7), in.flash);
        float3 rgb = float3(0.06, 0.07, 0.09) * body * 0.85
                   + bcol * border * (0.6 + 0.6 * in.flash);
        float alpha = max(body * 0.82, border);
        return float4(rgb, alpha * in.color.a);
    }
    if (shape == 11) {                    // play triangle (FIGHT)
        float d1 = p.x * 0.5 + abs(p.y) * 0.9 - 0.42;
        float cov = step(d1, 0.0) * step(-0.55, p.x);
        if (cov < 0.5) discard_fragment();
        return float4(in.color.rgb, 1.0);
    }
    if (shape == 12) {                    // digit (seed = 0..9)
        int d = clamp(int(in.seed + 0.5), 0, 9);
        int cx = clamp(int((p.x * 0.5 + 0.5) * 5.0), 0, 4);
        int cy = clamp(int((1.0 - (p.y * 0.5 + 0.5)) * 7.0), 0, 6);
        uint bit = (uint(kDigitRows[d][cy]) >> uint(4 - cx)) & 1u;
        if (bit == 0u) discard_fragment();
        return float4(in.color.rgb, in.color.a);
    }
    if (shape == 13) {                    // solid rect (score bar segments)
        return float4(in.color.rgb * in.color.a, in.color.a);
    }

    if (shape == 4) {                     // arrow
        float sh = sdSeg(p, float2(-0.9, 0.0), float2(0.7, 0.0));
        float head = sdSeg(p, float2(0.7, 0.0), float2(0.95, 0.0));
        float cov = step(sh, 0.10) + step(head, 0.18);
        if (cov < 0.5) discard_fragment();
        return float4(gammaOut(mix(wood, steel, step(0.5, p.x)) * 0.9), 1.0);
    }

    if (shape == 14) {                    // conifer tree (color = canopy tint)
        float trunk = step(max(abs(p.x) - 0.07, abs(p.y + 0.82) - 0.20), 0.0);
        float cov = trunk;
        float3 colr = float3(0.30, 0.19, 0.10);
        for (int L = 0; L < 3; L++) {
            float base = -0.60 + 0.44 * float(L);
            float topw = 0.72 - 0.18 * float(L);
            float f = (p.y - base) / 0.78;
            float tri = step(0.0, f) * step(f, 1.0) * step(abs(p.x), topw * (1.0 - f));
            cov = max(cov, tri);
            colr = mix(colr, in.color.rgb * (0.82 + 0.18 * float(L)), tri);
        }
        if (cov < 0.5) discard_fragment();
        float sh2 = 0.72 + 0.28 * smoothstep(-1.0, 1.0, p.y);
        sh2 *= 1.0 - 0.18 * smoothstep(0.0, 0.8, -p.x);
        // per-tree light variation
        sh2 *= 0.88 + 0.24 * fract(in.seed * 17.0);
        return float4(gammaOut(colr * sh2), 1.0);
    }

    if (shape == 15) {                    // boulder (color = rock tint)
        float2 q = p * float2(1.0, 1.25);
        float n = fbm(p * 2.3 + in.seed * 13.0);
        float r = length(q) + (n - 0.5) * 0.30;
        if (r > 0.78) discard_fragment();
        float sh2 = 0.55 + 0.50 * smoothstep(-0.9, 0.9, p.y);
        sh2 *= 1.0 - 0.20 * smoothstep(0.0, 0.8, -p.x);
        float3 colr = in.color.rgb * sh2 * (0.85 + 0.30 * fbm(p * 4.0 + in.seed * 7.0));
        return float4(gammaOut(colr), 1.0);
    }

    // ---- soldiers & catapult ----
    float cov = 0.0;
    float3 col = army;

    if (shape == 2) {                     // CAVALRY
        float horse = step(sdSeg(p, float2(-0.45, -0.42), float2(0.35, -0.42)), 0.30);
        horse += step(sdSeg(p, float2(0.35, -0.35), float2(0.62, -0.05)), 0.14);
        horse += step(length((p - float2(0.70, 0.02)) * float2(1.0, 1.4)), 0.16);
        horse += step(sdSeg(p, float2(-0.42, -0.55), float2(-0.45, -0.98)), 0.06);
        horse += step(sdSeg(p, float2(0.30, -0.55), float2(0.33, -0.98)), 0.06);
        horse += step(sdSeg(p, float2(-0.15, -0.55), float2(-0.16, -0.95)), 0.055);
        horse += step(sdSeg(p, float2(0.08, -0.55), float2(0.09, -0.95)), 0.055);
        float horseCov = min(horse, 1.0);
        float body = step(sdSeg(p, float2(-0.10, -0.15), float2(-0.10, 0.38)), 0.17);
        float headC = step(length(p - float2(-0.10, 0.58)), 0.15);
        float lance = step(sdSeg(p, float2(-0.05, 0.05), float2(0.85, 0.42)), 0.045);
        cov = max(max(horseCov, body), max(headC, lance));
        col = float3(0.24, 0.16, 0.10);
        col = mix(col, army, body);
        col = mix(col, skin, headC);
        col = mix(col, wood, lance * (1.0 - body));
        float blanket = step(sdSeg(p, float2(-0.28, -0.40), float2(0.10, -0.40)), 0.20);
        col = mix(col, army * 0.8, blanket * horseCov * (1.0 - body) * (1.0 - lance));
    } else if (shape == 6) {              // CATAPULT
        // wheels
        float wheels = step(length(p - float2(-0.48, -0.72)), 0.20)
                     + step(length(p - float2(0.42, -0.72)), 0.20);
        // base beam + upright
        float frame = step(sdSeg(p, float2(-0.62, -0.55), float2(0.60, -0.55)), 0.10);
        frame += step(sdSeg(p, float2(0.18, -0.5), float2(0.30, -0.02)), 0.08);
        // throwing arm, rotating around the axle with the attack flash
        float ang = -1.15 + 1.75 * in.flash;     // cocked -> flung
        float2 tip = float2(0.30, -0.02) + float2(cos(ang), sin(ang)) * -0.85;
        float arm = step(sdSeg(p, float2(0.30, -0.02), tip), 0.07);
        float bucket = step(length(p - tip), 0.13);
        // army banner on the upright
        float pole = step(sdSeg(p, float2(0.30, -0.02), float2(0.30, 0.55)), 0.035);
        float flag = step(max(abs(p.x - 0.44) - 0.14, abs(p.y - 0.44) - 0.10), 0.0);
        cov = max(max(min(wheels, 1.0), min(frame, 1.0)),
                  max(max(arm, bucket), max(pole, flag)));
        col = darkwood;
        col = mix(col, wood, min(frame, 1.0));
        col = mix(col, wood, arm);
        col = mix(col, float3(0.15, 0.13, 0.11), bucket);
        col = mix(col, wood * 0.8, pole);
        col = mix(col, army, flag);
    } else {                              // bipeds
        float tw = (shape == 3) ? 0.30 : 0.24;
        float body = step(sdSeg(p, float2(0.0, -0.30), float2(0.0, 0.28)), tw);
        body = max(body, step(sdSeg(p, float2(-0.10, -0.35), float2(-0.14, -0.95)), 0.09));
        body = max(body, step(sdSeg(p, float2(0.10, -0.35), float2(0.14, -0.95)), 0.09));
        float headC = step(length(p - float2(0.0, 0.52)), 0.18);
        float gear = 0.0, gearC = 0.0;
        float3 gearCol = steel;
        if (shape == 0) {
            gear = step(max(abs(p.x - 0.34) - 0.10, abs(p.y - 0.02) - 0.30), 0.0);
            gearC = step(sdSeg(p, float2(0.18, 0.30), float2(0.62, 0.78)), 0.05);
        } else if (shape == 1) {
            float r = length(p - float2(0.42, 0.05));
            gear = step(abs(r - 0.38), 0.045) * step(-0.15, p.x - 0.42);
            gearCol = wood;
            gearC = step(sdSeg(p, float2(0.42, -0.33), float2(0.42, 0.43)), 0.028);
        } else {
            gearC = step(sdSeg(p, float2(0.22, 0.10), float2(0.58, 0.66)), 0.055);
            gear = step(length((p - float2(0.66, 0.72)) * float2(1.0, 1.6)), 0.20);
        }
        cov = max(max(body, headC), max(gear, gearC));
        col = army;
        col = mix(col, skin, headC);
        if (shape != 1) {
            float helm = step(length(p - float2(0.0, 0.58)), 0.17) * step(0.52, p.y);
            col = mix(col, steel * 0.9, helm);
        }
        col = mix(col, gearCol, gear);
        col = mix(col, (shape == 1) ? wood : steel, gearC);
    }

    if (cov < 0.5) discard_fragment();

    float shade = 0.72 + 0.28 * smoothstep(-1.0, 1.0, p.y);
    shade *= 1.0 - 0.15 * smoothstep(0.0, 0.8, p.x * in.facing);
    col *= shade;
    col += float3(1.0, 0.95, 0.8) * in.flash * ((shape == 6) ? 0.15 : 0.6);
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
    float skill;       // ~1.0; individual competence, rolled at spawn
    float sizeMul;     // veterans stand a little taller
    float cooldown;
    float retarget;
    int target;
    float attackAnim;
    float bobPhase;
    float deathT;
    float seed;
    bool alive;
};

struct Shot {                      // arrow or flaming catapult ball
    simd_float3 pos, vel;          // (x, height, boardY)
    int army;
    int kind;                      // 0 arrow, 1 fireball
    bool alive;
};

struct Puff {
    simd_float2 pos;
    float y;
    simd_float2 vel;
    float vy;
    float age, life, size;
    int kind;
};

struct Splat {
    simd_float2 pos;
    float size, seed, age;
    float r, g, b;
    float alpha;
};

// --- Terrain features ---
struct Lake { simd_float2 pos; float radius, seed; };
struct Boulder { simd_float2 pos; float radius, seed; };
struct Tree { simd_float2 pos; float size, seed; simd_float4 tint; };
struct Grove { simd_float2 pos; float radius; };
struct Hill { simd_float2 pos; float radius, height; };   // height < 0 = valley

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
    id<MTLRenderPipelineState> _flatPipeline;
    id<MTLRenderPipelineState> _unitPipeline;
    id<MTLRenderPipelineState> _hudPipeline;
    id<MTLDepthStencilState> _depthWrite;
    id<MTLDepthStencilState> _depthTest;
    id<MTLDepthStencilState> _depthNone;

    id<MTLBuffer> _flatBuffers[kMaxInFlight];
    id<MTLBuffer> _unitBuffers[kMaxInFlight];
    id<MTLBuffer> _hudBuffers[kMaxInFlight];
    int _frameIndex;
    dispatch_semaphore_t _frameSemaphore;
    std::vector<FInstC> _flatScratch;
    std::vector<BInstC> _unitScratch;
    std::vector<BInstC> _hudScratch;

    // Game
    std::vector<Unit> _units;
    std::vector<Shot> _shots;
    std::vector<Puff> _puffs;
    std::vector<Splat> _splats;
    std::vector<Lake> _lakes;
    std::vector<Boulder> _boulders;
    std::vector<Tree> _trees;
    std::vector<Grove> _groves;
    std::vector<Hill> _hills;
    id<MTLBuffer> _groundMesh;
    NSUInteger _groundVertCount;
    std::vector<std::vector<int>> _grid;
    int _gridW, _gridH;
    float _cellSize;
    int _phase;
    int _selectedType;
    int _winner;
    std::mt19937 _rng;

    // Camera
    float _camYaw, _camPitch, _camZoom, _camZoomTarget, _shake;
    simd_float4x4 _viewProj;
    simd_float2 _camRightBoard;
    bool _haveVP;
    simd_float2 _lastPaint;

    // HUD hit rects, in view points (y-up): 0..4 unit buttons, 5 = FIGHT.
    CGRect _btnRects[6];
    float _hudTop;          // everything below this y is HUD

    double _startTime, _lastFrameTime;
    double _simAccum;
    float _smoothedFPS;
}

- (instancetype)initWithView:(MTKView *)view {
    if (!(self = [super init])) return nil;

    id<MTLDevice> device = view.device;
    _queue = [device newCommandQueue];
    view.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    view.clearColor = MTLClearColorMake(0.35, 0.42, 0.50, 1.0);

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

    d.colorAttachments[0].blendingEnabled = YES;
    d.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    d.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    d.vertexFunction = [library newFunctionWithName:@"flat_vertex"];
    d.fragmentFunction = [library newFunctionWithName:@"flat_fragment"];
    _flatPipeline = [device newRenderPipelineStateWithDescriptor:d error:&error];
    if (!_flatPipeline) { fprintf(stderr, "flat: %s\n", error.localizedDescription.UTF8String); return nil; }

    d.vertexFunction = [library newFunctionWithName:@"unit_vertex"];
    d.fragmentFunction = [library newFunctionWithName:@"unit_fragment"];
    _unitPipeline = [device newRenderPipelineStateWithDescriptor:d error:&error];
    if (!_unitPipeline) { fprintf(stderr, "unit: %s\n", error.localizedDescription.UTF8String); return nil; }

    d.vertexFunction = [library newFunctionWithName:@"hud_vertex"];
    _hudPipeline = [device newRenderPipelineStateWithDescriptor:d error:&error];
    if (!_hudPipeline) { fprintf(stderr, "hud: %s\n", error.localizedDescription.UTF8String); return nil; }

    MTLDepthStencilDescriptor *ds = [MTLDepthStencilDescriptor new];
    ds.depthCompareFunction = MTLCompareFunctionLess;
    ds.depthWriteEnabled = YES;
    _depthWrite = [device newDepthStencilStateWithDescriptor:ds];
    ds.depthWriteEnabled = NO;
    ds.depthCompareFunction = MTLCompareFunctionLessEqual;
    _depthTest = [device newDepthStencilStateWithDescriptor:ds];
    ds.depthCompareFunction = MTLCompareFunctionAlways;
    _depthNone = [device newDepthStencilStateWithDescriptor:ds];

    for (int i = 0; i < kMaxInFlight; i++) {
        _flatBuffers[i] = [device newBufferWithLength:kMaxFlats * sizeof(FInstC)
                                              options:MTLResourceStorageModeShared];
        _unitBuffers[i] = [device newBufferWithLength:kMaxBillboards * sizeof(BInstC)
                                              options:MTLResourceStorageModeShared];
        _hudBuffers[i] = [device newBufferWithLength:256 * sizeof(BInstC)
                                             options:MTLResourceStorageModeShared];
    }
    _frameIndex = 0;
    _frameSemaphore = dispatch_semaphore_create(kMaxInFlight);
    _flatScratch.reserve(kMaxFlats);
    _unitScratch.reserve(kMaxBillboards);
    _hudScratch.reserve(256);

    _cellSize = 2.5f;
    _gridW = (int)ceilf(kFieldW / _cellSize);
    _gridH = (int)ceilf(kFieldH / _cellSize);
    _grid.resize((size_t)_gridW * _gridH);

    // Tessellated ground mesh (board coords; the vertex shader displaces it
    // by the heightfield, so terrain rerolls need no mesh rebuild).
    {
        std::vector<float> verts;
        const float x0 = -60, x1 = 200, y0g = -45, y1g = 125, step = 3.0f;
        for (float y = y0g; y < y1g; y += step) {
            for (float x = x0; x < x1; x += step) {
                float xs[6] = {x, x + step, x + step, x, x + step, x};
                float ys[6] = {y, y, y + step, y, y + step, y + step};
                for (int k = 0; k < 6; k++) { verts.push_back(xs[k]); verts.push_back(ys[k]); }
            }
        }
        _groundVertCount = verts.size() / 2;
        _groundMesh = [device newBufferWithBytes:verts.data()
                                          length:verts.size() * sizeof(float)
                                         options:MTLResourceStorageModeShared];
    }

    _phase = kPhaseSetup;
    _selectedType = kInfantry;
    _winner = -1;
    _rng.seed(20250709);
    _camYaw = 0;
    _camPitch = 47.0f * (float)M_PI / 180.0f;
    _camZoom = 1.0f;
    _camZoomTarget = 1.0f;
    _shake = 0;
    _haveVP = false;
    _lastPaint = simd_make_float2(-1000, -1000);
    _hudTop = 0;
    [self generateTerrain:(unsigned)(CACurrentMediaTime() * 1000.0)];
    [self deployDefaultArmies];

    __unsafe_unretained WarSimRenderer *weakSelf = self;
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                          handler:^NSEvent *(NSEvent *event) {
        if (event.modifierFlags & NSEventModifierFlagCommand) return event;
        unsigned short c = event.keyCode;
        if (c == 18 || c == 19 || c == 20 || c == 21) { weakSelf->_selectedType = c - 18; return nil; }
        if (c == 23) { weakSelf->_selectedType = kCatapult; return nil; }   // '5'
        if (c == 49) { [weakSelf pressedFight]; return nil; }               // space
        if (c == 15) { [weakSelf resetField:YES]; return nil; }             // R
        if (c == 2)  { [weakSelf resetField:NO]; [weakSelf deployDefaultArmies]; return nil; } // D
        if (c == 17 && weakSelf->_phase == kPhaseSetup) {                   // T: reroll terrain
            [weakSelf generateTerrain:(unsigned)(CACurrentMediaTime() * 1000.0)];
            return nil;
        }
        if (c == 123 || c == 12) { weakSelf->_camYaw -= 0.12f; return nil; } // left / Q
        if (c == 124 || c == 14) { weakSelf->_camYaw += 0.12f; return nil; } // right / E
        if (c == 126) { weakSelf->_camPitch = std::min(weakSelf->_camPitch + 0.07f, 1.20f); return nil; }
        if (c == 125) { weakSelf->_camPitch = std::max(weakSelf->_camPitch - 0.07f, 0.45f); return nil; }
        return event;
    }];
    // Trackpad pinch = the natural MacBook zoom gesture.
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMagnify
                                          handler:^NSEvent *(NSEvent *event) {
        weakSelf->_camZoomTarget = std::clamp(
            weakSelf->_camZoomTarget / (1.0f + (float)event.magnification * 1.6f),
            0.22f, 1.75f);
        return event;
    }];
    // Two-finger scroll also zooms; precise (trackpad) deltas are gentler
    // than clicky mouse-wheel lines. The camera eases toward the target.
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
                                          handler:^NSEvent *(NSEvent *event) {
        float k = event.hasPreciseScrollingDeltas ? -0.0016f : -0.030f;
        weakSelf->_camZoomTarget = std::clamp(
            weakSelf->_camZoomTarget * expf((float)event.scrollingDeltaY * k),
            0.22f, 1.75f);
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
        if (event.type == NSEventTypeLeftMouseDown) {
            for (int b = 0; b < 6; b++) {
                if (CGRectContainsPoint(weakSelf->_btnRects[b], NSPointToCGPoint(pt))) {
                    if (b < 5) weakSelf->_selectedType = b;
                    else [weakSelf pressedFight];
                    return nil;
                }
            }
        }
        if (pt.y < weakSelf->_hudTop) return nil;   // clicks on the HUD bar never paint
        simd_float2 ndc = simd_make_float2((float)(pt.x / v.bounds.size.width) * 2.0f - 1.0f,
                                           (float)(pt.y / v.bounds.size.height) * 2.0f - 1.0f);
        simd_float2 board = [weakSelf unproject:ndc];
        BOOL erase = (event.type == NSEventTypeRightMouseDown ||
                      event.type == NSEventTypeRightMouseDragged);
        if (event.type == NSEventTypeLeftMouseDown)
            weakSelf->_lastPaint = simd_make_float2(-1000, -1000);
        [weakSelf paintAt:board erase:erase];
        return event;
    }];

    printf("WAR SIM v5\n"
           "  HUD or 1-5: Infantry / Archer / Cavalry / Berserker / Catapult\n"
           "  Click/drag: stamp squads (left half = RED, right half = BLUE)\n"
           "  Right-click erase · SPACE/FIGHT battle · R clear · D defaults\n"
           "  T: reroll terrain (lakes/forests/boulders, setup only)\n"
           "  Pinch or scroll: zoom · Arrows or Q/E: orbit · Up/Down: tilt\n");

    _startTime = CACurrentMediaTime();
    _lastFrameTime = _startTime;
    _simAccum = 0;
    _smoothedFPS = 60;
    return self;
}

// ---------------------------------------------------------------- Set-up ---

- (void)resetField:(BOOL)full {
    _units.clear();
    _shots.clear();
    _puffs.clear();
    if (full) _splats.clear();
    _phase = kPhaseSetup;
    _winner = -1;
}

// ---------------------------------------------------------------- Terrain ---

// CPU mirror of the shader's terrainH — keep in sync.
- (float)heightAt:(simd_float2)p {
    float h = 0;
    for (const Hill &hl : _hills) {
        simd_float2 d = p - hl.pos;
        float s = hl.radius * 0.5f;
        h += hl.height * expf(-simd_dot(d, d) / (2.0f * s * s));
    }
    for (const Lake &l : _lakes) {
        float dl = simd_distance(p, l.pos);
        float t = std::clamp((dl - l.radius * 0.95f) / (l.radius * 0.85f), 0.0f, 1.0f);
        h *= t * t * (3.0f - 2.0f * t);
    }
    return h;
}

- (simd_float2)gradAt:(simd_float2)p {
    const float e = 0.6f;
    return simd_make_float2(
        ([self heightAt:p + simd_make_float2(e, 0)] - [self heightAt:p - simd_make_float2(e, 0)]) / (2 * e),
        ([self heightAt:p + simd_make_float2(0, e)] - [self heightAt:p - simd_make_float2(0, e)]) / (2 * e));
}

- (BOOL)isBlockedAt:(simd_float2)p radius:(float)r {
    for (const Lake &l : _lakes)
        if (simd_distance(p, l.pos) < l.radius * 0.92f + r) return YES;
    for (const Boulder &b : _boulders)
        if (simd_distance(p, b.pos) < b.radius + r) return YES;
    return NO;
}

- (BOOL)inLake:(simd_float2)p {
    for (const Lake &l : _lakes)
        if (simd_distance(p, l.pos) < l.radius * 0.90f) return YES;
    return NO;
}

- (void)generateTerrain:(unsigned)seed {
    _lakes.clear();
    _boulders.clear();
    _trees.clear();
    _groves.clear();
    _hills.clear();
    std::mt19937 rng(seed);
    std::uniform_real_distribution<float> u01(0.0f, 1.0f);

    int nHills = 4 + (int)(u01(rng) * 4.0f);            // 4-7 hills/valleys
    for (int i = 0; i < nHills && i < 8; i++) {
        Hill h;
        h.pos = simd_make_float2(10.0f + 120.0f * u01(rng), 8.0f + 64.0f * u01(rng));
        h.radius = 12.0f + 14.0f * u01(rng);
        h.height = (u01(rng) < 0.35f) ? -(1.2f + 1.8f * u01(rng))
                                      : (1.6f + 2.8f * u01(rng));
        _hills.push_back(h);
    }

    int nLakes = 2 + (int)(u01(rng) * 2.0f);            // 2-3
    for (int i = 0; i < nLakes; i++) {
        Lake l;
        l.radius = 5.0f + 4.0f * u01(rng);
        for (int tries = 0; tries < 20; tries++) {
            l.pos = simd_make_float2(28.0f + 84.0f * u01(rng), 12.0f + 56.0f * u01(rng));
            bool clash = false;
            for (const Lake &o : _lakes)
                if (simd_distance(l.pos, o.pos) < l.radius + o.radius + 6.0f) clash = true;
            if (!clash) break;
        }
        l.seed = u01(rng);
        _lakes.push_back(l);
    }

    int nGroves = 3 + (int)(u01(rng) * 3.0f);           // 3-5
    for (int g = 0; g < nGroves; g++) {
        Grove gr;
        gr.radius = 6.0f + 5.0f * u01(rng);
        gr.pos = simd_make_float2(10.0f + 120.0f * u01(rng), 8.0f + 64.0f * u01(rng));
        _groves.push_back(gr);
        int nTrees = (int)(gr.radius * gr.radius * 0.55f);
        for (int t = 0; t < nTrees; t++) {
            float ang = u01(rng) * 6.2831853f;
            float rr = gr.radius * sqrtf(u01(rng));
            simd_float2 p = gr.pos + simd_make_float2(cosf(ang), sinf(ang)) * rr;
            if (p.x < 1 || p.x > kFieldW - 1 || p.y < 1 || p.y > kFieldH - 1) continue;
            if ([self isBlockedAt:p radius:0.3f]) continue;
            Tree tr;
            tr.pos = p;
            tr.size = 1.7f + 1.0f * u01(rng);
            tr.seed = u01(rng);
            float mixT = u01(rng);
            tr.tint = simd_make_float4(0.10f + 0.07f * mixT, 0.30f + 0.09f * mixT,
                                       0.09f + 0.04f * mixT, 1.0f);
            _trees.push_back(tr);
        }
    }

    int nBoulders = 10 + (int)(u01(rng) * 5.0f);        // 10-14
    for (int i = 0; i < nBoulders; i++) {
        Boulder b;
        b.radius = 0.8f + 1.1f * u01(rng);
        for (int tries = 0; tries < 20; tries++) {
            b.pos = simd_make_float2(6.0f + 128.0f * u01(rng), 6.0f + 68.0f * u01(rng));
            if (![self isBlockedAt:b.pos radius:b.radius + 1.0f]) break;
        }
        b.seed = u01(rng);
        _boulders.push_back(b);
    }

    // Evict any painted units now standing in water or rock.
    _units.erase(std::remove_if(_units.begin(), _units.end(), [self](const Unit &u) {
        return [self isBlockedAt:u.pos radius:kSpecs[u.type].radius];
    }), _units.end());

    printf("Terrain: %d lakes, %d groves (%d trees), %d boulders\n",
           (int)_lakes.size(), (int)_groves.size(), (int)_trees.size(),
           (int)_boulders.size());
}

- (void)spawnUnit:(int)type army:(int)army at:(simd_float2)pos {
    if ((int)_units.size() >= kMaxUnits) return;
    if ([self isBlockedAt:pos radius:kSpecs[type].radius]) return;   // no lakes/rocks
    std::uniform_real_distribution<float> u01(0.0f, 1.0f);
    Unit un = {};
    un.pos = pos;
    un.army = army;
    un.type = type;
    // Individual skill: triangular distribution around 1.0 (0.8 .. 1.2).
    // No two swordsmen are the same man: skill scales HP, damage, attack
    // speed, and archer accuracy; veterans render slightly bigger.
    un.skill = 0.8f + 0.2f * (u01(_rng) + u01(_rng));
    un.sizeMul = 0.88f + 0.35f * (un.skill - 0.8f);
    un.hp = kSpecs[type].hp * un.skill;
    un.cooldown = u01(_rng) * 0.5f;
    un.retarget = u01(_rng) * 0.3f;
    un.target = -1;
    un.bobPhase = u01(_rng) * 6.28f;
    un.seed = u01(_rng);
    un.alive = true;
    _units.push_back(un);
}

- (void)deployDefaultArmies {
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
        for (int c = 0; c < 3; c++)
            [self spawnUnit:kCatapult army:army
                         at:simd_make_float2(front - sgn * 12.0f, 25.0f + c * 15.0f)];
    }
}

- (simd_float2)unproject:(simd_float2)ndc {
    simd_float4x4 inv = simd_inverse(_viewProj);
    simd_float4 p0 = simd_mul(inv, simd_make_float4(ndc.x, ndc.y, 0.0f, 1.0f));
    simd_float4 p1 = simd_mul(inv, simd_make_float4(ndc.x, ndc.y, 1.0f, 1.0f));
    simd_float3 a = p0.xyz / p0.w, b = p1.xyz / p1.w;
    // Iterate the ray against the heightfield so painting lands on hills.
    float h = 0;
    simd_float2 board = simd_make_float2(0, 0);
    for (int it = 0; it < 3; it++) {
        float t = (fabsf(b.y - a.y) > 1e-6f) ? (a.y - h) / (a.y - b.y) : 0.0f;
        simd_float3 hit = a + (b - a) * t;
        board = simd_make_float2(hit.x, -hit.z);
        h = [self heightAt:board];
    }
    return board;
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
    if (simd_distance(board, _lastPaint) < 2.5f) return;
    _lastPaint = board;
    int army = board.x < 70.0f ? 0 : 1;
    float minX = army == 0 ? 2.0f : kNoMansMax;
    float maxX = army == 0 ? kNoMansMin : kFieldW - 2.0f;
    std::uniform_real_distribution<float> jit(-0.25f, 0.25f);
    // Catapults stamp a battery of 2; troops stamp a 4x4 squad.
    if (_selectedType == kCatapult) {
        for (int k = 0; k < 2; k++) {
            simd_float2 p = board + simd_make_float2(0, (k - 0.5f) * 3.2f);
            p.x = std::clamp(p.x, minX, maxX);
            p.y = std::clamp(p.y, 3.0f, kFieldH - 3.0f);
            [self spawnUnit:kCatapult army:army at:p];
        }
        return;
    }
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

- (void)pressedFight {
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

- (void)spawnPuffs:(simd_float2)pos y:(float)y kind:(int)kind count:(int)n
             speed:(float)spd size:(float)size {
    std::uniform_real_distribution<float> u01(0.0f, 1.0f);
    float ground = [self heightAt:pos];
    for (int k = 0; k < n; k++) {
        if (_puffs.size() >= (size_t)kPuffCap - 1)
            _puffs.erase(_puffs.begin(), _puffs.begin() + 200);
        Puff b;
        float ang = u01(_rng) * 6.2831853f;
        float s = spd * (0.4f + u01(_rng));
        b.pos = pos;
        b.y = ground + y + 0.4f * u01(_rng);   // absolute altitude
        b.vel = simd_make_float2(cosf(ang), sinf(ang)) * s;
        b.vy = (kind == kPuffSmoke || kind == kPuffFire)
                   ? 1.2f + 2.0f * u01(_rng)
                   : 1.5f + 2.0f * u01(_rng);
        b.age = 0;
        b.life = (kind == kPuffSmoke) ? 1.4f + 0.8f * u01(_rng)
                                      : 0.4f + 0.4f * u01(_rng);
        b.size = size * (0.7f + 0.6f * u01(_rng));
        b.kind = kind;
        _puffs.push_back(b);
    }
}

- (void)hurtUnit:(int)idx damage:(float)dmg knock:(simd_float2)knock {
    Unit &u = _units[idx];
    if (!u.alive) return;
    u.hp -= dmg;
    u.vel += knock;
    if (u.hp <= 0) {
        u.alive = false;
        u.deathT = 0.0001f;
        [self spawnPuffs:u.pos y:0.8f kind:kPuffBlood count:10 speed:2.4f size:0.30f];
        std::uniform_real_distribution<float> u01(0.0f, 1.0f);
        Splat s;
        s.pos = u.pos;
        s.size = 0.5f + 0.5f * u01(_rng) + kSpecs[u.type].radius;
        s.seed = u01(_rng);
        s.age = 0;
        s.r = 0.30f; s.g = 0.02f; s.b = 0.01f;
        s.alpha = 0.55f;
        _splats.push_back(s);
        if (_splats.size() > 1600) _splats.erase(_splats.begin(), _splats.begin() + 200);
    } else {
        [self spawnPuffs:u.pos y:0.8f kind:kPuffBlood count:3 speed:1.8f size:0.18f];
    }
}

- (void)explodeAt:(simd_float2)pos {
    // Area devastation, friendly fire included.
    for (size_t j = 0; j < _units.size(); j++) {
        if (!_units[j].alive) continue;
        float dd = simd_distance(_units[j].pos, pos);
        if (dd < kBoomKill) {
            [self hurtUnit:(int)j damage:9999
                     knock:(_units[j].pos - pos) * 3.0f];
        } else if (dd < kBoomRadius) {
            float f = 1.0f - (dd - kBoomKill) / (kBoomRadius - kBoomKill);
            simd_float2 dir = (_units[j].pos - pos) / dd;
            [self hurtUnit:(int)j damage:30.0f + 90.0f * f knock:dir * (6.0f * f)];
        }
    }
    [self spawnPuffs:pos y:0.6f kind:kPuffFire count:22 speed:5.0f size:0.85f];
    [self spawnPuffs:pos y:0.8f kind:kPuffSmoke count:14 speed:2.2f size:1.30f];
    [self spawnPuffs:pos y:0.5f kind:kPuffSpark count:14 speed:8.0f size:0.22f];
    [self spawnPuffs:pos y:0.3f kind:kPuffDust count:12 speed:4.0f size:0.60f];
    std::uniform_real_distribution<float> u01(0.0f, 1.0f);
    Splat s;
    s.pos = pos;
    s.size = kBoomRadius * 0.75f;
    s.seed = u01(_rng);
    s.age = 0;
    s.r = 0.05f; s.g = 0.045f; s.b = 0.04f;
    s.alpha = 0.75f;
    _splats.push_back(s);
    _shake = std::min(_shake + 0.55f, 1.2f);
}

- (void)simStep:(float)dt {
    for (Unit &u : _units) if (!u.alive && u.deathT > 0) u.deathT += dt;
    for (Puff &b : _puffs) {
        b.age += dt;
        b.pos += b.vel * dt;
        b.y += b.vy * dt;
        if (b.kind == kPuffSmoke) {
            b.vy += 1.5f * dt;                     // smoke rises
            b.vel *= expf(-1.5f * dt);
        } else {
            b.vy -= 9.8f * dt;
        }
        float g = [self heightAt:b.pos];
        if (b.y < g + 0.02f) b.y = g + 0.02f;
    }
    _puffs.erase(std::remove_if(_puffs.begin(), _puffs.end(),
                 [](const Puff &b) { return b.age >= b.life; }), _puffs.end());
    for (Splat &s : _splats) s.age += dt;
    _shake *= expf(-3.2f * dt);

    if (_phase != kPhaseBattle) return;

    [self rebuildGrid];
    std::uniform_real_distribution<float> u01(0.0f, 1.0f);

    for (size_t i = 0; i < _units.size(); i++) {
        Unit &u = _units[i];
        if (!u.alive) continue;
        const UnitSpec &spec = kSpecs[u.type];
        u.cooldown -= dt;
        u.attackAnim = std::max(0.0f, u.attackAnim - dt * ((u.type == kCatapult) ? 1.2f : 4.0f));
        u.retarget -= dt;
        if (u.retarget <= 0 ||
            u.target < 0 || u.target >= (int)_units.size() || !_units[u.target].alive) {
            u.target = [self findEnemyFor:(int)i];
            u.retarget = 0.25f + 0.1f * u01(_rng);
        }
        if (u.target < 0) continue;
        Unit &tgt = _units[u.target];
        simd_float2 d = tgt.pos - u.pos;
        float dist = simd_length(d);
        simd_float2 dir = dist > 1e-4f ? d / dist : simd_make_float2(1, 0);
        float reach = spec.reach + spec.radius + kSpecs[tgt.type].radius;

        // High ground extends an archer's reach; shooting uphill shortens it.
        float archerReach = kArcherRange;
        if (u.type == kArcher) {
            float hAdv = [self heightAt:u.pos] - [self heightAt:tgt.pos];
            archerReach = std::clamp(kArcherRange + hAdv * 3.0f, 18.0f, 36.0f);
        }
        bool archerShooting = (u.type == kArcher && dist < archerReach && dist > 4.0f);
        bool catShooting = (u.type == kCatapult && dist < kCatMaxRange && dist > kCatMinRange);

        simd_float2 want = simd_make_float2(0, 0);
        if (archerShooting || catShooting) {
            if (u.cooldown <= 0) {
                bool cat = (u.type == kCatapult);
                u.cooldown = (cat ? kCatReload : kArcherReload)
                             * (1.6f - 0.6f * u.skill) * (0.9f + 0.2f * u01(_rng));
                u.attackAnim = 1.0f;
                float flightSpeed = cat ? 16.0f : 28.0f;
                float T = std::clamp(dist / flightSpeed, cat ? 1.1f : 0.45f, cat ? 2.6f : 1.6f);
                simd_float2 aim = tgt.pos + tgt.vel * (T * 0.85f);
                // A skilled shooter groups tighter.
                float scatter = (cat ? dist * 0.06f : dist * 0.12f) * (2.0f - u.skill);
                aim += simd_make_float2(u01(_rng) - 0.5f, u01(_rng) - 0.5f) * scatter;
                Shot sh;
                sh.pos = simd_make_float3(u.pos.x,
                                          [self heightAt:u.pos] + (cat ? 1.8f : 1.3f),
                                          u.pos.y);
                simd_float2 flat = (aim - u.pos) / T;
                sh.vel = simd_make_float3(flat.x, 0.5f * 9.8f * T, flat.y);
                sh.army = u.army;
                sh.kind = cat ? 1 : 0;
                sh.alive = true;
                _shots.push_back(sh);
            }
        } else if (dist > reach) {
            want = dir * spec.speed;
        } else {
            if (u.cooldown <= 0) {
                // Skill: better men swing harder and faster.
                u.cooldown = spec.cooldown * (1.6f - 0.6f * u.skill)
                             * (0.9f + 0.2f * u01(_rng));
                u.attackAnim = 1.0f;
                float dmg = spec.damage * u.skill;
                float knock = 2.0f;
                if (u.type == kCavalry && simd_length(u.vel) > kChargeSpeed) {
                    dmg *= kChargeMult;
                    knock = 5.0f;
                }
                dmg *= 0.85f + 0.3f * u01(_rng);
                [self hurtUnit:u.target damage:dmg knock:dir * knock];
                // impact juice at the victim
                [self spawnPuffs:tgt.pos y:0.9f kind:kPuffSpark count:3 speed:3.5f size:0.14f];
                [self spawnPuffs:tgt.pos y:0.3f kind:kPuffDust count:2 speed:1.5f size:0.30f];
            }
        }

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
                        push += dd / dl * ((minD - dl) / minD) * 7.0f;
                }
        want += push;

        u.vel += (want - u.vel) * std::min(6.0f * dt, 1.0f);

        // Forests slow troops down — horses worst of all.
        float terrainFactor = 1.0f;
        for (const Grove &g : _groves) {
            if (simd_distance(u.pos, g.pos) < g.radius) {
                terrainFactor = (u.type == kCavalry) ? 0.40f : 0.60f;
                break;
            }
        }
        // Slopes: trudging uphill is slow, downhill gives a push.
        float vlen = simd_length(u.vel);
        if (vlen > 0.2f) {
            float slope = simd_dot([self gradAt:u.pos], u.vel / vlen);
            terrainFactor *= std::clamp(1.0f - slope * 0.55f, 0.55f, 1.30f);
        }
        u.pos += u.vel * dt * terrainFactor;

        // Lakes and boulders are impassable: slide along their edge.
        for (const Lake &l : _lakes) {
            float R = l.radius * 0.92f + spec.radius;
            simd_float2 dl = u.pos - l.pos;
            float dd = simd_length(dl);
            if (dd < R) u.pos = l.pos + (dd > 1e-4f ? dl / dd : simd_make_float2(1, 0)) * R;
        }
        for (const Boulder &b : _boulders) {
            float R = b.radius + spec.radius;
            simd_float2 dl = u.pos - b.pos;
            float dd = simd_length(dl);
            if (dd < R) u.pos = b.pos + (dd > 1e-4f ? dl / dd : simd_make_float2(1, 0)) * R;
        }

        u.pos.x = std::clamp(u.pos.x, 0.5f, kFieldW - 0.5f);
        u.pos.y = std::clamp(u.pos.y, 0.5f, kFieldH - 0.5f);
        u.bobPhase += simd_length(u.vel) * dt * 6.0f * terrainFactor;
    }

    // Shots: arrows + flaming balls.
    std::uniform_real_distribution<float> u01b(0.0f, 1.0f);
    for (Shot &a : _shots) {
        if (!a.alive) continue;
        a.vel.y -= 9.8f * dt;
        a.pos += a.vel * dt;
        if (a.kind == 1 && u01b(_rng) < dt * 22.0f) {   // flame trail
            [self spawnPuffs:simd_make_float2(a.pos.x, a.pos.z) y:a.pos.y
                        kind:kPuffFire count:1 speed:0.4f size:0.35f];
        }
        if (a.pos.y <= [self heightAt:simd_make_float2(a.pos.x, a.pos.z)]) {
            a.alive = false;
            simd_float2 hit = simd_make_float2(a.pos.x, a.pos.z);
            if ([self inLake:hit]) {
                // Splash — the water eats arrows and fireballs alike.
                int n = (a.kind == 1) ? 12 : 3;
                [self spawnPuffs:hit y:0.2f kind:kPuffSplash count:n speed:2.5f size:0.30f];
                if (a.kind == 1)
                    [self spawnPuffs:hit y:0.4f kind:kPuffSmoke count:5 speed:1.2f size:0.7f];
                continue;
            }
            if (a.kind == 1) {
                [self explodeAt:hit];
                continue;
            }
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
            if (best >= 0) {
                simd_float2 kd = simd_make_float2(a.vel.x, a.vel.z);
                float kl = simd_length(kd);
                [self hurtUnit:best damage:kArrowDamage
                         knock:(kl > 1e-4f ? kd / kl : simd_make_float2(0, 0)) * 1.2f];
            } else {
                [self spawnPuffs:hit y:0.1f kind:kPuffDust count:2 speed:1.0f size:0.22f];
            }
        }
    }
    _shots.erase(std::remove_if(_shots.begin(), _shots.end(),
                 [](const Shot &a) { return !a.alive; }), _shots.end());

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

// ------------------------------------------------------------------- HUD ---

- (void)pushHud:(float)cx cy:(float)cy hw:(float)hw hh:(float)hh
          shape:(float)shape color:(simd_float4)col flash:(float)flash
           seed:(float)seed facing:(float)facing {
    _hudScratch.push_back({cx, cy, 0, hw, hh, 0, shape, facing,
                           col.x, col.y, col.z, col.w, flash, seed, 0, 0});
}

// Converts a rect in view points (origin bottom-left) to NDC and pushes.
- (void)buildHUD:(MTKView *)view aliveRed:(int)aliveRed aliveBlue:(int)aliveBlue {
    _hudScratch.clear();
    float bw = (float)view.bounds.size.width;
    float bh = (float)view.bounds.size.height;
    auto toNDC = [&](float x, float y, float w, float h, float *ocx, float *ocy,
                     float *ohw, float *ohh) {
        *ocx = (x + w * 0.5f) / bw * 2.0f - 1.0f;
        *ocy = (y + h * 0.5f) / bh * 2.0f - 1.0f;
        *ohw = w / bw;
        *ohh = h / bh;
    };

    // Bottom bar: 5 unit buttons + FIGHT.
    const float btn = 74, gap = 12, fightW = 110;
    float totalW = 5 * btn + 4 * gap + 24 + fightW;
    float x0 = (bw - totalW) * 0.5f;
    float y0 = 14;
    _hudTop = y0 + btn + 10;

    for (int i = 0; i < 5; i++) {
        float x = x0 + i * (btn + gap);
        _btnRects[i] = CGRectMake(x, y0, btn, btn);
        float cx, cy, hw, hh;
        toNDC(x, y0, btn, btn, &cx, &cy, &hw, &hh);
        BOOL sel = (_selectedType == i);
        [self pushHud:cx cy:cy hw:hw hh:hh shape:10
                color:simd_make_float4(1, 1, 1, 1) flash:sel ? 1.0f : 0.0f
                 seed:0 facing:1];
        // The unit's own sprite as the icon (neutral grey army color).
        float iconScale = (i == kCavalry || i == kCatapult) ? 0.62f : 0.72f;
        float iconShape = (i == kCatapult) ? 6.0f : (float)i;
        [self pushHud:cx cy:cy hw:hw * iconScale hh:hh * iconScale
                shape:iconShape color:simd_make_float4(0.75f, 0.72f, 0.68f, 1)
                flash:0 seed:0 facing:1];
    }
    // FIGHT / rematch button.
    float fx = x0 + 5 * (btn + gap) + 24 - gap;
    _btnRects[5] = CGRectMake(fx, y0, fightW, btn);
    float cx, cy, hw, hh;
    toNDC(fx, y0, fightW, btn, &cx, &cy, &hw, &hh);
    BOOL battle = (_phase == kPhaseBattle);
    [self pushHud:cx cy:cy hw:hw hh:hh shape:10
            color:simd_make_float4(1, 1, 1, battle ? 0.35f : 1.0f)
            flash:(_phase != kPhaseBattle) ? 0.6f : 0.0f seed:0 facing:1];
    [self pushHud:cx cy:cy hw:hw * 0.45f hh:hh * 0.45f shape:11
            color:simd_make_float4(0.55f, 0.95f, 0.45f, battle ? 0.3f : 1.0f)
            flash:0 seed:0 facing:1];

    // --- Live scoreboard, top center: RED count | ratio bar | BLUE count.
    const float sbW = 400, sbH = 78;
    float sbx = (bw - sbW) * 0.5f, sby = bh - sbH - 10;
    {   // backing panel
        float cx, cy, hw, hh;
        toNDC(sbx, sby, sbW, sbH, &cx, &cy, &hw, &hh);
        [self pushHud:cx cy:cy hw:hw hh:hh shape:10
                color:simd_make_float4(1, 1, 1, 0.9f) flash:0 seed:0 facing:1];
    }
    auto pushNumber = [&](int value, float xAnchor, float y, simd_float4 col, bool leftAlign) {
        char buf[8];
        snprintf(buf, sizeof(buf), "%d", value);
        int n = (int)strlen(buf);
        const float dw = 22, dh = 32, dgap = 5;
        float x = leftAlign ? xAnchor : xAnchor - n * (dw + dgap);
        for (int i = 0; i < n; i++) {
            float ccx, ccy, chw, chh;
            toNDC(x + i * (dw + dgap), y, dw, dh, &ccx, &ccy, &chw, &chh);
            [self pushHud:ccx cy:ccy hw:chw hh:chh shape:12 color:col
                    flash:0 seed:(float)(buf[i] - '0') facing:1];
        }
    };
    float digitsY = sby + sbH - 44;
    pushNumber(aliveRed, sbx + sbW * 0.5f - 36, digitsY, kArmyColor[0] * 1.25f, false);
    pushNumber(aliveBlue, sbx + sbW * 0.5f + 36, digitsY, kArmyColor[1] * 1.45f, true);
    {   // center divider dot
        float cx, cy, hw, hh;
        toNDC(sbx + sbW * 0.5f - 3, digitsY + 12, 6, 6, &cx, &cy, &hw, &hh);
        [self pushHud:cx cy:cy hw:hw hh:hh shape:13
                color:simd_make_float4(0.8f, 0.8f, 0.8f, 0.9f) flash:0 seed:0 facing:1];
    }
    {   // live ratio bar: red share vs blue share of surviving troops
        int total = std::max(aliveRed + aliveBlue, 1);
        float barW = sbW - 48, barH = 10;
        float bx = sbx + 24, by = sby + 12;
        float redW = barW * (float)aliveRed / (float)total;
        float cx, cy, hw, hh;
        if (redW > 1) {
            toNDC(bx, by, redW, barH, &cx, &cy, &hw, &hh);
            [self pushHud:cx cy:cy hw:hw hh:hh shape:13
                    color:simd_make_float4(kArmyColor[0].x, kArmyColor[0].y,
                                           kArmyColor[0].z, 0.95f)
                    flash:0 seed:0 facing:1];
        }
        if (barW - redW > 1) {
            toNDC(bx + redW, by, barW - redW, barH, &cx, &cy, &hw, &hh);
            [self pushHud:cx cy:cy hw:hw hh:hh shape:13
                    color:simd_make_float4(kArmyColor[1].x, kArmyColor[1].y,
                                           kArmyColor[1].z, 0.95f)
                    flash:0 seed:0 facing:1];
        }
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

    // Orbit battle-cam with eased zoom and shake.
    _camZoom += (_camZoomTarget - _camZoom) * std::min(1.0f, dtRaw * 10.0f);
    float aspect = (float)(view.drawableSize.width / view.drawableSize.height);
    float fovy = 33.0f * (float)M_PI / 180.0f;
    float tanH = tanf(fovy * 0.5f);
    float distX = (kFieldW * 0.5f + 6.0f) / (tanH * aspect);
    float distZ = (kFieldH * 0.5f * sinf(_camPitch) + 10.0f) / tanH;
    float dist = std::max(distX, distZ) * _camZoom;
    simd_float3 target = simd_make_float3(kFieldW * 0.5f, 0, -kFieldH * 0.5f);
    simd_float3 orbit = simd_make_float3(sinf(_camYaw) * cosf(_camPitch),
                                         sinf(_camPitch),
                                         cosf(_camYaw) * cosf(_camPitch));
    simd_float3 eye = target + orbit * dist;
    simd_float3 fwd = simd_normalize(target - eye);
    simd_float3 right = simd_normalize(simd_cross(fwd, simd_make_float3(0, 1, 0)));
    simd_float3 up = simd_cross(right, fwd);
    if (_shake > 0.003f) {
        eye += right * (sinf(t * 51.0f) * _shake * 0.35f);
        eye += up * (cosf(t * 47.0f) * _shake * 0.25f);
        fwd = simd_normalize(target - eye);
        right = simd_normalize(simd_cross(fwd, simd_make_float3(0, 1, 0)));
        up = simd_cross(right, fwd);
    }
    simd_float4x4 proj = Perspective(fovy, aspect, 1.0f, dist * 4.0f + 100.0f);
    _viewProj = simd_mul(proj, LookAt(eye, right, up, fwd));
    _camRightBoard = simd_make_float2(right.x, -right.z);
    _haveVP = true;

    struct {
        simd_float4x4 viewProj;
        simd_float2 resolution;
        float time;
        float phase;
        simd_float2 camRight;
        float lakeCount;
        float hillCount;
        simd_float4 lakes[3];
        simd_float4 hills[8];
    } uni = {
        _viewProj,
        simd_make_float2((float)view.drawableSize.width, (float)view.drawableSize.height),
        t,
        (float)_phase,
        simd_make_float2(right.x, right.z),
        (float)std::min(_lakes.size(), (size_t)3),
        (float)std::min(_hills.size(), (size_t)8),
        {},
        {},
    };
    for (size_t i = 0; i < _lakes.size() && i < 3; i++)
        uni.lakes[i] = simd_make_float4(_lakes[i].pos.x, _lakes[i].pos.y,
                                        _lakes[i].radius, _lakes[i].seed);
    for (size_t i = 0; i < _hills.size() && i < 8; i++)
        uni.hills[i] = simd_make_float4(_hills[i].pos.x, _hills[i].pos.y,
                                        _hills[i].radius, _hills[i].height);

    dispatch_semaphore_wait(_frameSemaphore, DISPATCH_TIME_FOREVER);
    _flatScratch.clear();
    _unitScratch.clear();

    // ---- Terrain: shadows as decals, trees/boulders as billboards.
    for (const Tree &tr : _trees) {
        _flatScratch.push_back({tr.pos.x, tr.pos.y, tr.size * 0.42f, tr.size * 0.30f,
                                0, 0, 0.02f, 0.03f, 0.02f, 0.35f, 0, 0, 0, 0});
        _unitScratch.push_back({tr.pos.x, tr.pos.y, 0,
                                tr.size * 1.15f, tr.size * 2.0f, 0, 14, 1,
                                tr.tint.x, tr.tint.y, tr.tint.z, 1.0f,
                                0, tr.seed, 0, 0});
    }
    for (const Boulder &b : _boulders) {
        _flatScratch.push_back({b.pos.x, b.pos.y, b.radius * 1.25f, b.radius * 0.9f,
                                0, 0, 0.02f, 0.02f, 0.02f, 0.35f, 0, 0, 0, 0});
        float grey = 0.40f + 0.10f * b.seed;
        _unitScratch.push_back({b.pos.x, b.pos.y, -b.radius * 0.18f,
                                b.radius * 2.3f, b.radius * 1.9f, 0, 15, 1,
                                grey, grey * 0.98f, grey * 0.95f, 1.0f,
                                0, b.seed, 0, 0});
    }

    // ---- Flat decals.
    for (const Splat &s : _splats) {
        float fade = 1.0f - std::min(s.age / 30.0f, 1.0f);
        if (fade <= 0) continue;
        _flatScratch.push_back({s.pos.x, s.pos.y, s.size, s.size * 0.8f,
                                s.seed * 6.28f, 1,
                                s.r, s.g, s.b, s.alpha * fade,
                                s.seed, 0, 0, 0});
        if (_flatScratch.size() >= (size_t)kMaxFlats - 8) break;
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
        if (_flatScratch.size() >= (size_t)kMaxFlats - 8) break;
    }

    // ---- Unit + shot billboards.
    for (const Unit &u : _units) {
        if (!u.alive && (u.deathT <= 0 || u.deathT > 0.55f)) continue;
        const UnitSpec &spec = kSpecs[u.type];
        float speed = simd_length(u.vel);
        float bob = (u.alive && speed > 0.3f) ? fabsf(sinf(u.bobPhase)) * 0.07f : 0.0f;
        if (_phase == kPhaseDone && u.alive && _winner == u.army)
            bob = fabsf(sinf(t * 6.0f + u.bobPhase)) * 0.25f;
        float rot = 0, sink = 0;
        if (!u.alive) {
            float f = std::min(u.deathT / 0.55f, 1.0f);
            rot = (u.seed > 0.5f ? 1.0f : -1.0f) * f * 1.45f;
            sink = f * 0.25f;
        }
        // Face along the camera's screen-right axis toward the target.
        float facing;
        if (u.target >= 0 && u.target < (int)_units.size())
            facing = simd_dot(_units[u.target].pos - u.pos, _camRightBoard) >= 0 ? 1.0f : -1.0f;
        else
            facing = simd_dot(simd_make_float2(u.army == 0 ? 1.0f : -1.0f, 0),
                              _camRightBoard) >= 0 ? 1.0f : -1.0f;
        simd_float4 c = kArmyColor[u.army];
        // Sprite id: types 0-3 match shapes 0-3; the catapult sprite is 6.
        float sprite = (u.type == kCatapult) ? 6.0f : (float)u.type;
        _unitScratch.push_back({u.pos.x, u.pos.y, bob - sink,
                                spec.width * u.sizeMul, spec.height * u.sizeMul, rot,
                                sprite, facing,
                                c.x, c.y, c.z, 1.0f,
                                u.attackAnim, u.seed, 0, 0});
        if ((int)_unitScratch.size() >= kUnitCap) break;
    }
    for (const Shot &a : _shots) {
        if ((int)_unitScratch.size() >= kUnitCap) break;
        simd_float3 v3 = simd_make_float3(a.vel.x, a.vel.y, -a.vel.z);
        float sx = simd_dot(v3, right);
        float sy = simd_dot(v3, up);
        float rot = atan2f(sy, sx);
        // Shot altitude is absolute; the vertex shader adds terrain height,
        // so subtract it here.
        float g = [self heightAt:simd_make_float2(a.pos.x, a.pos.z)];
        if (a.kind == 0) {
            _unitScratch.push_back({a.pos.x, a.pos.z, a.pos.y - g - 0.35f,
                                    0.7f, 0.7f, rot, 4, 1,
                                    0.4f, 0.3f, 0.2f, 1.0f, 0, 0, 0, 0});
        } else {
            // Flaming ball: hot additive core + halo.
            _unitScratch.push_back({a.pos.x, a.pos.z, a.pos.y - g - 0.45f,
                                    0.9f, 0.9f, 0, 5, 1,
                                    1.6f, 0.65f, 0.15f, 0.9f, 0.0f, 0, 0, 0});
            _unitScratch.push_back({a.pos.x, a.pos.z, a.pos.y - g - 0.2f,
                                    0.4f, 0.4f, 0, 5, 1,
                                    1.9f, 1.5f, 0.9f, 1.0f, 0.0f, 0, 0, 0});
        }
    }

    id<MTLBuffer> flatBuf = _flatBuffers[_frameIndex];
    id<MTLBuffer> unitBuf = _unitBuffers[_frameIndex];
    id<MTLBuffer> hudBuf = _hudBuffers[_frameIndex];
    NSUInteger flatCount = _flatScratch.size();
    NSUInteger unitCount = _unitScratch.size();
    if (flatCount) memcpy([flatBuf contents], _flatScratch.data(), flatCount * sizeof(FInstC));
    if (unitCount) memcpy([unitBuf contents], _unitScratch.data(), unitCount * sizeof(BInstC));

    // ---- Particle billboards into the reserved tail of the unit buffer.
    _unitScratch.clear();
    for (const Puff &b : _puffs) {
        float f = 1.0f - b.age / b.life;
        float size = b.size * (b.kind == kPuffSmoke ? (1.0f + 2.0f * (1.0f - f)) : 1.0f);
        float occl, r, g, bl;
        switch (b.kind) {
            case kPuffBlood:  r = 0.45f; g = 0.02f; bl = 0.01f; occl = 0.85f; break;
            case kPuffDust:   r = 0.42f; g = 0.36f; bl = 0.27f; occl = 0.55f; break;
            case kPuffSpark:  r = 1.60f; g = 1.30f; bl = 0.55f; occl = 0.0f;  break;
            case kPuffFire:   r = 1.80f; g = 0.75f; bl = 0.18f; occl = 0.0f;  break;
            case kPuffSplash: r = 0.55f; g = 0.70f; bl = 0.85f; occl = 0.60f; break;
            default:          r = 0.13f; g = 0.12f; bl = 0.11f; occl = 0.75f; break;
        }
        float ground = [self heightAt:b.pos];
        _unitScratch.push_back({b.pos.x, b.pos.y, b.y - ground - size,
                                size * 2.0f, size * 2.0f, 0, 5, 1,
                                r, g, bl, f, occl, 0, 0, 0});
        if ((int)_unitScratch.size() >= kPuffCap) break;
    }
    NSUInteger puffCount = _unitScratch.size();
    const NSUInteger kPuffOffset = (NSUInteger)(kMaxBillboards - kPuffCap - 64) * sizeof(BInstC);
    if (puffCount)
        memcpy((char *)[unitBuf contents] + kPuffOffset,
               _unitScratch.data(), puffCount * sizeof(BInstC));

    // ---- HUD.
    int alive[2] = {0, 0};
    for (const Unit &u : _units) if (u.alive) alive[u.army]++;
    [self buildHUD:view aliveRed:alive[0] aliveBlue:alive[1]];
    NSUInteger hudCount = _hudScratch.size();
    if (hudCount) memcpy([hudBuf contents], _hudScratch.data(), hudCount * sizeof(BInstC));

    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [commands renderCommandEncoderWithDescriptor:pass];

    [enc setRenderPipelineState:_groundPipeline];
    [enc setDepthStencilState:_depthWrite];
    [enc setVertexBuffer:_groundMesh offset:0 atIndex:0];
    [enc setVertexBytes:&uni length:sizeof(uni) atIndex:1];
    [enc setFragmentBytes:&uni length:sizeof(uni) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
            vertexCount:_groundVertCount];

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
    if (puffCount) {
        [enc setRenderPipelineState:_unitPipeline];
        [enc setDepthStencilState:_depthTest];
        [enc setVertexBuffer:unitBuf offset:kPuffOffset atIndex:0];
        [enc setVertexBytes:&uni length:sizeof(uni) atIndex:1];
        [enc setFragmentBytes:&uni length:sizeof(uni) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                vertexCount:6 instanceCount:puffCount];
    }
    if (hudCount) {
        [enc setRenderPipelineState:_hudPipeline];
        [enc setDepthStencilState:_depthNone];
        [enc setVertexBuffer:hudBuf offset:0 atIndex:0];
        [enc setVertexBytes:&uni length:sizeof(uni) atIndex:1];
        [enc setFragmentBytes:&uni length:sizeof(uni) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                vertexCount:6 instanceCount:hudCount];
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

    NSString *state;
    if (_phase == kPhaseSetup)
        state = [NSString stringWithFormat:@"SETUP — %s", kSpecs[_selectedType].name];
    else if (_phase == kPhaseBattle)
        state = @"BATTLE";
    else
        state = _winner >= 0 ? (_winner == 0 ? @"RED WINS" : @"BLUE WINS")
                             : @"MUTUAL ANNIHILATION";
    view.window.title = [NSString stringWithFormat:
        @"08 — WAR SIM v5 ▸ RED %d vs BLUE %d ▸ %@ ▸ %.0f fps",
        alive[0], alive[1], state, _smoothedFPS];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

@end

int main() {
    return RunMetalApp(@"08 — WAR SIM", 1280, 760, ^(MTKView *view) {
        return (NSObject<MTKViewDelegate> *)[[WarSimRenderer alloc] initWithView:view];
    });
}
