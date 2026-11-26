const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);
const float4 Constants11 : register(c11);
const float4 Constants12 : register(c12);
const float4 Constants13 : register(c13);
const float4 Constants14 : register(c14);

sampler Frame : register(s0);
sampler Depth : register(s1);
sampler NormalMap : register(s2);
sampler3D Noise : register(s3);
sampler SkyLut : register(s4);
sampler CoverTex : register(s5);
sampler SkyWall : register(s6);
sampler Wakes : register(s7);

#define R_EARTH 6371.0
#define EYE_H   0.2
#define SKY_EXPOSURE 1.2
#define LUT_WEIGHT Constants1.w
#define LUT_SCALE  Constants3.w
#define RAIN       Constants11.x
#define OPENNESS   Constants11.y
#define FOG_DENSITY Constants11.z
#define FOG_FALLOFF Constants11.w
#define FOG_BASE    Constants12.x
#define FROZEN      (Constants12.y > 0.5)
#define BAKED_SUN   Constants13.xyz
#define LIGHT_SCALE Constants13.w
#define FILL        Constants14.x
#define BRIGHTNESS  Constants14.y
#define INV_SCREEN  Constants12.zw
#define WAKE_EYE    Constants14.zw
#define FOG_RANGE   5000.0

#define WAKE_LEVEL  512.0
#define WAKE_STRIDE 514.0
#define WAKE_ATLAS  1028.0
#define WAKE_LEVELS 4.0
#define WAKE_TEXEL  4.0
#define WAKE_REACH  824.0
#define WAKE_BLEND  0.7
#define WAKE_HEIGHT 8.4
#define WAKE_POM_RANGE 34.0
#define WAKE_POM_MAX 192.0
#define WAKE_POM_STEPS 16
#define WAKE_POM_REFINE 4
#define WAKE_POM_MIN 0.25
#define FOAM_BIAS   0.0078125
#define FOAM_LOW    0.6
#define FOAM_HIGH   2.0
#define FOAM_TILE   16.0
#define FOAM_CLUMP_TILE 96.0
#define FOAM_CLUMP_MIX  0.6
#define FOAM_FLOW   0.02
#define FOAM_SOFT   0.25
#define FOAM_SOFT_RANGE 1500.0
#define FOAM_MAX    0.85
#define FOAM_ALBEDO float3(0.45, 0.45, 0.45)
#define FOAM_NEUTRAL 0.6

#define ICE_CRACK_BIG 260.0
#define ICE_CRACK_FINE 90.0
#define ICE_CRACK_WIDTH 1.2
#define ICE_FINE_STRENGTH 0.5
#define ICE_GROOVE 0.25
#define ICE_WARP_TILE 900.0
#define ICE_WARP 20.0
#define ICE_JAG_TILE 60.0
#define ICE_JAG 5.0
#define ICE_CRACK_MASK_TILE 2600.0
#define ICE_CLOUD_TILE 1300.0
#define ICE_CLOUD_MIN 0.5
#define ICE_CLOUD_MAX 0.9
#define ICE_SCATTER 0.65
#define ICE_BUMP_TILE 700.0
#define ICE_BUMP 0.45
#define ICE_SSR 0.5
#define ICE_ROUGH_TILE 70.0
#define ICE_ROUGH 0.35
#define ICE_ROUGH_FADE float2(250.0, 900.0)
#define ICE_BUMP_FADE float2(900.0, 2500.0)
#define ICE_REFLECT 0.55
#define ICE_TINT float3(0.75, 0.88, 0.95)
#define ICE_WIND float2(0.9397, 0.3420)
#define ICE_WIND2 float2(0.7660, 0.6428)
#define ICE_DRIFT_ALONG 3000.0
#define ICE_DRIFT_ACROSS 700.0
#define ICE_GRAIN_TILE 450.0
#define ICE_COVER_TILE 7000.0
#define ICE_FROST_SPARSE 0.66
#define ICE_FROST_DENSE 0.38
#define ICE_FROST_SOFT 0.2
#define ICE_FROST_MAX 0.85
#define ICE_SHORE_DEPTH 24.0
#define ICE_ALBEDO float3(0.235, 0.24, 0.25)
#define ICE_CRACK_WHITE 0.4
#define FOG_AMBIENT 0.6

