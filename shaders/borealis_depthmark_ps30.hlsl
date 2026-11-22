#include "include/slices.hlsl"

const float4 Constants0 : register(c0);

sampler Codes : register(s0);
sampler Depth : register(s1);
sampler Frame : register(s2);

#define ZNEAR Constants0.x
#define ZFAR  Constants0.y
#define BIAS  Constants0.z
#define SAMPLES Constants0.w

#define CHANGE_EPS (0.5 / 255.0)
#define SLOPE_K 1.0
#define EDGE_SLOPE 0.08

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

float surfaceDepth(float depthSample, float2 uv)
{
	float d = IsSkyDepth(depthSample) ? ZFAR : depthSample * DEPTH_SCALE;

	float code = tex2D(Codes, uv).a * 255.0;
	if (code > SLICE_EXACT - 0.5)
	{
		return d > SLICE_NEAR * pow(SLICE_RATIO, code - SLICE_EXACT + 1.0) ? SLICE_NEAR * pow(SLICE_RATIO, code - SLICE_EXACT - 0.5) : d;
	}

	d = max(d, SLICE_NEAR * pow(SLICE_RATIO, SLICES - 1.0 - max(SAMPLES, 1.0) * (SLICES - code)) / SLICE_MARGIN);
	float ks = floor(code + 0.5) - 1.0;
	if (ks < 0.0)
	{
		return d > SLICE_NEAR ? ZNEAR : d;
	}
	float sliceFar = SLICE_NEAR * pow(SLICE_RATIO, ks + 1.0);
	if (ks < SLICES - 1.0 && d > sliceFar * SLICE_MARGIN)
	{
		return sliceFar / SLICE_RATIO;
	}

	return d;
}

PS_OUT main(PS_IN i)
{
	float2 uv = i.spos.xy / i.spos.w * float2(0.5, -0.5) + 0.5;
	uv += float2(abs(ddx(uv).x), abs(ddy(uv).y)) * 0.5;

	float depthSample = tex2D(Depth, uv).r;
	float slope = (abs(ddx(depthSample)) + abs(ddy(depthSample))) / max(depthSample, 1e-4);
	float bias = BIAS + (slope < EDGE_SLOPE ? SLOPE_K * slope : 0.0);
	float d = surfaceDepth(depthSample, uv);

	float3 change = abs(tex2D(Frame, uv).rgb - tex2D(Codes, uv).rgb);
	clip(max(change.r, max(change.g, change.b)) - CHANGE_EPS);

	PS_OUT o;
	o.color = float4(0.0, 0.0, 0.0, 1.0);
	o.depth = d >= ZFAR ? 1.0 : saturate(ZFAR / (ZFAR - ZNEAR) * (1.0 - ZNEAR / (d * (1.0 - bias))));

	return o;
}
