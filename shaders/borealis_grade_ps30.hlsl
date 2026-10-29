const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);

sampler Frame : register(s0);

#define WHITE      Constants0.rgb
#define CONTRAST   Constants0.w
#define SHADOWS    Constants1.rgb
#define SATURATION Constants1.w
#define HIGHLIGHTS Constants2.rgb
#define TEXEL      Constants3.xy
#define PEAK       Constants3.z

#define LUMA float3(0.2126, 0.7152, 0.0722)
#define PIVOT 0.4587
#define DITHER (1.0 / 255.0)

struct PS_IN
{
	float2 uv   : TEXCOORD0;
	float2 vpos : VPOS;
};

float3 sCurve(float3 d)
{
	float3 lo = PIVOT * pow(max(d / PIVOT, 0.0), CONTRAST);
	float3 hi = 1.0 - (1.0 - PIVOT) * pow(max((1.0 - d) / (1.0 - PIVOT), 0.0), CONTRAST);

	return d < PIVOT ? lo : hi;
}

float noise(float2 p)
{
	return frac(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

float3 sharpen(float2 uv, float3 e)
{
	float3 b = tex2Dlod(Frame, float4(uv - float2(0.0, TEXEL.y), 0.0, 0.0)).rgb;
	float3 d = tex2Dlod(Frame, float4(uv - float2(TEXEL.x, 0.0), 0.0, 0.0)).rgb;
	float3 f = tex2Dlod(Frame, float4(uv + float2(TEXEL.x, 0.0), 0.0, 0.0)).rgb;
	float3 h = tex2Dlod(Frame, float4(uv + float2(0.0, TEXEL.y), 0.0, 0.0)).rgb;

	float3 mn = min(e, min(min(b, d), min(f, h)));
	float3 mx = max(e, max(max(b, d), max(f, h)));
	float3 w = sqrt(saturate(min(mn, 1.0 - mx) / max(mx, 1e-4))) * PEAK;

	return saturate(((b + d + f + h) * w + e) / (1.0 + 4.0 * w));
}

float4 main(PS_IN i) : COLOR0
{
	float4 frame = tex2D(Frame, i.uv);
	float3 c = frame.rgb;
	[branch] if (PEAK < 0.0)
	{
		c = sharpen(i.uv, c);
	}
	c *= WHITE;

	float tone = pow(saturate(dot(c, LUMA)), 1.0 / 2.2);
	float ws = (1.0 - tone) * (1.0 - tone);
	float wh = tone * tone;
	c *= 1.0 + (SHADOWS - 1.0) * ws + (HIGHLIGHTS - 1.0) * wh;

	float luma = dot(c, LUMA);
	c = max(lerp(luma.xxx, c, SATURATION), 0.0);

	float3 d = sCurve(pow(saturate(c), 1.0 / 2.2));
	d += (noise(i.vpos) + noise(i.vpos + 0.5) - 1.0) * DITHER;

	return float4(pow(saturate(d), 2.2), frame.a);
}
