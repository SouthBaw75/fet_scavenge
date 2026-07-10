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
    float4 water;    // rgb = water body color (linear)
    float4 moon;     // xyz = direction to moon, w = night factor 0..1
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
    float  jac;     // Jacobian determinant: < ~0.6 means the crest is folding
};

// Gerstner waves (GPU Gems ch.1): points move in circles, so crests get
// sharp and troughs get flat — the shape that makes it read as ocean
// instead of rippling jelly. Deep-water dispersion: omega = sqrt(g*k),
// so long waves travel faster than short ones, like the real sea.
Wave gerstner(float2 xz, float time, float intensity) {
    float3 p = float3(xz.x, 0.0, xz.y);
    float3 n = float3(0.0, 1.0, 0.0);
    float ampSum = 0.0;
    float jxx = 1.0, jyy = 1.0, jxy = 0.0;   // horizontal-displacement Jacobian
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
        // Where the horizontal map compresses (det -> 0), the crest folds
        // over itself: that is where real whitecaps form.
        float qkas = Q * k * A * s;
        jxx -= qkas * D.x * D.x;
        jyy -= qkas * D.y * D.y;
        jxy -= qkas * D.x * D.y;
        ampSum += A;
    }
    Wave w;
    w.pos = p;
    w.normal = normalize(n);
    w.crest = p.y / ampSum;
    w.jac = jxx * jyy - jxy * jxy;
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

// The sun's light color: white-gold when high, deep orange-red as it sinks.
float3 sunTint(float elev) {
    float low = clamp(1.0 - abs(elev - 0.04) / 0.24, 0.0, 1.0);
    return mix(float3(1.0, 0.92, 0.75), float3(1.30, 0.42, 0.15), low);
}

// Time-of-day atmospheric sky. Everything derives from the sun's elevation:
// midday blue, golden-hour warmth, a full layered sunset (yellow -> orange ->
// pink -> purple climbing from the horizon), and violet dusk after the sun
// slips under. The water reflects all of it.
float3 skyColor(float3 rd, float3 sun, float time, float4 moon, float storm) {
    float sd = max(dot(rd, sun), 0.0);
    float elev = sun.y;
    float sunset = clamp(1.0 - abs(elev - 0.04) / 0.24, 0.0, 1.0);
    float dusk = smoothstep(0.02, -0.12, elev);
    float night = moon.w;

    float h = saturate(rd.y);
    float3 zenith = mix(float3(0.10, 0.28, 0.58),        // midday blue
                        float3(0.15, 0.10, 0.36),        // sunset blue-violet
                        sunset);
    zenith = mix(zenith, float3(0.035, 0.025, 0.10), dusk);   // indigo dusk
    zenith = mix(zenith, float3(0.008, 0.012, 0.030), night); // near-black night

    // Sunset bands: yellow at the waterline, up through orange and hot pink
    // into purple — strongest toward the sun's side of the sky.
    float azim = pow(saturate(dot(normalize(float3(rd.x, 0.0, rd.z) + 1e-4),
                                  normalize(float3(sun.x, 0.0, sun.z) + 1e-4))
                              * 0.5 + 0.5), 2.0);
    float3 band = mix(float3(1.25, 0.90, 0.35),          // yellow
                      float3(1.30, 0.50, 0.16),          // orange
                      smoothstep(0.0, 0.10, h));
    band = mix(band, float3(1.10, 0.36, 0.55), smoothstep(0.08, 0.24, h));  // pink
    band = mix(band, float3(0.46, 0.22, 0.60), smoothstep(0.20, 0.45, h));  // purple
    band *= 0.45 + 0.75 * azim;

    float3 haze = mix(float3(0.58, 0.68, 0.78), band, sunset);
    haze = mix(haze, float3(0.34, 0.13, 0.40) * (0.35 + 0.65 * azim), dusk);
    haze = mix(haze, float3(0.030, 0.042, 0.085), night);       // afterglow dies

    float horizon = pow(1.0 - h, 3.5);
    float3 col = mix(zenith, haze, horizon);

    // Overcast: storms grey the sky out and swallow the sun.
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = mix(col, lum * float3(0.80, 0.88, 1.00), storm * 0.55);
    col *= 1.0 - 0.35 * storm;

    float3 st = sunTint(elev);
    col += st * pow(sd, 9.0) * (0.45 + 1.10 * sunset)
              * (1.0 - night) * (1.0 - 0.8 * storm);            // aureole swells low
    col += st * pow(sd, 1400.0) * 60.0
              * smoothstep(-0.025, 0.015, elev)
              * (1.0 - 0.85 * storm);                           // disc hides in cloud

    // Stars: hashed points on the dome, twinkling, fading toward the horizon
    // haze. Drawn before the clouds so clouds drift in front of them.
    if (night > 0.02 && rd.y > 0.01) {
        float2 suv = rd.xz / (rd.y + 0.55) * 48.0;
        float2 cell = floor(suv);
        float hs = hash21(cell);
        if (hs > 0.80) {
            float2 sp = float2(hash21(cell + 3.1), hash21(cell + 7.7));
            float d = length(fract(suv) - sp);
            float tw = 0.72 + 0.28 * sin(time * (1.5 + hs * 5.0) + hs * 41.0);
            float bright = (hs - 0.80) / 0.20;
            float star = smoothstep(0.10, 0.0, d) * tw;
            col += float3(0.85, 0.92, 1.10) * star
                 * (0.25 + 1.9 * bright * bright)
                 * night * smoothstep(0.02, 0.25, rd.y);
        }
    }

    // The moon: cool disc + soft halo, rising as the night deepens.
    float md = max(dot(rd, moon.xyz), 0.0);
    col += float3(0.95, 0.98, 1.05) * pow(md, 4000.0) * 9.0 * night;
    col += float3(0.40, 0.50, 0.70) * pow(md, 24.0) * 0.35 * night;

    // Clouds: shadowed bases go purple at sunset, sunlit sides catch pink
    // and orange; everything dims into dusk.
    if (rd.y > 0.02) {
        float2 cuv = rd.xz / (rd.y + 0.14) * 0.55
                   + float2(time * 0.008, time * 0.003);
        float shape = fbm(cuv);
        // Storm cloud decks close in: lower coverage threshold, full ceiling.
        float cover = smoothstep(0.52 - 0.30 * storm, 0.74 - 0.28 * storm, shape);
        float detail = fbm(cuv * 2.7 + 11.0);
        float3 lit = mix(float3(1.08, 1.04, 0.98), float3(1.35, 0.52, 0.40), sunset);
        lit = mix(lit, float3(0.30, 0.20, 0.38), dusk);
        lit = mix(lit, float3(0.14, 0.17, 0.24), night);   // moon-grey
        float3 shad = mix(float3(0.52, 0.55, 0.60), float3(0.40, 0.22, 0.44), sunset);
        shad = mix(shad, float3(0.09, 0.07, 0.15), dusk);
        shad = mix(shad, float3(0.015, 0.020, 0.038), night);
        shad *= 1.0 - 0.35 * storm;                        // brooding storm bases
        float3 cloud = mix(shad, lit, detail * 0.6 + 0.4 * pow(sd, 2.0));
        cloud = mix(cloud, dot(cloud, float3(0.33, 0.34, 0.33)) * float3(0.85, 0.92, 1.0),
                    storm * 0.5);
        cloud += st * pow(sd, 6.0) * (0.35 + 0.5 * sunset) * (1.0 - night) * (1.0 - 0.8 * storm);
        cloud += float3(0.35, 0.42, 0.55) * pow(md, 8.0) * 0.5 * night;  // moonlit edges
        float fade = smoothstep(0.02, 0.15, rd.y);
        col = mix(col, cloud, cover * fade * 0.85);
    }
    return col;
}

