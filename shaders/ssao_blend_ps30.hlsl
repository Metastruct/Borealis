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
#define CENTER_WEIGHT 0.05
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

float2 blurTap(float2 uv, float raw)
{
	float2 o = tex2Dlod(Occlusion, float4(uv, 0.0, 0.0)).rg;
	float w = saturate(1.0 - abs(o.g - raw) / (raw * BLUR_TOLERANCE));

	return float2(o.r * w, w);
}

PS_OUT main(PS_IN i)
{
	float2 uv = i.spos.xy / i.spos.w * float2(0.5, -0.5) + 0.5;
	uv += float2(abs(ddx(uv).x), abs(ddy(uv).y)) * 0.5;

	float4 frame = tex2D(Frame, uv);
	float raw = tex2D(Depth, uv).r;
	float slope = (abs(ddx(raw)) + abs(ddy(raw))) / max(raw, 1e-4);
	float bias = DEPTH_BIAS + (slope < EDGE_SLOPE ? slope : 0.0);
	float d = raw * DEPTH_SCALE;

	PS_OUT o;
	o.depth = IsSkyDepth(raw) ? 1.0 : saturate(ZFAR / (ZFAR - ZNEAR) * (1.0 - ZNEAR / (d * (1.0 - bias))));
	o.color = float4(frame.rgb, 1.0);
	[branch] if (IsSkyDepth(raw))
	{
		clip(DEBUG - 0.5);
		return o;
	}

	float2 corner = floor(uv / TEXEL - 0.5) * TEXEL;
	float2 acc = float2(tex2Dlod(Occlusion, float4(uv, 0.0, 0.0)).r, 1.0) * CENTER_WEIGHT;
	acc += blurTap(corner, raw);
	acc += blurTap(corner + TEXEL * float2(2.0, 0.0), raw);
	acc += blurTap(corner + TEXEL * float2(0.0, 2.0), raw);
	acc += blurTap(corner + TEXEL * float2(2.0, 2.0), raw);
	float ao = acc.x / acc.y;

	float luma = max(dot(frame.rgb, float3(0.2126, 0.7152, 0.0722)), 1e-4);
	float applied = 1.0 - (1.0 - ao) * STRENGTH * min(luma, AMBIENT) / luma;
	clip(max(UNCHANGED - applied, DEBUG - 0.5));
	o.color.rgb = lerp(frame.rgb * applied, applied.xxx, DEBUG);

	return o;
}
