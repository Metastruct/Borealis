static const float3 WATER_ABSORB = float3(4.0, 1.5, 0.9) / 1000.0;

static const float WATER_MURK_MAX = 4.0;

float DecodeMurk(float encoded) {
    return encoded * WATER_MURK_MAX;
}

static const float3 WATER_SCATTER = float3(0.0, 0.05, 0.1);
static const float WATER_SCATTER_REF_LUMA = 0.3;

float3 WaterScatter(float3 zenithColor) {
    float luma = dot(zenithColor, float3(0.2126, 0.7152, 0.0722));
    return WATER_SCATTER * min(luma / WATER_SCATTER_REF_LUMA, 1.5);
}

static const float3 WATER_INSCATTER = float3(0.05, 0.28, 0.38);
static const float WATER_INSCATTER_DOWN = 0.35;
static const float WATER_INSCATTER_UP = 1.6;

float3 WaterInScatter(float3 zenithColor, float3 rayDir, float depthBelowSurface) {
    float luma = dot(zenithColor, float3(0.2126, 0.7152, 0.0722));
    float sky = min(luma / WATER_SCATTER_REF_LUMA, 1.5);
    float direction = lerp(WATER_INSCATTER_DOWN, WATER_INSCATTER_UP, rayDir.z * 0.5 + 0.5);
    float3 lightAtDepth = exp(-WATER_ABSORB * max(depthBelowSurface, 0.0));

    return WATER_INSCATTER * sky * direction * lightAtDepth;
}

float3 WaterAttenuate(float3 scene, float distance, float3 scatter) {
    float3 transmission = exp(-WATER_ABSORB * max(distance, 0.0));
    return scene * transmission + scatter * (1.0 - transmission);
}
