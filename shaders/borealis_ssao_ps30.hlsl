#include "include/slices.hlsl"

const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);

sampler Depth : register(s0);

#define TEXEL      Constants0.xy
#define TAN_H      Constants0.z
#define TAN_V      Constants0.w
#define RADIUS     Constants1.x
#define INTENSITY  Constants1.y
#define SCREEN_H   Constants1.z
#define MAX_PIXELS Constants1.w
#define AO_SIZE    Constants2.xy
#define AO_SCALE   Constants2.z

#define SAMPLES 24
#define TURNS 7.0
#define TAU 6.2831853
#define BIAS 0.5
#define BIAS_RATIO 0.002
#define EPSILON 0.01
#define SKY_FAR 1e6
#define FADE_START 3000.0
#define FADE_END 5000.0

struct PS_IN
{
	float2 uv    : TEXCOORD0;
	float4 color : TEXCOORD1;
};

float3 viewPos(float2 uv, float d)
{
	float2 ndc = (uv - 0.5) * float2(2.0, -2.0);

	return float3(ndc.x * TAN_H * d, ndc.y * TAN_V * d, d);
}

float3 tapPos(float2 uv)
{
	float depthSample = tex2Dlod(Depth, float4(uv, 0.0, 0.0)).r;

	return viewPos(uv, IsSkyDepth(depthSample) ? SKY_FAR : depthSample * DEPTH_SCALE);
}

float3 nearer(float3 p, float3 a, float3 b)
{
	return abs(a.z - p.z) < abs(p.z - b.z) ? a - p : p - b;
}

float bayer2(float2 c)
{
	float2 m = fmod(c, 2.0);

	return abs(m.x - m.y) * 2.0 + m.y;
}

float bayer4(float2 px)
{
	return bayer2(px) * 4.0 + bayer2(floor(px * 0.5));
}

float4 main(PS_IN i) : COLOR
{
	float2 px = floor(i.uv * AO_SIZE + 0.25);
	float2 uv = (px * AO_SCALE + 0.5) * TEXEL;
	float depthSample = tex2Dlod(Depth, float4(uv, 0.0, 0.0)).r;
	float d = depthSample * DEPTH_SCALE;
	[branch] if (IsSkyDepth(depthSample) || d > FADE_END)
	{
		return float4(1.0, depthSample, 0.0, 1.0);
	}

	float pixels = min(RADIUS * SCREEN_H * 0.5 / (d * TAN_V), MAX_PIXELS);
	[branch] if (pixels < 1.0)
	{
		return float4(1.0, depthSample, 0.0, 1.0);
	}

	float3 p = viewPos(uv, d);
	float2 sx = float2(TEXEL.x, 0.0);
	float2 sy = float2(0.0, TEXEL.y);
	float3 n = normalize(cross(nearer(p, tapPos(uv + sx), tapPos(uv - sx)), nearer(p, tapPos(uv + sy), tapPos(uv - sy))));
	n = dot(n, p) > 0.0 ? -n : n;

	float idx = bayer4(px);
	float phi = idx * (TAU / 16.0);
	float jitter = (fmod(idx * 7.0, 16.0) + 0.5) / 16.0;
	float2 rot;
	sincos(phi, rot.y, rot.x);

	float r2 = RADIUS * RADIUS;
	float bias = BIAS + d * BIAS_RATIO;
	float sum = 0.0;

	[unroll]
	for (int s = 0; s < SAMPLES; s++)
	{
		float a = (s + 0.5) / SAMPLES;
		float2 k;
		sincos(a * TURNS * TAU, k.y, k.x);
		float2 dir = float2(k.x * rot.x - k.y * rot.y, k.y * rot.x + k.x * rot.y);
		float2 tuv = uv + dir * ((s + jitter) / SAMPLES * pixels) * TEXEL;
		float inside = step(0.0, tuv.x) * step(0.0, tuv.y) * step(tuv.x, 1.0) * step(tuv.y, 1.0);
		float3 v = tapPos(tuv) - p;
		float vv = dot(v, v);
		float occlusion = max(dot(v, n) - bias, 0.0) * rsqrt(vv + EPSILON * r2);
		sum += inside * occlusion * saturate(1.0 - vv / r2);
	}

	float ao = saturate(1.0 - sum * INTENSITY * (2.0 / SAMPLES));
	ao = lerp(1.0, ao, saturate((FADE_END - d) / (FADE_END - FADE_START)));

	return float4(ao, depthSample, 0.0, 1.0);
}
