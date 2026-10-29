#include "include/common.hlsl"

const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);

sampler MilkyWay : register(s0);

#define FWD      Constants0.xyz
#define TIME     Constants0.w
#define RIGHT_S  Constants1.xyz
#define HALF_H   Constants1.w
#define STARS    Constants2.y
#define MILKYWAY Constants2.z
#define TWINKLE  1.0
#define WORLD_UP float3(Constants2.x, Constants2.w, sqrt(saturate(1.0 - Constants2.x * Constants2.x - Constants2.w * Constants2.w)))
#define POLE     Constants3.xyz
#define AIRGLOW  Constants3.w

#define SPEED 0.06
#define MW_PI 3.14159265
#define MW_MAX 0.4

struct PS_IN { float2 uv : TEXCOORD0; };

float2 mwUV(float3 dir)
{
	float3 x = normalize(cross(POLE, float3(0.0, 0.0, 1.0)));
	float3 y = cross(POLE, x);
	float lon = atan2(dot(dir, y), dot(dir, x));

	return float2(lon / (2.0 * MW_PI) + 0.5, 0.5 - asin(clamp(dot(dir, POLE), -1.0, 1.0)) / MW_PI);
}

float hash31(float3 p)
{
	return frac(sin(dot(p, float3(12.9898, 78.233, 37.719))) * 43758.5453);
}

float3 starLayer(float3 dir, float cells, float density)
{
	float3 p = dir * cells;
	float3 c = floor(p);
	float h = hash31(c);

	if (h > density)
	{
		return 0.0;
	}

	float3 sp = c + 0.25 + 0.5 * float3(hash31(c + 11.1), hash31(c + 23.7), hash31(c + 37.3));
	sp = normalize(sp) * cells;
	float d = length(p - sp);

	float mag = pow(hash31(c + 51.3), 5.0);
	float r = 0.07 + 0.11 * mag;
	float core = saturate(1.0 - d / r);
	core *= core;
	float halo = mag * mag * 0.12 * saturate(1.0 - d / 0.45);

	float rate = 40.0 + floor(hash31(c + 63.9) * 4.0) * 10.0;
	float tw = 1.0 + TWINKLE * 0.4 * sin(TIME * SPEED * rate + h * 61.0);

	float3 tint = lerp(float3(1.0, 0.78, 0.55), float3(0.65, 0.8, 1.0), hash31(c + 71.7));
	tint = lerp(float3(1.0, 1.0, 1.0), tint, 0.6);

	return tint * (core * (0.25 + 1.75 * mag) + halo) * tw;
}

float4 main(PS_IN i) : COLOR
{
	float2 ndc = float2(i.uv.x * 2.0 - 1.0, 1.0 - i.uv.y * 2.0);
	float3 up = normalize(cross(RIGHT_S, FWD)) * HALF_H;
	float3 dir = normalize(FWD + RIGHT_S * ndc.x + up * ndc.y);

	float elev = dot(dir, WORLD_UP);

	if (elev < 0.0)
	{
		return float4(0.0, 0.0, 0.0, 1.0);
	}

	float4 mw = tex2Dlod(MilkyWay, float4(mwUV(dir), 0.0, 0.0));
	float3 col = mw.rgb * mw.rgb * (MW_MAX * MILKYWAY);

	float3 st = starLayer(dir, 55.0, 0.22) * 1.6;
	st += starLayer(dir, 130.0, 0.18 + 0.5 * mw.a) * 0.75;
	col += st * STARS;

	float h = saturate(1.0 - elev);
	float3 haze = unpackColor(AIRGLOW) * 0.25 * pow(h, 5.0) * 0.14;

	col *= smoothstep(0.04, 0.38, elev);
	col += haze * smoothstep(0.0, 0.16, elev);

	return float4(col, 1.0);
}