// GGX microfacet lobe: the physically-based sun glitter on the water.
float D_GGX(float NoH, float a) {
    float a2 = a * a;
    float d = NoH * NoH * (a2 - 1.0) + 1.0;
    return a2 / (M_PI_F * d * d + 1e-6);
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
    float3 col = skyColor(rd, u.sun.xyz, u.sun.w, u.moon, u.water.w);
    return float4(col, 1.0);   // linear HDR; tonemap happens in the composite
}

// ---------------- Ocean pass: the displaced grid ----------------

struct OceanVSOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float  crest;
    float  jac;
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
    out.jac = w.jac;
    return out;
}

fragment float4 ocean_fragment(OceanVSOut in [[stage_in]],
                               constant Uniforms &u [[buffer(0)]]) {
    float time = u.sun.w;
    float3 sun = u.sun.xyz;
    float3 toCam = u.camPos.xyz - in.world;
    float dist = length(toCam);
    float3 V = toCam / dist;

    // Fine ripple detail, strongest near the camera (distant water reads
    // smooth, which is what stretches the sun's glitter path to the horizon).
    float detailAmp = 0.9 / (1.0 + dist * 0.04);
    float2 dp = in.world.xz * 1.3 + float2(time * 0.4, time * 0.25);
    float hC = fbm(dp);
    float hX = fbm(dp + float2(0.33, 0.0));
    float hZ = fbm(dp + float2(0.0, 0.33));
    float3 n = normalize(normalize(in.normal) +
                         float3(hC - hX, 0.0, hC - hZ) * detailAmp);

    // Fresnel: ~2% reflective looking straight down, a mirror at grazing angles.
    float fresnel = 0.02 + 0.98 * pow(1.0 - max(dot(n, V), 0.0), 5.0);

    // What the mirror sees.
    float3 R = reflect(-V, n);
    R.y = max(R.y, 0.03);
    float3 reflection = skyColor(normalize(R), sun, time, u.moon, u.water.w);

    // What's under the surface: deep water, plus light scattering through
    // the top of backlit crests. Both derive from the user's water color so
    // the hue stays coherent from depths to sunlit crest.
    float day = smoothstep(-0.05, 0.30, sun.y);   // ambient light fades at dusk
    float3 wc = u.water.rgb;
    float3 deep = wc * 0.35 * (0.30 + 0.70 * day);
    float scatter = pow(max(dot(-V, sun), 0.0), 3.0) * max(in.crest, 0.0);
    float3 body = deep + wc * 1.35 * scatter * 0.9 * (0.25 + 0.75 * day);

    float3 color = mix(body, reflection, fresnel);

    // Sun glitter: GGX microfacet lobe. Roughness grows with distance, so
    // near water sparkles and the path elongates toward the horizon.
    float alpha = clamp(0.035 + dist * 0.0022, 0.035, 0.30);
    float3 H = normalize(V + sun);
    float NoH = max(dot(n, H), 0.0);
    float NoL = max(dot(n, sun), 0.0);
    float spec = D_GGX(NoH, alpha) * 0.25;
    color += sunTint(sun.y) * spec * fresnel * NoL * 3.0;

    // Moonlight: a second, silver glitter path once night falls.
    float night = u.moon.w;
    if (night > 0.02) {
        float3 Hm = normalize(V + u.moon.xyz);
        float specM = D_GGX(max(dot(n, Hm), 0.0), alpha) * 0.25;
        color += float3(0.70, 0.80, 1.00) * specM * fresnel
               * max(dot(n, u.moon.xyz), 0.0) * 1.3 * night;
    }

    // Whitecaps where the surface FOLDS (Jacobian pinch), not where it's
    // merely high — foam hugs breaking crests the way real water does.
    float rough = clamp(u.misc.z, 0.25, 2.5);
    float fold = smoothstep(0.78, 0.30, in.jac / max(rough * 0.6 + 0.4, 0.6));
    float foamMask = fbm(in.world.xz * 0.9 + float2(time * 0.25, -time * 0.18));
    float trail = smoothstep(0.30, 0.85, in.crest * (0.5 + 0.5 * rough))
                * smoothstep(0.45, 0.8, foamMask) * 0.5;
    float foam = clamp(fold * (0.55 + 0.45 * foamMask) + trail, 0.0, 1.0);
    // Foam is lit by the sky: white at noon, warm at sunset, dim at dusk.
    float3 foamCol = float3(0.92, 0.95, 0.97) * (0.30 + 0.70 * day)
                   + sunTint(sun.y) * 0.12 * clamp(1.0 - abs(sun.y - 0.04) / 0.24, 0.0, 1.0);
    color = mix(color, foamCol, foam * 0.85);

    // Fade the far edge of the grid into the sky so it has no visible border.
    float3 rd = -V;
    float3 horizon = skyColor(normalize(float3(rd.x, 0.015, rd.z)), sun, time, u.moon, u.water.w);
    color = mix(color, horizon, smoothstep(60.0, 95.0, dist));

    // Rain fizz: drops peppering the surface as a fine, flickering sparkle.
    float rain = u.water.w;
    if (rain > 0.02) {
        float fizz = smoothstep(0.88, 1.0, vnoise(in.world.xz * 7.0 + float2(time * 3.1, time * 2.3)));
        color += float3(0.45, 0.52, 0.60) * fizz * rain * 0.30 * (0.3 + 0.7 * day);
    }

    return float4(color, 1.0);   // linear HDR; tonemap happens in the composite
}

