#include "include/api.hlsl"
#include "include/slices.hlsl"

const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);

sampler Frame : register(s0);
sampler Depth : register(s1);
sampler Occlusion : register(s2);

#define TEXEL    Constants0.xy
#define STRENGTH Constants0.z
#define DEBUG    Constants0.w
#define ZNEAR    Constants1.x
#define ZFAR     Constants1.y
#define AMBIENT  Constants1.z

#define DEPTH_BIAS 0.002
#define EDGE_SLOPE 0.08
#define BLUR_TOLERANCE 0.05
#define FALLBACK 1.0
#define UNCHANGED 0.998

struct PS_IN
{
	float4 color : TEXCOORD0;
	float3 wpos  : TEXCOORD1;
	float4 spos  : TEXCOORD2;
};

struct PS_OUT
{
	float4 color : COLOR0;
	float depth  : DEPTH0;
};

float2 blurTap(float2 uv, float weight, float depthSample)
{
	float2 o = tex2Dlod(Occlusion, float4(uv, 0.0, 0.0)).rg;
	float w = weight * saturate(1.0 - abs(o.g - depthSample) / (depthSample * BLUR_TOLERANCE));

	return float2(o.r * w, w);
}

float2 nearestTap(float2 best, float2 uv, float depthSample)
{
	float2 o = tex2Dlod(Occlusion, float4(uv, 0.0, 0.0)).rg;
	float diff = abs(o.g - depthSample);

	return diff < best.y ? float2(o.r, diff) : best;
}

PS_OUT main(PS_IN i)
{
	float2 uv = i.spos.xy / i.spos.w * float2(0.5, -0.5) + 0.5;
	uv += DX9_HALF_TEXEL(float2(abs(ddx(uv).x), abs(ddy(uv).y)) * 0.5);

	float4 frame = tex2D(Frame, uv);
	float depthSample = tex2D(Depth, uv).r;
	float slope = (abs(ddx(depthSample)) + abs(ddy(depthSample))) / max(depthSample, 1e-4);
	float bias = DEPTH_BIAS + (slope < EDGE_SLOPE ? slope : 0.0);
	float d = depthSample * DEPTH_SCALE;

	PS_OUT o;
	o.depth = DeviceDepth(IsSkyDepth(depthSample) ? 1.0 : saturate(ZFAR / (ZFAR - ZNEAR) * (1.0 - ZNEAR / (d * (1.0 - bias)))));
	o.color = float4(frame.rgb, 1.0);
	[branch] if (IsSkyDepth(depthSample))
	{
		clip(DEBUG - 0.5);
		return o;
	}

	float2 t = uv / TEXEL;
	float2 g = frac(t);
	float2 k = floor(t);
	float3 wx = float3(2.0 - g.x, 2.0, g.x);
	float3 wy = float3(2.0 - g.y, 2.0, g.y);
	float3 tx = (k.x + float3(1.0 / (2.0 - g.x) - 1.5, 1.0, 2.5)) * TEXEL.x;
	float3 ty = (k.y + float3(1.0 / (2.0 - g.y) - 1.5, 1.0, 2.5)) * TEXEL.y;

	float2 acc = 0.0;
	[unroll]
	for (int y = 0; y < 3; y++)
	{
		[unroll]
		for (int x = 0; x < 3; x++)
		{
			acc += blurTap(float2(tx[x], ty[y]), wx[x] * wy[y], depthSample);
		}
	}
	float ao = acc.x / max(acc.y, 1e-4);

	[branch] if (acc.y < FALLBACK)
	{
		float2 near = (floor(t - 0.5) + 0.5) * TEXEL;
		float2 best = float2(1.0, 1e30);
		best = nearestTap(best, near, depthSample);
		best = nearestTap(best, near + float2(TEXEL.x, 0.0), depthSample);
		best = nearestTap(best, near + float2(0.0, TEXEL.y), depthSample);
		best = nearestTap(best, near + TEXEL, depthSample);
		ao = lerp(best.x, ao, acc.y / FALLBACK);
	}

	float luma = max(dot(frame.rgb, float3(0.2126, 0.7152, 0.0722)), 1e-4);
	float applied = 1.0 - (1.0 - ao) * STRENGTH * min(luma, AMBIENT) / luma;
	clip(max(UNCHANGED - applied, DEBUG - 0.5));
	o.color.rgb = lerp(frame.rgb * applied, applied.xxx, DEBUG);

	return o;
}
