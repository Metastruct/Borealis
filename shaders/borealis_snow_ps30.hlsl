#include "include/common.hlsl"
#include "include/dynamic_lights.hlsl"
#include "include/local_lights.hlsl"

const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);

sampler CoverTex     : register(s0);
sampler WorldTex     : register(s1);
sampler DynamicTex   : register(s2);
sampler ProjectedTex : register(s3);

#define EYE        Constants0.xyz
#define FOG_MAX    Constants0.w
#define INTENSITY  Constants1.x
#define WORLD_K    Constants1.y
#define DYN_K      Constants1.z
#define FOG_START  Constants1.w
#define FILL       Constants2.xyz
#define FOG_END    Constants2.w
#define FOG_COLOR  Constants3.xyz

#define FADE_START   560.0
#define FADE_END     760.0
#define NEAR         20.0
#define Z_FADE_START 240.0
#define Z_FADE_END   400.0
#define COLUMN       24.0
#define COLUMNS      64.0
#define Z_MIN        -16384.0
#define Z_RANGE      32768.0
#define DEPTH_NEAR   40.0
#define HAZE         0.6
#define FAR_ALPHA    0.35

struct PS_IN
{
	float2 uv     : TEXCOORD0;
	float3 centre : TEXCOORD1;
	float2 info   : TEXCOORD2;
};

float4 main(PS_IN i) : COLOR
{
	float2 col = floor(i.centre.xy / COLUMN);
	float2 cuv = frac(col / COLUMNS) + 0.5 / COLUMNS;
	float2 c = tex2D(CoverTex, cuv).rg;
	float coverZ = (c.r * 65280.0 + c.g * 255.0) / 65535.0 * Z_RANGE + Z_MIN;

	float r = length(i.uv);
	float disc = 1.0 - smoothstep(0.3, 1.0, r);

	float dist = distance(i.centre, EYE);
	float fade = (1.0 - smoothstep(FADE_START, FADE_END, dist)) * smoothstep(NEAR * 0.3, NEAR, dist);
	fade *= 1.0 - smoothstep(Z_FADE_START, Z_FADE_END, abs(i.centre.z - EYE.z));

	float depth = smoothstep(DEPTH_NEAR, FADE_END, dist);
	fade *= lerp(1.0, FAR_ALPHA, depth);

	float fog = saturate((dist - FOG_START) / max(FOG_END - FOG_START, 1.0)) * FOG_MAX;
	float3 lit = FILL + LocalLight(WorldTex, DynamicTex, ProjectedTex, i.centre, coverZ, EYE.xy, WORLD_K, DYN_K);
	float3 color = lerp(lit, FOG_COLOR, max(fog, depth * HAZE));

	float a = i.centre.z >= coverZ - 1.0 ? disc * fade * i.info.x * i.info.y * INTENSITY : 0.0;

	return float4(color, a);
}
