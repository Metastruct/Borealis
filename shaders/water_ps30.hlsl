const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);

sampler Frame : register(s0);
sampler Depth : register(s1);
sampler NormalMap : register(s2);
sampler3D Noise : register(s3);

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
};

float4 ProjectToClip(float3 pos, PS_IN i) {
    return pos.x * i.row0 + pos.y * i.row1 + pos.z * i.row2 + i.row3;
}

float2 ClipToUV(float4 pixel) {
    return pixel.xy / pixel.w * float2(0.5, -0.5) + 0.5;
}

#include "include/water_waves.hlsl"
#include "include/slices.hlsl"
#include "include/water_optics.hlsl"

float3 WorldAbove(float2 lookupUV, float3 sky) {
    float edge = saturate(min(lookupUV.x, 1 - lookupUV.x) / 0.1) * saturate(min(lookupUV.y, 1 - lookupUV.y) / 0.1);

    return lerp(sky, tex2Dlod(Frame, float4(saturate(lookupUV), 0.0, 0.0)).rgb, edge);
}

float4 main(PS_IN i) : COLOR
{
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

    float flatFresnel = F0 + (1 - F0) * pow(1 - saturate(abs(viewDir.z)), 5);
    slope *= 1 - pow(flatFresnel, 8);

    float3 normal = normalize(float3(-slope.x, -slope.y, 1.0));
    float3 skyScatter = WaterScatter(ZENITH_COLOR);
    float sunUp = saturate(SUN_DIR.z * 10.0);

    float3 transmitted;
    float f;
    float3 reflectDir;
    float3 fallbackColor;

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
        float caustics = CausticLight(NormalMap, seabedPos, EYE_POS, i.wpos.z, SUN_DIR, TIME);
        bool seabedSky = abs(depth - DEPTH_SCALE) < SKY_DEPTH_TOLERANCE;
        frame.rgb *= seabedSky ? 1.0 : lerp(1.0, caustics, SUNLIT);

        transmitted = WaterAttenuate(frame.rgb, thickness * MURK, skyScatter);

        float cosTheta = saturate(dot(-viewDir, normal));
        f = F0 + (1 - F0) * pow(1 - cosTheta, 5);
        reflectDir = reflect(viewDir, normal);
        fallbackColor = lerp(HORIZON_COLOR, ZENITH_COLOR, saturate(reflectDir.z));
    } else {
        float2 wobble = -slope / i.spos.w * BELOW_REFRACTION;
        float3 bentDir = normalize(viewDir + float3(-slope * BELOW_SKY_BEND, 0.0));
        float3 sky = lerp(HORIZON_COLOR, ZENITH_COLOR, saturate(bentDir.z));
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
                float weight = fadeX * fadeY * (FROM_BELOW ? saturate(-reflectDir.z / BELOW_SSR_GRAZING) : 1.0);
                hit = true;
                float3 reflected = FROM_BELOW ? WaterAttenuate(projectedFrame.rgb, tFar * MURK, fallbackColor) : projectedFrame.rgb;
                hitColor = lerp(fallbackColor, reflected, weight);
                break;
            }
        }

        tPrev = t;
        t = t * stepFactor;
    }

    float3 color = lerp(transmitted, hitColor, f);
    if (!FROM_BELOW)
        color += SUN_COLOR * spec * f * sunUp * SUNLIT * (hit ? 0.0 : 1.0);

    return float4(color, ExactDepthAlpha(i.spos.w));
}