// ---------------- HDR post chain: bright-pass, blur, composite ----------------

struct PostVSOut {
    float4 position [[position]];
    float2 uv;
};

vertex PostVSOut post_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    PostVSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

fragment float4 bright_fragment(PostVSOut in [[stage_in]],
                                texture2d<float> scene [[texture(0)]],
                                sampler smp [[sampler(0)]]) {
    float3 c = scene.sample(smp, in.uv).rgb;
    float luma = dot(c, float3(0.299, 0.587, 0.114));
    return float4(c * smoothstep(1.0, 2.2, luma), 1.0);
}

constant float kBlurW[5] = {0.227027, 0.194594, 0.121621, 0.054054, 0.016216};

fragment float4 blur_fragment(PostVSOut in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              sampler smp [[sampler(0)]],
                              constant float2 &dir [[buffer(0)]]) {
    float2 texel = 1.0 / float2(src.get_width(), src.get_height());
    float3 c = src.sample(smp, in.uv).rgb * kBlurW[0];
    for (int i = 1; i < 5; i++) {
        float2 o = dir * texel * float(i) * 1.5;
        c += src.sample(smp, in.uv + o).rgb * kBlurW[i];
        c += src.sample(smp, in.uv - o).rgb * kBlurW[i];
    }
    return float4(c, 1.0);
}

struct CompUni {
    float2 resolution;
    float time;
    float rain;
};