#define COVER_COLUMN 24.0
#define COVER_COLUMNS 64.0
#define COVER_RANGE 30.0
#define COVER_Z_MIN -16384.0
#define COVER_Z_RANGE 32768.0
#define COVER_MARGIN 2.0

struct PS_IN
{
	float2 uv    : TEXCOORD0;
	float4 color : TEXCOORD1;
	float3 wpos  : TEXCOORD2;
	float4 spos  : TEXCOORD3;
    float4 row0  : TEXCOORD4;
	float4 row1  : TEXCOORD5;
	float4 row2  : TEXCOORD6;
	float4 row3  : TEXCOORD7;
	float2 vpos  : VPOS;
};

float4 ProjectToClip(float3 pos, PS_IN i) {
    return pos.x * i.row0 + pos.y * i.row1 + pos.z * i.row2 + i.row3;
}

float2 ClipToUV(float4 pixel) {
    return pixel.xy / pixel.w * float2(0.5, -0.5) + 0.5;
}

#include "include/common.hlsl"
#include "include/water_waves.hlsl"
#include "include/slices.hlsl"
#include "include/skywall.hlsl"
#include "include/water_optics.hlsl"
#include "include/sky_lut.hlsl"
#include "include/rain_ripples.hlsl"
#include "include/fog_layer.hlsl"
#include "include/ice.hlsl"

float RainExposure(float3 pos, float3 eye) {
    float2 col = floor(pos.xy / COVER_COLUMN);
    float2 eyeCol = floor(eye.xy / COVER_COLUMN);
    if (max(abs(col.x - eyeCol.x), abs(col.y - eyeCol.y)) > COVER_RANGE - 1.0)
        return OPENNESS;

    float2 c = tex2Dlod(CoverTex, float4(frac(col / COVER_COLUMNS) + 0.5 / COVER_COLUMNS, 0.0, 0.0)).rg;
    float coverZ = (c.r * 65280.0 + c.g * 255.0) / 65535.0 * COVER_Z_RANGE + COVER_Z_MIN;

    return coverZ <= pos.z + COVER_MARGIN ? 1.0 : 0.0;
}

struct WakeSel {
    float k;
    float3 a;
    float3 b;
    float blend;
    float keep;
};

float3 WakeLevel(float k) {
    return float3(float2(fmod(k, 2.0), floor(k * 0.5)) * WAKE_STRIDE + 1.0, WAKE_TEXEL * exp2(k));
}

WakeSel WakeSelect(float2 p) {
    WakeSel w;
    float d = length(p - WAKE_EYE);
    w.k = max(ceil(log2(max(d, 1.0) / WAKE_REACH)), 0.0);
    float reach = WAKE_REACH * exp2(w.k);
    w.blend = smoothstep(reach * WAKE_BLEND, reach, d);
    w.keep = w.k < WAKE_LEVELS - 1.0 ? 1.0 : 0.0;
    w.a = WakeLevel(w.k);
    w.b = WakeLevel(min(w.k + 1.0, WAKE_LEVELS - 1.0));

    return w;
}

float4 WakeTap(float2 p, float3 level) {
    float2 u = frac(float2(p.x, -p.y) / (level.z * WAKE_LEVEL)) * WAKE_LEVEL;

    return tex2Dlod(Wakes, float4((level.xy + u) / WAKE_ATLAS, 0.0, 0.0));
}

