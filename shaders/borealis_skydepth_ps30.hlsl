#include "include/slices.hlsl"

const float4 Constants0 : register(c0);

sampler Depth : register(s0);
sampler Sky   : register(s1);

#define TEXEL Constants0.xy

struct PS_IN
{
	float2 uv   : TEXCOORD0;
	float2 vpos : VPOS;
};

float4 main(PS_IN i) : COLOR
{
	float2 uv = (i.vpos + 0.5) * TEXEL;
	float depthSample = tex2D(Depth, uv).r;
	float sky = tex2D(Sky, uv).r;
	clip((IsSkyDepth(depthSample) && sky > 0.0) ? 1.0 : -1.0);

	return float4(sky, sky, sky, 1.0);
}