// Three parallax layers of wind-slanted rain streaks, screen space.
float rainStreaks(float2 uv, float aspect, float t, float rain) {
    float acc = 0.0;
    float slant = 0.16 + 0.05 * sin(t * 0.4);
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float dens = 70.0 + 55.0 * fi;               // far layers are denser
        float speed = 1.5 - 0.38 * fi;               // near layers fall faster
        float2 p = float2(uv.x * aspect + (1.0 - uv.y) * slant * (1.0 + 0.3 * fi),
                          uv.y);
        float gx = p.x * dens;
        float colId = floor(gx);
        float h = hash21(float2(colId, fi * 17.3 + 1.7));
        float phase = fract(p.y * (0.55 + 0.30 * fi) + t * speed + h * 19.7);
        float active = step(h, 0.22 + 0.30 * rain);  // heavier rain, more drops
        float d = abs(fract(gx) - 0.5);
        float width = smoothstep(0.10 - 0.02 * fi, 0.0, d);
        float len = smoothstep(0.34, 0.02, phase);
        acc += active * width * len * (0.50 - 0.13 * fi);
    }
    return acc * rain;
}

fragment float4 composite_fragment(PostVSOut in [[stage_in]],
                                   texture2d<float> scene [[texture(0)]],
                                   texture2d<float> bloom [[texture(1)]],
                                   sampler smp [[sampler(0)]],
                                   constant CompUni &cu [[buffer(0)]]) {
    float3 c = scene.sample(smp, in.uv).rgb;
    c += bloom.sample(smp, in.uv).rgb * 0.65;

    // Rain in front of everything, catching the scene's ambient light.
    if (cu.rain > 0.01) {
        float sceneLum = dot(c, float3(0.299, 0.587, 0.114));
        float lightScale = 0.25 + 1.4 * clamp(sceneLum, 0.0, 0.8);
        float r = rainStreaks(in.uv, cu.resolution.x / cu.resolution.y,
                              cu.time, cu.rain);
        c += float3(0.55, 0.62, 0.72) * r * 0.55 * lightScale;
    }

    float2 cc = in.uv - 0.5;
    c *= 1.0 - 0.30 * dot(cc, cc) * 2.0;     // gentle vignette
    c = tonemap(c);
    return float4(pow(c, float3(0.4545)), 1.0);
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
    simd_float4 water;
    simd_float4 moon;
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

// WMO weather codes -> how hard it's raining (0..1) and a display name.
static float RainForCode(int c) {
    if (c >= 95) return 1.0f;                       // thunderstorms
    if (c == 82) return 1.0f;
    if (c == 81) return 0.75f;
    if (c == 80) return 0.50f;                      // showers
    if (c == 85 || c == 86) return 0.6f;            // snow showers
    if (c >= 71 && c <= 77) return 0.5f;            // snow (rendered as rain)
    if (c == 65) return 1.0f;
    if (c == 63) return 0.70f;
    if (c == 61) return 0.45f;                      // rain
    if (c == 66 || c == 67) return 0.7f;            // freezing rain
    if (c >= 51 && c <= 57) return 0.30f;           // drizzle
    return 0.0f;
}

static const char *NameForCode(int c) {
    if (c == 0) return "clear";
    if (c == 1) return "mostly clear";
    if (c == 2) return "partly cloudy";
    if (c == 3) return "overcast";
    if (c == 45 || c == 48) return "fog";
    if (c >= 51 && c <= 57) return "drizzle";
    if (c == 61) return "light rain";
    if (c == 63) return "rain";
    if (c == 65) return "heavy rain";
    if (c == 66 || c == 67) return "freezing rain";
    if ((c >= 71 && c <= 77) || c == 85 || c == 86) return "snow";
    if (c >= 80 && c <= 82) return "showers";
    if (c >= 95) return "thunderstorm";
    return "unknown";
}

@interface OceanRenderer : NSObject <MTKViewDelegate>
- (instancetype)initWithView:(MTKView *)view;
@end

@implementation OceanRenderer {
    float _intensity;        // sea state: 0.2 calm .. 2.5 storm
    float _intensityShown;   // eased value actually sent to the GPU
    float _dayT;             // time of day: 0 = high noon .. 1 = dusk
    float _dayShown;         // eased value driving the sun
    simd_float3 _waterLinear; // water body color, linear space

    // LIVE mode: mirror the real time of day and the real weather outside.
    BOOL _live;
    double _lastFetch;
    float _liveWind;         // km/h
    float _liveRain;         // 0..1
    float _liveCloud;        // 0..1
    float _sunriseMin, _sunsetMin;   // local minutes since midnight, -1 unknown
    NSString *_liveCity;
    NSString *_liveCond;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _skyPipeline;
    id<MTLRenderPipelineState> _oceanPipeline;
    id<MTLRenderPipelineState> _brightPipeline;
    id<MTLRenderPipelineState> _blurPipeline;
    id<MTLRenderPipelineState> _compositePipeline;
    id<MTLDepthStencilState> _skyDepth;
    id<MTLDepthStencilState> _oceanDepth;
    id<MTLSamplerState> _sampler;
    id<MTLTexture> _sceneTex, _sceneDepth, _bloomA, _bloomB;
    double _startTime;
    FPSCounter _fps;
}

- (void)ensureTargets:(id<MTLDevice>)device size:(CGSize)size {
    NSUInteger w = (NSUInteger)size.width, h = (NSUInteger)size.height;
    if (w == 0 || h == 0) return;
    if (_sceneTex && _sceneTex.width == w && _sceneTex.height == h) return;

    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                           width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    _sceneTex = [device newTextureWithDescriptor:td];

    MTLTextureDescriptor *dd =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                           width:w height:h mipmapped:NO];
    dd.usage = MTLTextureUsageRenderTarget;
    dd.storageMode = MTLStorageModePrivate;
    _sceneDepth = [device newTextureWithDescriptor:dd];

    td.width = std::max<NSUInteger>(w / 4, 1);
    td.height = std::max<NSUInteger>(h / 4, 1);
    _bloomA = [device newTextureWithDescriptor:td];
    _bloomB = [device newTextureWithDescriptor:td];
}

