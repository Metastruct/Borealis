#include "include/common.hlsl"

const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);
const float4 Extra0 : register(c11);
const float4 Extra1 : register(c12);
const float4 Extra2 : register(c13);

sampler History : register(s0);
sampler3D Shape : register(s2);
sampler3D Detail : register(s3);

#define EYE      Constants0.xyz
#define LIGHT_P  Constants0.w
#define LUT_SIZE Constants1.xy
#define JITTER   Constants1.z
#define TIME     Constants1.w
#define SUN_DIR  Constants2.xyz
#define AMB_P    Constants2.w
#define BASE_Z   Constants3.x
#define FOG_HUE  Constants3.y
#define COVERAGE Constants3.z
#define FOG_RAMP Constants3.w

#define AMB_S    Extra0.x
#define LIGHT_S  Extra0.y
#define FOG_S    Extra0.z
#define SIDE     Extra0.w
#define HIST_REL Extra1.xyz
#define HIST_MID Extra1.w
#define HIST_W   Extra2.x

#define MAX_RANGE 150000.0
#define FADE_RANGE 90000.0

#define SHAPE_BLEND

#include "include/cloud_volume.hlsl"
#include "include/cloud_lut.hlsl"

#define STEPS 64

struct PS_IN
{
	float2 vpos : VPOS;
};

float4 march(float3 ray, float jitter)
{
	float top = BASE_Z + THICK;
	float t0, t1;
	if (abs(ray.z) < 1e-4)
	{
		bool inside = EYE.z > BASE_Z && EYE.z < top;
		t0 = 0.0;
		t1 = inside ? MAX_RANGE : -1.0;
	}
	else
	{
		float ta = (BASE_Z - EYE.z) / ray.z;
		float tb = (top - EYE.z) / ray.z;
		t0 = min(ta, tb);
		t1 = max(ta, tb);
	}

	t0 = max(t0, 0.0);
	t1 = min(t1, MAX_RANGE);
	if (t1 <= t0)
	{
		return 0.0;
	}

	float erode = ERODE;
	float3 sunCol = unpackColor(LIGHT_P) * decodeScale(LIGHT_S);
	float3 ambCol = unpackColor(AMB_P) * decodeScale(AMB_S);
	float3 fogCol = unpackColor(FOG_HUE) * decodeScale(FOG_S);
	float3 fog = unpackFog(FOG_RAMP);

	float3 phases = cloudPhases(dot(ray, SUN_DIR));

	float ds = (t1 - t0) / STEPS;

	float T = 1.0;
	float3 L = 0.0;

	for (int k = 0; k < STEPS; k++)
	{
		if (T < 0.02)
		{
			break;
		}

		float t = t0 + (k + jitter) * ds;
		float3 p = EYE + ray * t;
		float h = heightFraction(p);
		float cover = coverAt(p);
		float dens = cloudDensity(p, h, erode, cover);
		if (dens > 0.0)
		{
			dens *= saturate(remap(t, MAX_RANGE, FADE_RANGE, 0.0, 1.0));

			float sigma = dens * DENSITY;
			float a = 1.0 - exp(-sigma * ds);

			float beer = exp(-lightTau(p, erode, cover));
			float3 col = lerp(cloudLight(beer, sigma, dens, h, phases, sunCol, ambCol), fogCol, saturate((t - fog.x) / fog.y) * fog.z);

			L += col * a * T;
			T *= 1.0 - a;
		}
	}

	return float4(L, 1.0 - T);
}

float4 main(PS_IN i) : COLOR
{
	float3 ray = cloudLutDir((i.vpos + 0.5) / LUT_SIZE, SIDE);
	float jitter = frac(frac(sin(dot(i.vpos, float2(12.9898, 78.233))) * 43758.5453) + JITTER);
	float4 c = march(ray, jitter);

	float t = HIST_MID / ray.z;
	float3 q = t > 0.0 ? HIST_REL + ray * min(t, MAX_RANGE) : ray;
	float4 hist = tex2Dlod(History, float4(cloudLutUV(normalize(q), HIST_MID + HIST_REL.z > 0.0 ? 1.0 : -1.0), 0.0, 0.0));

	return lerp(c, hist, HIST_W);
}
