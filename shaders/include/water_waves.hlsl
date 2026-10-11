#define SWELL_TILE    2000.0
#define SWELL_HEIGHT  4.0
#define SWELL_DRIFT   (float2(27.0, 12.0) / 3600.0)
#define SWELL_EVOLVE  (30.0 / 3600.0)
#define SWELL_EPSILON 8.0
#define GUST_TILE    9000.0
#define GUST_DRIFT   (float2(8.0, -5.0) / 3600.0)
#define GUST_EVOLVE  (12.0 / 3600.0)
#define RIPPLE_TILE      (256.0 / 2.0)
#define RIPPLE_TILE_ROT  (256.0 / 1.3)
#define RIPPLE_DRIFT     (float2(180.0, 90.0) / 3600.0)
#define RIPPLE_DRIFT_ROT (float2(-108.0, 162.0) / 3600.0)
#define RIPPLE_STRENGTH  0.4
static const float2 WAVE_ROT = float2(0.7986, 0.6018);

float WaveNoise(sampler3D noise, float3 uvw) {
    return max((tex3Dlod(noise, float4(uvw, 0.0)).r - 0.25) * 2.2, 0.0);
}

float SwellHeight(sampler3D noise, float2 p, float time) {
    float n = WaveNoise(noise, float3(p / SWELL_TILE - time * SWELL_DRIFT, time * SWELL_EVOLVE));
    return SWELL_HEIGHT * n * n;
}

#define CAUSTIC_EPSILON    3.0
#define CAUSTIC_REFRACTION 0.25
#define CAUSTIC_MIN_SPREAD 0.25

float2 RippleSlope(sampler normalMap, float2 p, float time) {
    float2 pRot = float2(WAVE_ROT.x * p.x - WAVE_ROT.y * p.y, WAVE_ROT.y * p.x + WAVE_ROT.x * p.y);
    float2 ripple1 = tex2D(normalMap, p / RIPPLE_TILE + time * RIPPLE_DRIFT).rg * 2 - 1;
    float2 ripple2 = tex2D(normalMap, pRot / RIPPLE_TILE_ROT + time * RIPPLE_DRIFT_ROT).rg * 2 - 1;
    ripple2 = float2(WAVE_ROT.x * ripple2.x + WAVE_ROT.y * ripple2.y, -WAVE_ROT.y * ripple2.x + WAVE_ROT.x * ripple2.y);

    return (ripple1 + ripple2) * RIPPLE_STRENGTH;
}

float2 WaveSlope(sampler normalMap, sampler3D noise, float2 p, float time) {
    float swellFade = saturate(2.0 - 2.0 * length(fwidth(p)) / (SWELL_TILE / 128.0));
    float h0 = SwellHeight(noise, p, time);
    float hx = SwellHeight(noise, p + float2(SWELL_EPSILON, 0.0), time);
    float hy = SwellHeight(noise, p + float2(0.0, SWELL_EPSILON), time);
    float2 swell = float2(hx - h0, hy - h0) / SWELL_EPSILON * swellFade;

    float gust = WaveNoise(noise, float3(p / GUST_TILE + time * GUST_DRIFT, time * GUST_EVOLVE + 0.5));
    gust = lerp(0.3, 1.0, smoothstep(0.2, 0.8, gust));

    return swell + RippleSlope(normalMap, p, time) * gust;
}

float WaveCaustic(sampler normalMap, float2 p, float time, float depth) {
    float2 s0 = RippleSlope(normalMap, p, time);
    float2 sx = RippleSlope(normalMap, p + float2(CAUSTIC_EPSILON, 0.0), time);
    float2 sy = RippleSlope(normalMap, p + float2(0.0, CAUSTIC_EPSILON), time);
    float divergence = (sx.x - s0.x + sy.y - s0.y) / CAUSTIC_EPSILON;

    float spread = 1.0 - CAUSTIC_REFRACTION * depth * divergence;
    return 1.0 / max(abs(spread), CAUSTIC_MIN_SPREAD);
}

float2 RippleSlopeLod(sampler normalMap, float2 p, float time, float lod) {
    float2 pRot = float2(WAVE_ROT.x * p.x - WAVE_ROT.y * p.y, WAVE_ROT.y * p.x + WAVE_ROT.x * p.y);
    float2 ripple1 = tex2Dlod(normalMap, float4(p / RIPPLE_TILE + time * RIPPLE_DRIFT, 0.0, lod)).rg * 2 - 1;
    float2 ripple2 = tex2Dlod(normalMap, float4(pRot / RIPPLE_TILE_ROT + time * RIPPLE_DRIFT_ROT, 0.0, lod)).rg * 2 - 1;
    ripple2 = float2(WAVE_ROT.x * ripple2.x + WAVE_ROT.y * ripple2.y, -WAVE_ROT.y * ripple2.x + WAVE_ROT.x * ripple2.y);

    return (ripple1 + ripple2) * RIPPLE_STRENGTH;
}

float WaveCausticLod(sampler normalMap, float2 p, float time, float depth, float lod, float epsilon) {
    float2 s0 = RippleSlopeLod(normalMap, p, time, lod);
    float2 sx = RippleSlopeLod(normalMap, p + float2(epsilon, 0.0), time, lod);
    float2 sy = RippleSlopeLod(normalMap, p + float2(0.0, epsilon), time, lod);
    float divergence = (sx.x - s0.x + sy.y - s0.y) / epsilon;

    float spread = 1.0 - CAUSTIC_REFRACTION * depth * divergence;
    return 1.0 / max(abs(spread), CAUSTIC_MIN_SPREAD);
}

float3 UnderwaterSunDir(float3 sunDir) {
    return normalize(refract(-sunDir, float3(0.0, 0.0, 1.0), 1.0 / 1.333));
}

float2 SunEntryPoint(float3 pos, float surfaceZ, float3 underwaterSun) {
    return pos.xy + underwaterSun.xy * (surfaceZ - pos.z) / min(underwaterSun.z, -0.2);
}

#define CAUSTIC_STRENGTH   0.3
#define CAUSTIC_MAX_DEPTH  1200.0
#define CAUSTIC_PIXEL_FADE 6.0

float CausticLight(sampler normalMap, float3 worldPos, float3 eyePos, float surfaceZ, float3 sunDir, float time) {
    float depthBelow = max(surfaceZ - worldPos.z, 0.0);
    float3 facing = normalize(cross(ddx(worldPos), ddy(worldPos)));
    facing *= sign(dot(facing, eyePos - worldPos));

    float fade = saturate(dot(facing, sunDir)) * saturate(sunDir.z * 10.0)
        * saturate(1.0 - depthBelow / CAUSTIC_MAX_DEPTH)
        * saturate(1.0 - length(fwidth(worldPos.xy)) / CAUSTIC_PIXEL_FADE)
        * (worldPos.z < surfaceZ ? 1.0 : 0.0);

    float2 entry = SunEntryPoint(float3(worldPos.xy, min(worldPos.z, surfaceZ)), surfaceZ, -sunDir);
    float caustic = WaveCaustic(normalMap, entry, time, depthBelow);

    return 1.0 + CAUSTIC_STRENGTH * (caustic - 1.0) * fade;
}