- (instancetype)initWithView:(MTKView *)view {
    if (!(self = [super init])) return nil;

    id<MTLDevice> device = view.device;
    _queue = [device newCommandQueue];
    // The scene renders offscreen in HDR; the view only receives the final
    // tonemapped composite, so it needs no depth buffer of its own.

    std::string source = "#define GRID " + std::to_string(kGrid) +
                         "\n#define SPACING " + std::to_string(kSpacing) + "f\n" +
                         kShaderSource;
    id<MTLLibrary> library = CompileLibrary(device, source.c_str());
    if (!library) return nil;

    NSError *error = nil;

    // Scene pipelines target the HDR offscreen texture.
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

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

    // Post pipelines: bright-pass and blur in HDR, composite to the drawable.
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [library newFunctionWithName:@"post_vertex"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    pd.fragmentFunction = [library newFunctionWithName:@"bright_fragment"];
    _brightPipeline = [device newRenderPipelineStateWithDescriptor:pd error:&error];
    if (!_brightPipeline) {
        fprintf(stderr, "Bright pipeline error: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }
    pd.fragmentFunction = [library newFunctionWithName:@"blur_fragment"];
    _blurPipeline = [device newRenderPipelineStateWithDescriptor:pd error:&error];
    if (!_blurPipeline) {
        fprintf(stderr, "Blur pipeline error: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }
    pd.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    pd.fragmentFunction = [library newFunctionWithName:@"composite_fragment"];
    _compositePipeline = [device newRenderPipelineStateWithDescriptor:pd error:&error];
    if (!_compositePipeline) {
        fprintf(stderr, "Composite pipeline error: %s\n", error.localizedDescription.UTF8String);
        return nil;
    }

    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = MTLSamplerMinMagFilterLinear;
    sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    _sampler = [device newSamplerStateWithDescriptor:sd];

    MTLDepthStencilDescriptor *depthDesc = [MTLDepthStencilDescriptor new];
    depthDesc.depthCompareFunction = MTLCompareFunctionAlways;
    depthDesc.depthWriteEnabled = NO;
    _skyDepth = [device newDepthStencilStateWithDescriptor:depthDesc];

    depthDesc.depthCompareFunction = MTLCompareFunctionLess;
    depthDesc.depthWriteEnabled = YES;
    _oceanDepth = [device newDepthStencilStateWithDescriptor:depthDesc];

    _intensity = 1.0f;
    _intensityShown = 1.0f;
    _dayT = 0.72f;           // start in the golden hour (matches the old look)
    _dayShown = 0.72f;
    _waterLinear = simd_make_float3(0.06f, 0.31f, 0.46f);   // classic sea teal

    // Sea-state controls: up/down arrows (or +/-) adjust smoothly, 1-5 are
    // presets from glassy calm to full storm. C opens the color wheel.
    __unsafe_unretained OceanRenderer *weakSelf = self;
    __unsafe_unretained MTKView *weakView = view;
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                          handler:^NSEvent *(NSEvent *event) {
        if (event.modifierFlags & NSEventModifierFlagCommand) return event;
        // Only react to keys aimed at the ocean window (so typing hex values
        // into the color panel doesn't change the sea state).
        if (event.window != weakView.window) return event;
        unsigned short c = event.keyCode;
        if (c == 37) { [weakSelf toggleLive]; return nil; }   // L = live mode
        // Any manual sea/time key hands control back to you.
        BOOL manual = (c == 126 || c == 24 || c == 125 || c == 27 ||
                       (c >= 18 && c <= 23) || c == 25 || c == 26 || c == 28 ||
                       c == 29 || c == 123 || c == 124);
        if (manual && weakSelf->_live) {
            weakSelf->_live = NO;
            printf("LIVE mode OFF: manual controls restored.\n");
        }
        float &inten = weakSelf->_intensity;
        if (c == 126 || c == 24) { inten = std::min(inten * 1.15f, 2.5f); return nil; } // up / =
        if (c == 125 || c == 27) { inten = std::max(inten / 1.15f, 0.2f); return nil; } // down / -
        if (c == 18) { inten = 0.30f; return nil; }   // 1 glassy
        if (c == 19) { inten = 0.65f; return nil; }   // 2 light chop
        if (c == 20) { inten = 1.00f; return nil; }   // 3 default
        if (c == 21) { inten = 1.60f; return nil; }   // 4 heavy
        if (c == 23) { inten = 2.40f; return nil; }   // 5 storm
        if (c == 8) { [weakSelf openColorWheel]; return nil; }   // C
        // Time of day: left = earlier, later = right; 6-9 and 0 presets.
        float &day = weakSelf->_dayT;
        if (c == 123) { day = std::max(day - 0.05f, 0.0f); return nil; }  // ←
        if (c == 124) { day = std::min(day + 0.05f, 1.45f); return nil; } // →
        if (c == 22) { day = 0.05f; return nil; }     // 6 high noon
        if (c == 26) { day = 0.62f; return nil; }     // 7 golden hour
        if (c == 28) { day = 0.88f; return nil; }     // 8 sunset
        if (c == 25) { day = 1.00f; return nil; }     // 9 dusk
        if (c == 29) { day = 1.45f; return nil; }     // 0 NIGHT
        return event;
    }];
    _live = NO;
    _lastFetch = 0;
    _liveWind = 10;
    _liveRain = 0;
    _liveCloud = 0.3f;
    _sunriseMin = -1;
    _sunsetMin = -1;
    _liveCity = @"";
    _liveCond = @"";

    printf("Sea state: Up/Down (or +/-) adjust wave intensity, 1-5 presets.\n"
           "Time of day: Left/Right, or 6 noon · 7 golden · 8 sunset · 9 dusk · 0 night.\n"
           "Color: press C for the color wheel — the water re-tints live.\n"
           "LIVE: press L to mirror your real local time of day and weather.\n");

    _startTime = CACurrentMediaTime();
    return self;
}

// ---- LIVE mode: locate by IP, then pull current weather + sun times from
// Open-Meteo (free, no API key). Refreshes every 10 minutes while active.
- (void)fetchWeather {
    _lastFetch = CACurrentMediaTime();
    NSURLSession *session = [NSURLSession sharedSession];
    NSURL *ipURL = [NSURL URLWithString:@"https://ipapi.co/json/"];
    [[session dataTaskWithURL:ipURL completionHandler:
      ^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSDictionary *j = data ? [NSJSONSerialization JSONObjectWithData:data
                                                                 options:0 error:nil] : nil;
        if (![j isKindOfClass:[NSDictionary class]] || !j[@"latitude"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                printf("LIVE: could not determine location (offline?) — using defaults.\n");
            });
            return;
        }
        double lat = [j[@"latitude"] doubleValue];
        double lon = [j[@"longitude"] doubleValue];
        NSString *city = [j[@"city"] isKindOfClass:[NSString class]] ? j[@"city"] : @"";
        NSString *wu = [NSString stringWithFormat:
            @"https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f"
             "&current=weather_code,wind_speed_10m,cloud_cover"
             "&daily=sunrise,sunset&forecast_days=1&timezone=auto", lat, lon];
        [[session dataTaskWithURL:[NSURL URLWithString:wu] completionHandler:
          ^(NSData *d2, NSURLResponse *r2, NSError *e2) {
            NSDictionary *w = d2 ? [NSJSONSerialization JSONObjectWithData:d2
                                                                   options:0 error:nil] : nil;
            if (![w isKindOfClass:[NSDictionary class]] || !w[@"current"]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    printf("LIVE: weather fetch failed — using defaults.\n");
                });
                return;
            }
            NSDictionary *cur = w[@"current"];
            int code = [cur[@"weather_code"] intValue];
            float wind = [cur[@"wind_speed_10m"] floatValue];
            float cloud = [cur[@"cloud_cover"] floatValue] / 100.0f;
            float sr = -1, ss = -1;
            NSArray *sra = w[@"daily"][@"sunrise"], *ssa = w[@"daily"][@"sunset"];
            int hh, mm;
            if ([sra isKindOfClass:[NSArray class]] && sra.count &&
                sscanf([sra[0] UTF8String], "%*d-%*d-%*dT%d:%d", &hh, &mm) == 2)
                sr = hh * 60 + mm;
            if ([ssa isKindOfClass:[NSArray class]] && ssa.count &&
                sscanf([ssa[0] UTF8String], "%*d-%*d-%*dT%d:%d", &hh, &mm) == 2)
                ss = hh * 60 + mm;
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_liveWind = wind;
                self->_liveRain = RainForCode(code);
                self->_liveCloud = cloud;
                self->_sunriseMin = sr;
                self->_sunsetMin = ss;
                self->_liveCity = city;
                self->_liveCond = @(NameForCode(code));
                printf("LIVE: %s — %s, wind %.0f km/h, cloud %.0f%%, "
                       "sunrise %02d:%02d, sunset %02d:%02d\n",
                       city.UTF8String, NameForCode(code), wind, cloud * 100,
                       (int)sr / 60, (int)sr % 60, (int)ss / 60, (int)ss % 60);
            });
        }] resume];
    }] resume];
}