float4 WakeLevelSample(float2 p, float3 level) {
    float4 s = WakeTap(p, level);
    float hx = WakeTap(p + float2(level.z, 0.0), level).r;
    float hy = WakeTap(p - float2(0.0, level.z), level).r;

    return float4(float2(hx - s.r, s.r - hy) * (WAKE_HEIGHT / level.z), s.r, s.a - FOAM_BIAS);
}

float4 Wake(float2 p, WakeSel w) {
    float4 wake = WakeLevelSample(p, w.a);
    [branch] if (w.blend > 0.0)
    {
        wake = lerp(wake, WakeLevelSample(p, w.b) * w.keep, w.blend);
    }

    return wake;
}

float WakeHeight(float2 p, WakeSel w) {
    float h = WakeTap(p, w.a).r;
    [branch] if (w.blend > 0.0)
    {
        h = lerp(h, WakeTap(p, w.b).r * w.keep, w.blend);
    }

    return clamp(h * WAKE_HEIGHT, -WAKE_POM_RANGE, WAKE_POM_RANGE);
}

float2 WakeParallax(float2 p, float3 viewDir, WakeSel w) {
    float reach = min(WAKE_POM_RANGE / max(-viewDir.z, 1e-3), WAKE_POM_MAX);
    float3 dir = viewDir * reach;
    float peak = max(abs(WakeHeight(p, w)), max(abs(WakeHeight(p - dir.xy, w)), abs(WakeHeight(p + dir.xy, w))));

    [branch] if (peak > WAKE_POM_MIN)
    {
        float s = 1.0;
        float sPrev = -1.0;
        [loop] for (int k = 0; k <= WAKE_POM_STEPS; k++)
        {
            float t = -1.0 + 2.0 * k / WAKE_POM_STEPS;
            if (dir.z * t <= WakeHeight(p + dir.xy * t, w))
            {
                s = t;
                break;
            }
            sPrev = t;
        }

        [loop] for (int r = 0; r < WAKE_POM_REFINE; r++)
        {
            float m = (sPrev + s) * 0.5;
            if (dir.z * m <= WakeHeight(p + dir.xy * m, w))
            {
                s = m;
            }
            else
            {
                sPrev = m;
            }
        }

        p += dir.xy * s;
    }

    return p;
}

float3 SkyColor(float3 dir, float3 horizon, float3 zenith) {
    float3 gradient = lerp(horizon, zenith, saturate(dir.z));
    float3 above = normalize(float3(dir.xy, max(dir.z, 1e-3)));
    float3 sky = 1.0 - exp(-max(tex2Dlod(SkyLut, float4(lutUV(above), 0.0, 0.0)).rgb, 0.0) * SKY_EXPOSURE);

    return lerp(gradient, sky * LUT_SCALE, LUT_WEIGHT);
}

float3 WorldAbove(float2 lookupUV, float3 sky) {
    float edge = saturate(min(lookupUV.x, 1 - lookupUV.x) / 0.1) * saturate(min(lookupUV.y, 1 - lookupUV.y) / 0.1);

    return lerp(sky, tex2Dlod(Frame, float4(saturate(lookupUV), 0.0, 0.0)).rgb, edge);
}

float3 IceColor(float3 baked, float3 normal, float3 albedo) {
    float share = length(BAKED_SUN);
    float3 sunDir = BAKED_SUN / max(share, 1e-4);
    float flatLight = share * saturate(sunDir.z) + (1.0 - share);
    float slopeLight = share * saturate(dot(normal, sunDir)) + (1.0 - share) * (0.5 + 0.5 * normal.z);
    float3 linearColor = max((baked * 2.0 * LIGHT_SCALE + unpackColor(FILL)) * (slopeLight / max(flatLight, 1e-3)) * BRIGHTNESS * albedo, 0.0);

    return linearColor <= 0.0031308 ? linearColor * 12.92 : 1.055 * pow(linearColor, 1.0 / 2.4) - 0.055;
}

