const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);

sampler Frame : register(s0);

#define RECT_MIN     Constants0.xy
#define RECT_SIZE    Constants0.zw
#define TEXEL        Constants1.xy
#define TIME         Constants1.z
#define GLOW         Constants2.x
#define SCAN         Constants2.y
#define ABERRATION   Constants2.z
#define CURVE        Constants2.w
#define POWER        Constants3.x

#define TAU 6.2831853
#define GLOW_TAPS 12
#define GLOW_RADIUS 6.0
#define SCAN_PERIOD 3.0

static const float3 PHOSPHOR = float3(0.20, 1.00, 0.62);

struct PS_IN
{
	float2 uv   : TEXCOORD0;
	float2 vpos : VPOS;
};

float4 main(PS_IN i) : COLOR0
{
	float2 pixel = floor(i.vpos);
	float2 q = (pixel - RECT_MIN + 0.5) / RECT_SIZE * 2.0 - 1.0;

	float fold = saturate(POWER * 2.0);
	float shrink = saturate(POWER * 2.0 - 1.0);
	float2 open = float2(1.0 - shrink * 0.995, lerp(1.0, 0.008, fold));
	float shown = step(abs(q.x), open.x) * step(abs(q.y), open.y);
	q /= open;

	float2 d = (abs(q) - 1.0) * RECT_SIZE * 0.5;
	float sdf = max(d.x, d.y);

	float2 qa = q * RECT_SIZE / RECT_SIZE.x;
	q *= 1.0 + CURVE * dot(qa, qa);

	float2 n = q * 0.5 + 0.5;
	float2 lo = (RECT_MIN + 0.5) * TEXEL;
	float2 hi = (RECT_MIN + RECT_SIZE - 0.5) * TEXEL;
	float2 uv = clamp((RECT_MIN + n * RECT_SIZE) * TEXEL, lo, hi);

	float2 shift = q * ABERRATION * TEXEL;
	float3 c;
	c.r = tex2Dlod(Frame, float4(clamp(uv + shift, lo, hi), 0.0, 0.0)).r;
	c.g = tex2Dlod(Frame, float4(uv, 0.0, 0.0)).g;
	c.b = tex2Dlod(Frame, float4(clamp(uv - shift, lo, hi), 0.0, 0.0)).b;

	float3 glow = 0.0;
	[unroll] for (int k = 0; k < GLOW_TAPS; k++)
	{
		float a = k * 2.39996;
		float r = sqrt((k + 0.5) / GLOW_TAPS) * GLOW_RADIUS;
		float2 tap = clamp(uv + float2(cos(a), sin(a)) * r * TEXEL, lo, hi);
		glow += tex2Dlod(Frame, float4(tap, 0.0, 0.0)).rgb;
	}
	glow /= GLOW_TAPS;
	c += glow * glow * GLOW;

	float scan = 0.5 + 0.5 * cos(pixel.y * TAU / SCAN_PERIOD);
	float roll = frac(TIME * 0.07) * 1.4 - 0.2;
	c *= (1.0 - SCAN * scan) * (1.0 + 0.05 * exp(-pow((n.y - roll) * 9.0, 2.0)));
	c *= 1.0 + 0.012 * sin(TIME * 7.3) * sin(TIME * 2.9 + 1.0);

	float edge = saturate(-sdf / (RECT_SIZE.y * 0.18));
	c *= lerp(0.55, 1.0, sqrt(edge));
	c += 0.035 * saturate(1.0 - length((n - float2(0.22, 0.12)) * float2(1.6, 2.6)));

	c = lerp(c, PHOSPHOR * 1.3, fold);

	return float4(saturate(c) * shown, 1.0);
}
