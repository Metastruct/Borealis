const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);

sampler NormalMap : register(s0);
sampler3D Noise : register(s1);

#include "include/water_waves.hlsl"
#include "include/water_optics.hlsl"

#define EYE_POS   Constants0.xyz
#define SURFACE_Z Constants0.w
#define SUN_DIR   Constants1.xyz
#define TIME      Constants1.w
#define MURK      Constants2.x
#define SUNLIT    Constants2.y

static const float3 SUN_COLOR    = float3(8.0, 7.0, 6.0);
static const float3 SUNSET_COLOR = float3(8.0, 3.5, 1.2);
#define SUN_DISC       500.0
#define SUN_HALO       0.08
#define SUN_WAVE_BEND  0.5
#define SUN_GLITTER    120.0
#define SUN_MAX_SLANT  400.0
#define RIPPLE_TEXELS  512.0
#define RIPPLE_BLUR_START 3.0
#define RIPPLE_BLUR_END   7.0

struct PS_IN
{
	float2 uv    : TEXCOORD0;
	float4 color : TEXCOORD1;
	float3 wpos  : TEXCOORD2;
	float4 spos  : TEXCOORD3;
};

float4 main(PS_IN i) : COLOR
{
	float3 ray = normalize(i.wpos - EYE_POS);
	float eyeDepth = max(SURFACE_Z - EYE_POS.z, 0.0);
	float surfaceDistance = eyeDepth / max(ray.z, 1e-3);

	float2 exitPos = (EYE_POS + ray * min(surfaceDistance, 50000.0)).xy;
	float footprint = sqrt(length(ddx(exitPos)) * length(ddy(exitPos)));

	float rippleLod = log2(max(footprint / (RIPPLE_TILE / RIPPLE_TEXELS), 1.0));
	float2 ripples = RippleSlopeLod(NormalMap, exitPos, TIME, rippleLod);
	float rippleResolved = 1.0 - smoothstep(RIPPLE_BLUR_START, RIPPLE_BLUR_END, rippleLod);

	float swellResolved = saturate(2.0 - 2.0 * footprint / (SWELL_TILE / 128.0));
	float h0 = SwellHeight(Noise, exitPos, TIME);
	float hx = SwellHeight(Noise, exitPos + float2(SWELL_EPSILON, 0.0), TIME);
	float hy = SwellHeight(Noise, exitPos + float2(0.0, SWELL_EPSILON), TIME);
	float2 swell = float2(hx - h0, hy - h0) / SWELL_EPSILON * swellResolved;

	float3 bentRay = normalize(ray + float3(-(swell + ripples * rippleResolved) * SUN_WAVE_BEND, 0.0));
	float sunAlignment = saturate(dot(bentRay, SUN_DIR));

	float unresolved = saturate((1.0 - rippleResolved) * 0.6 + (1.0 - swellResolved) * 0.4);
	float disc = lerp(SUN_DISC, SUN_GLITTER, unresolved);
	float spread = sqrt((disc + 2.0) / (SUN_DISC + 2.0));

	float3 sunColor = lerp(SUNSET_COLOR, SUN_COLOR, saturate(SUN_DIR.z * 4.0));
	float3 sunThroughWater = exp(-WATER_ABSORB * min(surfaceDistance, eyeDepth + SUN_MAX_SLANT) * MURK);
	float sunVisible = saturate((SUN_DIR.z + 0.02) * 25.0) * SUNLIT * (ray.z > 0.0 ? 1.0 : 0.0);

	float3 light = pow(sunAlignment, disc) * spread + SUN_HALO * pow(sunAlignment, 40.0);
	return float4(sunColor * light * sunThroughWater * sunVisible, 1.0);
}
