const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);

sampler SkyLut : register(s0);

#define FWD        Constants0.xyz
#define BRIGHTNESS Constants0.w
#define RIGHT_S    Constants1.xyz
#define HALF_H     Constants1.w
#define SUN_DIR    Constants2.xyz
#define DISC_COL   Constants3.xyz

#define R_EARTH 6371.0
#define EYE_H   0.2

#define SUN_DISC_COS 0.9997
#define EXPOSURE 1.2

#include "include/sky_lut.hlsl"

struct PS_IN
{
	float2 uv : TEXCOORD0;
};

float hash12(float2 p)
{
	return frac(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

float4 main(PS_IN i) : COLOR
{
	float2 ndc = float2(i.uv.x * 2.0 - 1.0, 1.0 - i.uv.y * 2.0);
	float3 up = normalize(cross(RIGHT_S, FWD)) * HALF_H;
	float3 dir = normalize(FWD + RIGHT_S * ndc.x + up * ndc.y);

	float3 col = tex2Dlod(SkyLut, float4(lutUV(dir), 0.0, 0.0)).rgb;

	float b = (R_EARTH + EYE_H) * dir.z;
	float c = (R_EARTH + EYE_H) * (R_EARTH + EYE_H) - R_EARTH * R_EARTH;
	bool ground = b < 0.0 && b * b - c > 0.0;
	if (!ground)
	{
		float mu = dot(dir, SUN_DIR);
		col += DISC_COL * smoothstep(SUN_DISC_COS - 0.0004, SUN_DISC_COS + 0.0002, mu);
	}

	col = 1.0 - exp(-max(col, 0.0) * EXPOSURE);

	col += (hash12(i.uv * 1024.0) - 0.5) * (1.0 / 255.0);

	return float4(max(col, 0.0) * BRIGHTNESS, 1.0);
}
