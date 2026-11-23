const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);
const float4 Constants11 : register(c11);
const float4 Constants12 : register(c12);
const float4 Constants13 : register(c13);
const float4 Constants14 : register(c14);

sampler SkyLut : register(s0);
sampler Cirrus : register(s1);

#define FWD        Constants0.xyz
#define BRIGHTNESS Constants0.w
#define RIGHT_S    Constants1.xyz
#define HALF_H     Constants1.w
#define SUN_DIR    Constants2.xyz
#define DISC_COL   Constants3.xyz

#define CIRRUS_ORIGIN Constants11.xy
#define CIRRUS_HEIGHT Constants11.z
#define CIRRUS_ON     Constants11.w
#define CIRRUS_SUN_COL Constants12.xyz
#define FOG_START     Constants12.w
#define CIRRUS_AMB_COL Constants13.xyz
#define FOG_RANGE     Constants13.w
#define FOG_COL       Constants14.xyz
#define FOG_DENSITY   Constants14.w

#define R_EARTH 6371.0
#define EYE_H   0.2

#define SUN_DISC_COS 0.9997
#define EXPOSURE 1.2

#define CIRRUS_AXIS float2(0.9374, 0.3482)
#define CIRRUS_STRETCH float3(0.6, 0.3, 1.4)
#define CIRRUS_BASE (1.0 / 60000.0)
#define CIRRUS_BREAKUP (1.0 / 30000.0)
#define CIRRUS_BREAKUP_W 0.75
#define CIRRUS_AMOUNT 0.15
#define CIRRUS_SOFT 0.35
#define CIRRUS_LIGHT_STEP 600.0
#define CIRRUS_OPACITY 0.5
#define CIRRUS_HORIZON 0.03
#define CIRRUS_FADE 0.12
#define CIRRUS_LIT 0.6
#define CIRRUS_EDGE 2.0
#define CIRRUS_THICK 0.6
#define CIRRUS_G 0.6
#define CIRRUS_SUN 1.0
#define CIRRUS_SCATTER 0.15
#define CIRRUS_AMB 0.9

#include "include/sky_lut.hlsl"

struct PS_IN
{
	float2 uv : TEXCOORD0;
};

float hash12(float2 p)
{
	return frac(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

float2 cirrusCoord(float2 p)
{
	float2 r = float2(dot(p, CIRRUS_AXIS), dot(p, float2(-CIRRUS_AXIS.y, CIRRUS_AXIS.x)));

	return float2(r.x * CIRRUS_STRETCH.x + r.y * CIRRUS_STRETCH.y, r.y * CIRRUS_STRETCH.z);
}

float cirrusDensity(float b, float keep)
{
	return pow(smoothstep(CIRRUS_AMOUNT, CIRRUS_AMOUNT + CIRRUS_SOFT, b * b * keep), 1.5);
}

float hgPhase(float cosT, float g)
{
	float g2 = g * g;

	return (1.0 - g2) / pow(max(1.0 + g2 - 2.0 * g * cosT, 1e-3), 1.5);
}

float4 main(PS_IN i) : COLOR
{
	float2 ndc = float2(i.uv.x * 2.0 - 1.0, 1.0 - i.uv.y * 2.0);
	float3 up = normalize(cross(RIGHT_S, FWD)) * HALF_H;
	float3 dir = normalize(FWD + RIGHT_S * ndc.x + up * ndc.y);

	float cirrusT = CIRRUS_HEIGHT / max(dir.z, CIRRUS_HORIZON);
	float2 cq = cirrusCoord(CIRRUS_ORIGIN + dir.xy * cirrusT);
	float cBreak = tex2D(Cirrus, cq * CIRRUS_BREAKUP + float2(0.37, 0.71)).a;
	float cBase = tex2D(Cirrus, cq * CIRRUS_BASE).r;
	float cBaseSun = tex2D(Cirrus, (cq + cirrusCoord(SUN_DIR.xy * CIRRUS_LIGHT_STEP)) * CIRRUS_BASE).r;

	float3 col = tex2Dlod(SkyLut, float4(lutUV(dir), 0.0, 0.0)).rgb;
	float mu = dot(dir, SUN_DIR);

	float b = (R_EARTH + EYE_H) * dir.z;
	float c = (R_EARTH + EYE_H) * (R_EARTH + EYE_H) - R_EARTH * R_EARTH;
	bool ground = b < 0.0 && b * b - c > 0.0;
	if (!ground)
	{
		col += DISC_COL * smoothstep(SUN_DISC_COS - 0.0004, SUN_DISC_COS + 0.0002, mu);
	}

	col = 1.0 - exp(-max(col, 0.0) * EXPOSURE);

	col += (hash12(i.uv * 1024.0) - 0.5) * (1.0 / 255.0);

	float3 sky = max(col, 0.0) * BRIGHTNESS;

	[branch] if (CIRRUS_ON > 0.0 && dir.z > CIRRUS_HORIZON)
	{
		float keep = 1.0 - cBreak * CIRRUS_BREAKUP_W;
		float cd = cirrusDensity(cBase, keep);
		float cdSun = cirrusDensity(cBaseSun, keep);
		float a = sqrt(cd) * CIRRUS_OPACITY * saturate((dir.z - CIRRUS_HORIZON) / CIRRUS_FADE) * CIRRUS_ON;
		float lit = (CIRRUS_LIT + saturate(cd - cdSun) * CIRRUS_EDGE) * (1.0 - cd * cd * CIRRUS_THICK);
		float3 cirrusCol = CIRRUS_SUN_COL * lit * (CIRRUS_SUN + CIRRUS_SCATTER * hgPhase(mu, CIRRUS_G)) + CIRRUS_AMB_COL * CIRRUS_AMB;
		cirrusCol = lerp(cirrusCol, FOG_COL, saturate((cirrusT - FOG_START) / FOG_RANGE) * FOG_DENSITY);
		sky = lerp(sky, cirrusCol, a);
	}

	return float4(sky, 1.0);
}
