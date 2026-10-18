const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);

sampler CurLut : register(s0);
sampler PrevLut : register(s1);

#define FWD      Constants0.xyz
#define BLEND    Constants0.w
#define RIGHT_S  Constants1.xyz
#define HALF_H   Constants1.w
#define REL_CUR  Constants2.xyz
#define MID_CUR  Constants2.w
#define REL_PREV Constants3.xyz
#define MID_PREV Constants3.w

#define MAX_RANGE 150000.0

#include "include/cloud_lut.hlsl"

struct PS_IN
{
	float2 uv : TEXCOORD0;
};

float2 reproject(float3 dir, float3 rel, float midRel)
{
	float t = midRel / dir.z;
	float3 q = t > 0.0 ? rel + dir * min(t, MAX_RANGE) : dir;

	return cloudLutUV(normalize(q), midRel + rel.z > 0.0 ? 1.0 : -1.0);
}

float4 main(PS_IN i) : COLOR
{
	float2 ndc = float2(i.uv.x * 2.0 - 1.0, 1.0 - i.uv.y * 2.0);
	float3 up = normalize(cross(RIGHT_S, FWD)) * HALF_H;
	float3 dir = normalize(FWD + RIGHT_S * ndc.x + up * ndc.y);
	[branch] if (dir.z <= 0.0 && MID_CUR > 0.0 && MID_PREV > 0.0)
	{
		return 0.0;
	}

	float4 cur = tex2Dlod(CurLut, float4(reproject(dir, REL_CUR, MID_CUR), 0.0, 0.0));
	float4 prev = tex2Dlod(PrevLut, float4(reproject(dir, REL_PREV, MID_PREV), 0.0, 0.0));
	float4 c = lerp(prev, cur, BLEND);

	return float4(c.rgb / max(c.a, 1e-4), c.a);
}