- (void)toggleLive {
    _live = !_live;
    if (_live) {
        printf("LIVE mode ON: mirroring your local time of day and weather.\n");
        [self fetchWeather];
    } else {
        printf("LIVE mode OFF: manual controls restored.\n");
    }
}

// The native macOS color panel, in wheel mode: live updates while dragging.
- (void)openColorWheel {
    NSColorPanel *panel = [NSColorPanel sharedColorPanel];
    panel.showsAlpha = NO;
    panel.mode = NSColorPanelModeWheel;
    panel.continuous = YES;
    panel.target = self;
    panel.action = @selector(waterColorChanged:);
    // Seed the panel with the current water color (linear -> sRGB).
    simd_float3 s = simd_make_float3(powf(_waterLinear.x, 1.0f / 2.2f),
                                     powf(_waterLinear.y, 1.0f / 2.2f),
                                     powf(_waterLinear.z, 1.0f / 2.2f));
    panel.color = [NSColor colorWithSRGBRed:s.x green:s.y blue:s.z alpha:1.0];
    [panel orderFront:nil];
}

- (void)waterColorChanged:(id)sender {
    NSColor *c = [[(NSColorPanel *)sender color]
                  colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!c) return;
    // sRGB -> linear, since the shader works in linear light.
    _waterLinear = simd_make_float3(powf((float)c.redComponent, 2.2f),
                                    powf((float)c.greenComponent, 2.2f),
                                    powf((float)c.blueComponent, 2.2f));
}

- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) return;

    float t = (float)(CACurrentMediaTime() - _startTime);
    float aspect = (float)(view.drawableSize.width / view.drawableSize.height);

    // LIVE mode: derive time-of-day from the wall clock against the real
    // sunrise/sunset, and sea/weather from the live conditions.
    if (_live) {
        if (CACurrentMediaTime() - _lastFetch > 600.0) [self fetchWeather];
        NSDateComponents *dc = [[NSCalendar currentCalendar]
            components:(NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond)
              fromDate:[NSDate date]];
        float nowMin = dc.hour * 60.0f + dc.minute + dc.second / 60.0f;
        float sr = _sunriseMin > 0 ? _sunriseMin : 6 * 60;
        float ss = _sunsetMin > 0 ? _sunsetMin : 20 * 60;
        float dayT;
        if (nowMin >= sr && nowMin <= ss) {
            // Daylight: sun arcs up to ~48 deg at solar noon.
            float f = (nowMin - sr) / std::max(ss - sr, 1.0f);
            float elevDeg = 48.0f * sinf(f * (float)M_PI);
            dayT = (48.0f - elevDeg) / 56.0f;
        } else {
            // Twilight into night: the sun sinks ~16 deg per hour after sunset.
            float after = nowMin > ss ? (nowMin - ss) : (sr - nowMin);
            float elevDeg = -std::min(after / 60.0f * 16.0f, 33.0f);
            dayT = (48.0f - elevDeg) / 56.0f;
        }
        _dayT = std::clamp(dayT, 0.0f, 1.45f);
        _intensity = std::clamp(0.35f + _liveWind * 0.035f, 0.25f, 2.5f);
        if (_liveRain > 0.8f) _intensity = std::max(_intensity, 1.3f);  // storm seas
    }

    // Glide toward the requested sea state / time of day so changes ease in.
    _intensityShown += (_intensity - _intensityShown) * 0.06f;
    _dayShown += (_dayT - _dayShown) * 0.05f;

    // Weather factors: manual mode ties overcast+rain to the sea state;
    // live mode uses the real cloud cover and precipitation.
    float autoStorm = std::clamp((_intensityShown - 1.45f) / 0.9f, 0.0f, 1.0f);
    float overcast = _live ? std::max(_liveCloud * 0.9f, _liveRain) : autoStorm;
    float rainAmt = _live ? _liveRain : autoStorm;

    // Sun path: ~48 degrees up at noon, below the horizon at dusk, deep under
    // at night, along a fixed azimuth (the camera sways across it).
    float elevA = (48.0f - 56.0f * _dayShown) * (float)M_PI / 180.0f;
    simd_float3 hdir = simd_normalize(simd_make_float3(0.8f, 0, 0.55f));
    simd_float3 sunDir = simd_normalize(simd_make_float3(hdir.x * cosf(elevA),
                                                         sinf(elevA),
                                                         hdir.z * cosf(elevA)));

    // The moon rises from the opposite quarter as night comes on.
    float night = std::clamp((_dayShown - 1.02f) / 0.30f, 0.0f, 1.0f);
    float moonElev = (6.0f + 30.0f * night) * (float)M_PI / 180.0f;
    simd_float3 mdir = simd_normalize(simd_make_float3(-0.30f, 0, 0.95f));
    simd_float3 moonDir = simd_normalize(simd_make_float3(mdir.x * cosf(moonElev),
                                                          sinf(moonElev),
                                                          mdir.z * cosf(moonElev)));

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
        .sun = simd_make_float4(sunDir, t),
        .misc = simd_make_float4((float)view.drawableSize.width,
                                 (float)view.drawableSize.height,
                                 _intensityShown, 0),
        .water = simd_make_float4(_waterLinear, overcast),
        .moon = simd_make_float4(moonDir, night),
    };

    [self ensureTargets:view.device size:view.drawableSize];
    if (!_sceneTex) return;

    id<MTLCommandBuffer> commands = [_queue commandBuffer];

    // 1) Scene in HDR: sky, then the displaced ocean grid.
    MTLRenderPassDescriptor *scenePass = [MTLRenderPassDescriptor renderPassDescriptor];
    scenePass.colorAttachments[0].texture = _sceneTex;
    scenePass.colorAttachments[0].loadAction = MTLLoadActionClear;
    scenePass.colorAttachments[0].storeAction = MTLStoreActionStore;
    scenePass.depthAttachment.texture = _sceneDepth;
    scenePass.depthAttachment.loadAction = MTLLoadActionClear;
    scenePass.depthAttachment.storeAction = MTLStoreActionDontCare;
    scenePass.depthAttachment.clearDepth = 1.0;
    {
        id<MTLRenderCommandEncoder> enc =
            [commands renderCommandEncoderWithDescriptor:scenePass];
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
    }

    // 2) Bright-pass into quarter-res A.
    MTLRenderPassDescriptor *bp = [MTLRenderPassDescriptor renderPassDescriptor];
    bp.colorAttachments[0].texture = _bloomA;
    bp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    bp.colorAttachments[0].storeAction = MTLStoreActionStore;
    {
        id<MTLRenderCommandEncoder> enc = [commands renderCommandEncoderWithDescriptor:bp];
        [enc setRenderPipelineState:_brightPipeline];
        [enc setFragmentTexture:_sceneTex atIndex:0];
        [enc setFragmentSamplerState:_sampler atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
    }

    // 3) Two blur iterations (H,V,H,V) for a wide soft halo.
    for (int p = 0; p < 4; p++) {
        MTLRenderPassDescriptor *pp = [MTLRenderPassDescriptor renderPassDescriptor];
        pp.colorAttachments[0].texture = (p % 2 == 0) ? _bloomB : _bloomA;
        pp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        pp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [commands renderCommandEncoderWithDescriptor:pp];
        [enc setRenderPipelineState:_blurPipeline];
        [enc setFragmentTexture:(p % 2 == 0) ? _bloomA : _bloomB atIndex:0];
        [enc setFragmentSamplerState:_sampler atIndex:0];
        simd_float2 dir = (p % 2 == 0) ? simd_make_float2(1, 0) : simd_make_float2(0, 1);
        [enc setFragmentBytes:&dir length:sizeof(dir) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
    }

    // 4) Composite: scene + bloom + rain, tonemap, gamma, vignette.
    {
        struct { simd_float2 resolution; float time; float rain; } compUni = {
            simd_make_float2((float)view.drawableSize.width,
                             (float)view.drawableSize.height),
            t,
            rainAmt,
        };
        id<MTLRenderCommandEncoder> enc =
            [commands renderCommandEncoderWithDescriptor:pass];
        [enc setRenderPipelineState:_compositePipeline];
        [enc setFragmentTexture:_sceneTex atIndex:0];
        [enc setFragmentTexture:_bloomA atIndex:1];
        [enc setFragmentSamplerState:_sampler atIndex:0];
        [enc setFragmentBytes:&compUni length:sizeof(compUni) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
    }

    [commands presentDrawable:drawable];
    [commands commit];

    const char *seaName = _intensity < 0.45f ? "glassy" :
                          _intensity < 0.85f ? "light chop" :
                          _intensity < 1.30f ? "moderate" :
                          _intensity < 2.00f ? "heavy" : "STORM";
    const char *dayName = _dayT < 0.25f ? "midday" :
                          _dayT < 0.55f ? "afternoon" :
                          _dayT < 0.78f ? "golden hour" :
                          _dayT < 0.95f ? "sunset" :
                          _dayT < 1.15f ? "dusk" : "night";
    if (_live) {
        _fps.tick(view.window, [NSString stringWithFormat:
            @"05 — Ocean ▸ LIVE %@%@%@ ▸ %s, sea x%.2f ▸ [L] manual",
            _liveCity, _liveCity.length ? @" — " : @"",
            _liveCond.length ? _liveCond : @"fetching…", dayName, _intensity]);
    } else {
        _fps.tick(view.window, [NSString stringWithFormat:
            @"05 — Ocean ▸ %s [←/→, 6-0] ▸ Sea x%.2f (%s) [↑/↓, 1-5] ▸ [C] color ▸ [L] live",
            dayName, _intensity, seaName]);
    }
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}

@end

int main() {
    return RunMetalApp(@"05 — Ocean", 1100, 650, ^(MTKView *view) {
        return (NSObject<MTKViewDelegate> *)[[OceanRenderer alloc] initWithView:view];
    });
}