float4 main(PS_IN i) : COLOR
{
    ClipSkyWall(SkyWall, i.vpos, INV_SCREEN, i.spos.w);
    float TIME = Constants0.x;
    float3 EYE_POS = Constants1.xyz;
    bool FROM_BELOW = EYE_POS.z < i.wpos.z;
    float MURK = DecodeMurk(i.color.r);
    float3 HORIZON_COLOR = Constants2.xyz;
    float3 ZENITH_COLOR = Constants0.yzw;
    float3 SUN_DIR = Constants3.xyz;
    float SUNLIT = Constants2.w;

    const float SKY_DEPTH_TOLERANCE = 2.0;
    const float SSR_MAX_DISTANCE = 32000.0;
    const float SSR_MIN_THICKNESS = 16.0;
    const float SSR_THICKNESS_RATIO = 0.03;
    const float3 SUN_COLOR = float3(8.0, 7.0, 6.0);
    const float SUN_SHINYNESS = 500.0;
    const float F0 = 0.02;
    const float SHORE_FADE = 16.0;

    float2 p = i.wpos.xy;

	float2 uv = ClipToUV(i.spos);
	uv += float2(abs(ddx(uv).x), abs(ddy(uv).y)) * 0.5;

    const float ABOVE_REFRACTION = 12.0;

    const float BELOW_REFRACTION = 16.0;
    const float BELOW_SKY_BEND = 0.5;
    const float BELOW_WINDOW_RADIUS = 740.0;
    const float BELOW_WINDOW_RADIUS_SURFACE = 2460.0;
    const float BELOW_WINDOW_SHRINK_DEPTH = 300.0;
    const float BELOW_WINDOW_OPEN = 0.05;
    const float BELOW_SHEET_OPACITY = 0.6;
    const float BELOW_SHEET_BRIGHTNESS = 1.0;
    const float BELOW_SSR_GRAZING = 0.15;

    float3 viewDir = normalize(i.wpos - EYE_POS);
    float2 slope = WaveSlope(NormalMap, Noise, p, TIME);
    float crack = 0.0;
    float cloud = 0.0;
    float frost = 0.0;
    [branch] if (FROZEN)
    {
        float2 warp = float2(IceNoise(Noise, p, ICE_WARP_TILE, 0.15), IceNoise(Noise, p, ICE_WARP_TILE, 0.85)) - 0.5;
        float2 jag = float2(IceNoise(Noise, p, ICE_JAG_TILE, 0.45), IceNoise(Noise, p, ICE_JAG_TILE, 0.65)) - 0.5;
        float3 big = IceCracks(p + warp * ICE_WARP + jag * ICE_JAG, ICE_CRACK_BIG);
        float3 fine = IceCracks(p + 37.0 + warp * ICE_WARP * 0.4 + jag * ICE_JAG * 0.5, ICE_CRACK_FINE);
        float bigMask = smoothstep(0.45, 0.6, IceNoise(Noise, p, ICE_CRACK_MASK_TILE, 0.3));
        float fineMask = smoothstep(0.5, 0.62, IceNoise(Noise, p, ICE_CRACK_MASK_TILE, 0.55));
        float bigLine = (1.0 - smoothstep(0.0, ICE_CRACK_WIDTH, big.x)) * bigMask;
        float fineLine = (1.0 - smoothstep(0.0, ICE_CRACK_WIDTH * 0.6, fine.x)) * ICE_FINE_STRENGTH * fineMask;
        crack = max(bigLine, fineLine);
        float dist = length(i.wpos - EYE_POS);
        float bump = ICE_BUMP * (1.0 - smoothstep(ICE_BUMP_FADE.x, ICE_BUMP_FADE.y, dist));
        float rough = ICE_ROUGH * (1.0 - smoothstep(ICE_ROUGH_FADE.x, ICE_ROUGH_FADE.y, dist));
        slope = (big.yz * bigLine + fine.yz * fineLine) * ICE_GROOVE + IceBump(Noise, p, ICE_BUMP_TILE, 0.61) * bump + IceBump(Noise, p, ICE_ROUGH_TILE, 0.07) * rough;
        cloud = IceNoise(Noise, p, ICE_CLOUD_TILE, 0.4);
        float2 drift = float2(dot(p, ICE_WIND) / ICE_DRIFT_ALONG, dot(p, float2(-ICE_WIND.y, ICE_WIND.x)) / ICE_DRIFT_ACROSS);
        float2 drift2 = float2(dot(p, ICE_WIND2) / (ICE_DRIFT_ALONG * ICE_GOLDEN), dot(p, float2(-ICE_WIND2.y, ICE_WIND2.x)) / (ICE_DRIFT_ACROSS * ICE_GOLDEN));
        float streak = saturate(0.5 + (tex3Dlod(Noise, float4(drift, 0.7, 0.0)).r + tex3Dlod(Noise, float4(drift2 + 0.53, 0.12, 0.0)).r - 1.0) * 0.7);
        float grain = IceNoise(Noise, p, ICE_GRAIN_TILE, 0.2);
        float coverage = IceNoise(Noise, p, ICE_COVER_TILE, 0.9);
        float threshold = lerp(ICE_FROST_SPARSE, ICE_FROST_DENSE, smoothstep(0.3, 0.7, coverage));
        frost = smoothstep(threshold, threshold + ICE_FROST_SOFT, streak + (grain - 0.5) * 0.3) * ICE_FROST_MAX;
    }

    float rainNear = RainNear(length(i.wpos - EYE_POS));
    float rain = 0.0;
    [branch] if (RAIN > 0.0 && !FROZEN)
    {
        rain = RAIN * RainExposure(i.wpos, EYE_POS);
        [branch] if (rain * rainNear > 0.0)
        {
            slope += RainRipples(p, rain, TIME) * rainNear;
        }
    }

    float wakeFoam = 0.0;
    float2 wakeP = p;
    WakeSel wakeSel = WakeSelect(p);
    [branch] if (!FROZEN && wakeSel.k < WAKE_LEVELS)
    {
        [branch] if (!FROM_BELOW) wakeP = WakeParallax(p, viewDir, wakeSel);
        float4 wake = Wake(wakeP, wakeSel);
        slope += wake.xy;
        wakeFoam = max(smoothstep(FOAM_LOW, FOAM_HIGH, wake.z), saturate(wake.w));
    }

    float flatFresnel = F0 + (1 - F0) * pow(1 - saturate(abs(viewDir.z)), 5);
    slope *= 1 - pow(flatFresnel, 8);

    float3 normal = normalize(float3(-slope.x, -slope.y, 1.0));
    float3 skyScatter = WaterScatter(ZENITH_COLOR);
    float sunUp = saturate(SUN_DIR.z * 10.0);

    float3 transmitted;
    float f;
    float3 reflectDir;
    float3 fallbackColor;
    float skyClear = 1.0;

    if (!FROM_BELOW) {
        float2 wobble = (normal.xy / i.spos.w) * ABOVE_REFRACTION;
        float4 frame = tex2D(Frame, uv + wobble);
        float depth = SceneDepth(tex2D(Depth, uv + wobble).r * DEPTH_SCALE, frame.a);
        float thickness = depth - i.spos.w;

        if (thickness < 0) {
            frame = tex2D(Frame, uv);
            depth = SceneDepth(tex2D(Depth, uv).r * DEPTH_SCALE, frame.a);
            thickness = depth - i.spos.w;
        }

        float3 seabedPos = EYE_POS + (i.wpos - EYE_POS) * (depth / i.spos.w);
        bool seabedSky = abs(depth - DEPTH_SCALE) < SKY_DEPTH_TOLERANCE;
        float caustics = CausticLight(NormalMap, seabedPos, EYE_POS, i.wpos.z, SUN_DIR, TIME);
        frame.rgb *= seabedSky || FROZEN ? 1.0 : lerp(1.0, caustics, SUNLIT);

        transmitted = WaterAttenuate(frame.rgb, thickness * MURK, skyScatter);
        [branch] if (FROZEN)
        {
            float3 scatter = IceColor(i.color.gba, float3(0.0, 0.0, 1.0), ICE_ALBEDO * ICE_SCATTER);
            transmitted = lerp(transmitted * ICE_TINT, scatter, lerp(ICE_CLOUD_MIN, ICE_CLOUD_MAX, cloud));
            frost = max(frost, 1.0 - saturate((i.wpos.z - seabedPos.z) / ICE_SHORE_DEPTH));
        }

        float cosTheta = saturate(dot(-viewDir, normal));
        f = (F0 + (1 - F0) * pow(1 - cosTheta, 5)) * saturate((i.wpos.z - seabedPos.z) / SHORE_FADE) * (FROZEN ? ICE_REFLECT : 1.0);
        reflectDir = reflect(viewDir, normal);
        skyClear = exp(-FogLayerDepth(FOG_DENSITY, FOG_BASE, FOG_FALLOFF, i.wpos.z, i.wpos.z + reflectDir.z * FOG_RANGE, FOG_RANGE));
        fallbackColor = lerp(HORIZON_COLOR * FOG_AMBIENT, SkyColor(reflectDir, HORIZON_COLOR, ZENITH_COLOR), skyClear);
    } else {
        float2 wobble = -slope / i.spos.w * BELOW_REFRACTION;
        float3 bentDir = normalize(viewDir + float3(-slope * BELOW_SKY_BEND, 0.0));
        float3 sky = SkyColor(bentDir, HORIZON_COLOR, ZENITH_COLOR);
        transmitted = WorldAbove(uv + wobble, sky);

        float eyeDepth = max(i.wpos.z - EYE_POS.z, 0.0);
        float radius = lerp(BELOW_WINDOW_RADIUS_SURFACE, BELOW_WINDOW_RADIUS, smoothstep(0.0, BELOW_WINDOW_SHRINK_DEPTH, eyeDepth));
        float horizontal = length(i.wpos.xy - EYE_POS.xy);
        float window = max(pow(saturate(horizontal / radius), 4), BELOW_WINDOW_OPEN);
        float grazing = saturate(1.0 - dot(viewDir, normal)) * window;
        f = lerp(BELOW_SHEET_OPACITY * window, 1.0, grazing);

        reflectDir = reflect(viewDir, -normal);
        fallbackColor = WaterInScatter(ZENITH_COLOR, viewDir, eyeDepth * MURK) * BELOW_SHEET_BRIGHTNESS;
    }

    float spec = pow(saturate(dot(reflectDir, SUN_DIR)), SUN_SHINYNESS);

    bool hit = false;
    float3 hitColor = fallbackColor;
    float stepFactor = pow(SSR_MAX_DISTANCE / 10.0, 1.0 / 31.0);
    float t = 10.0;
    float tPrev = 0.0;

    [loop]
    for (int step = 1; step <= 32; step++)
    {
        float3 P = i.wpos + reflectDir * t;
        float4 projected = ProjectToClip(P, i);
        float2 projectedUV = ClipToUV(projected);

        if (projectedUV.x < 0 || projectedUV.y < 0 || projectedUV.x > 1 || projectedUV.y > 1)
            break;

        float projectedDepth = tex2Dlod(Depth, float4(projectedUV, 0, 0)).r * DEPTH_SCALE;
        float behind = projected.w - projectedDepth;
        bool projectedSky = abs(projectedDepth - DEPTH_SCALE) < SKY_DEPTH_TOLERANCE;
        if (projectedDepth > 0 && projectedDepth < projected.w && behind < (t - tPrev) && !projectedSky)
        {
            float tNear = tPrev;
            float tFar = t;
            float farBehind = behind;
            float farDepth = projectedDepth;
            [unroll]
            for (int r = 1; r <= 5; r++)
            {
                float tMid = (tNear + tFar) * 0.5;
                float4 refinement = ProjectToClip(i.wpos + reflectDir * tMid, i);
                float2 refinementUV = ClipToUV(refinement);
                float refinementDepth = tex2Dlod(Depth, float4(refinementUV, 0.0, 0.0)).r * DEPTH_SCALE;

                if (refinementDepth < refinement.w && abs(refinementDepth - DEPTH_SCALE) >= SKY_DEPTH_TOLERANCE) {
                    tFar = tMid;
                    farBehind = refinement.w - refinementDepth;
                    farDepth = refinementDepth;
                } else {
                    tNear = tMid;
                }
            }

            if (farBehind < max(SSR_MIN_THICKNESS, farDepth * SSR_THICKNESS_RATIO)) {
                projectedUV = ClipToUV(ProjectToClip(i.wpos + reflectDir * tFar, i));

                float4 projectedFrame = tex2Dlod(Frame, float4(projectedUV, 0.0, 0.0));
                float fadeX = saturate(min(projectedUV.x, 1 - projectedUV.x) / 0.1);
                float fadeY = saturate(min(projectedUV.y, 1 - projectedUV.y) / 0.1);
                float weight = fadeX * fadeY * (FROM_BELOW ? saturate(-reflectDir.z / BELOW_SSR_GRAZING) : 1.0) * (FROZEN ? ICE_SSR : 1.0);
                hit = true;
                float3 reflected = FROM_BELOW ? WaterAttenuate(projectedFrame.rgb, tFar * MURK, fallbackColor) : lerp(HORIZON_COLOR * FOG_AMBIENT, projectedFrame.rgb, exp(-FogLayerDepth(FOG_DENSITY, FOG_BASE, FOG_FALLOFF, i.wpos.z, i.wpos.z + reflectDir.z * tFar, tFar)));
                hitColor = lerp(fallbackColor, reflected, weight);
                break;
            }
        }

        tPrev = t;
        t = t * stepFactor;
    }

    if (!FROM_BELOW && hit)
        f *= 1.0 - RainHeavy(rain) * (1.0 - rainNear) * RAIN_HEAVY_FAR_BLUR;

    float3 color = lerp(transmitted, hitColor, f * (1.0 - frost));
    if (!FROM_BELOW)
        color += SUN_COLOR * spec * f * (1.0 - frost) * sunUp * SUNLIT * skyClear * (hit ? 0.0 : 1.0);

    [branch] if (wakeFoam > 0.0 && !FROM_BELOW)
    {
        float coverage = wakeFoam;
        float soft = saturate(FOAM_SOFT + length(i.wpos - EYE_POS) / FOAM_SOFT_RANGE);
        float clumps = IceNoise(Noise, wakeP, FOAM_CLUMP_TILE, frac(TIME * FOAM_FLOW));
        float bubbles = IceNoise(Noise, wakeP, FOAM_TILE, frac(TIME * FOAM_FLOW + 0.5));
        float pattern = lerp(bubbles, clumps, FOAM_CLUMP_MIX);
        float edge = 1.0 - coverage;
        float foam = smoothstep(edge - soft * 0.5, edge + soft * 0.5, pattern) * sqrt(coverage);
        float3 lit = IceColor(i.color.gba, normal, FOAM_ALBEDO);
        lit = lerp(lit, dot(lit, float3(0.2126, 0.7152, 0.0722)), FOAM_NEUTRAL);
        color = lerp(color, lit, foam * FOAM_MAX);
    }

    [branch] if (FROZEN)
    {
        float3 white = IceColor(i.color.gba, normal, ICE_ALBEDO);
        color = lerp(color, white, crack * ICE_CRACK_WHITE);
        color = lerp(color, white, frost);
    }

    return float4(color, ExactDepthAlpha(i.spos.w));
}
