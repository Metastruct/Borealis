#include "include/common.hlsl"
#include "include/slices.hlsl"

const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);
const float4 Constants11 : register(c11);
const float4 Constants12 : register(c12);
const float4 Constants13 : register(c13);

sampler Frame : register(s0);
sampler Depth : register(s1);
sampler Mask : register(s2);
sampler3D Noise : register(s3);

#define EYE         Constants0.xyz
#define TIME        Constants0.w
#define FWD         Constants1.xyz
#define TAN_H       Constants1.w
#define RIGHT       Constants2.xyz
#define TAN_V       Constants2.w
#define UP          cross(RIGHT, FWD)
#define MASK_ORIGIN Constants3.xy
#define MASK_SIZE   Constants3.z
#define BASE_TOP    Constants3.w
#define STRENGTH    Constants11.x
#define SHIMMER     Constants11.y
#define PULSE       Constants11.z
#define GLOW        Constants11.w
#define AREA_MIN    Constants12.xyz
#define FUME        Constants12.w
#define AREA_MAX    Constants13.xyz
#define CAVE_HAZE   Constants13.w

#define LAVA_COLOR float3(1.0, 0.32, 0.06)
#define LAVA_ADD 0.03
#define FUME_EMBER float3(0.8, 0.12, 0.025)
#define FUME_SMOKE float3(0.06, 0.012, 0.006)
#define FUME_FALLOFF 160.0
#define CAVE_FALLOFF 700.0

#define MASK_RES 256.0
#define HEIGHT_RANGE 255.0
#define SKY_FAR 8000.0
#define SURFACE_EPS 1.0
#define SURFACE_COVER 0.003
#define SURFACE_FLAT 0.99
#define FALLOFF 260.0
#define HEIGHT_OFFSET 48.0
#define SIDE_DISTANCE 700.0
#define WRAP 0.3
#define EDGE_HEIGHT 28.0
#define EDGE_GLOW 1.6
#define FLICKER 0.35
#define FLICKER_SCALE (1.0 / 700.0)
#define FLICKER_SPEED 0.04
#define HOT_HEIGHT 160.0
#define HOT_PATH 600.0
#define SHIMMER_SCALE (1.0 / 400.0)
#define SHIMMER_RISE 70.0
#define SHIMMER_FADE 2500.0
#define FLOW_SCALE (1.0 / 900.0)
#define FLOW_SPEED 0.012
#define FUME_LAYERS 3.0
#define FUME_LIT 120.0
#define FUME_SCALE (1.0 / 600.0)
#define FUME_RISE 25.0
#define FUME_DRIFT float2(9.0, 5.0)
#define FUME_GAP 0.3
#define FUME_STEPS 12
#define FUME_MAX 3000.0

#define FINISH(c) float4((c) * fumeT + fumeCol, 1.0)

struct PS_IN
{
	float4 color : TEXCOORD0;
	float3 wpos  : TEXCOORD1;
	float4 spos  : TEXCOORD2;
};

float3 viewRay(float2 uv)
{
	float2 ndc = (uv - 0.5) * float2(2.0, -2.0);

	return FWD + RIGHT * (ndc.x * TAN_H) + UP * (ndc.y * TAN_V);
}

float4 lavaMask(float2 xy)
{
	return tex2Dlod(Mask, float4((xy - MASK_ORIGIN) / MASK_SIZE, 0.0, 0.0));
}

float2 areaSpan(float3 dir)
{
	float3 safe = dir + (abs(dir) < 1e-5) * 1e-5;
	float3 t0 = (AREA_MIN - EYE) / safe;
	float3 t1 = (AREA_MAX - EYE) / safe;
	float3 enter = min(t0, t1);
	float3 leave = max(t0, t1);

	return float2(max(max(enter.x, enter.y), enter.z), min(min(leave.x, leave.y), leave.z));
}

float4 main(PS_IN i) : COLOR0
{
	float2 uv = i.spos.xy / i.spos.w * float2(0.5, -0.5) + 0.5;
	float2 halfTexel = float2(abs(ddx(uv).x), abs(ddy(uv).y)) * 0.5;
	uv += halfTexel;

	float4 frame = tex2D(Frame, uv);
	float raw = tex2D(Depth, uv).r;
	float samples = max(floor(i.color.b * 255.0 + 0.5), 1.0);
	float code = frame.a * 255.0;
	float coded = code > SLICE_EXACT - 0.5 ? SLICE_NEAR * pow(SLICE_RATIO, code - SLICE_EXACT) : SLICE_NEAR * pow(SLICE_RATIO, floor(code + 0.5) - 0.5);
	float d = abs(raw - 1.0) < SKY_EPS ? SKY_FAR : (raw <= 0.0 ? coded : SliceDepth(raw * DEPTH_SCALE, code, samples));
	float3 view = viewRay(uv);
	float3 p = EYE + view * d;
	float3 n = normalize(cross(ddx(p), ddy(p)));
	n = dot(n, view) > 0.0 ? -n : n;

	float3 color = frame.rgb;
	float vz = abs(view.z) < 1e-4 ? 1e-4 : view.z;
	float sa = (BASE_TOP - EYE.z) / vz;
	float sb = (BASE_TOP + HOT_HEIGHT - EYE.z) / vz;
	float lo = max(min(sa, sb), 0.0);
	float hi = min(max(sa, sb), d);
	float len = length(view);
	[branch] if (SHIMMER > 0.0 && hi > lo)
	{
		float3 mid = EYE + view * ((lo + hi) * 0.5);
		float heat = lavaMask(mid.xy).a;
		float w = heat * saturate((hi - lo) * len / HOT_PATH) * saturate(1.0 - lo * len / SHIMMER_FADE);
		[branch] if (w > 0.01)
		{
			float3 q = mid * SHIMMER_SCALE;
			q.z -= TIME * SHIMMER_RISE * SHIMMER_SCALE;
			float nx = tex3Dlod(Noise, float4(q, 0.0)).r;
			float ny = tex3Dlod(Noise, float4(q.yzx + 0.37, 0.0)).r;
			color = tex2Dlod(Frame, float4(uv + (float2(nx, ny) - 0.5) * SHIMMER * w, 0.0, 0.0)).rgb;
		}
	}

	float fumeT = 1.0;
	float3 fumeCol = float3(0.0, 0.0, 0.0);
	float fa = (BASE_TOP - EYE.z) / vz;
	float fb = (BASE_TOP + FUME_FALLOFF * FUME_LAYERS - EYE.z) / vz;
	float2 span = areaSpan(view);
	float2 band = CAVE_HAZE > 0.0 ? float2(-1e9, 1e9) : float2(min(fa, fb), max(fa, fb));
	float flo = max(max(band.x, 0.0), span.x);
	float fhi = min(min(band.y, d), span.y);
	fhi = min(fhi, flo + FUME_MAX / len);
	float lavaNearby = 0.0;
	[branch] if (FUME > 0.0 && fhi > flo)
	{
		lavaNearby = CAVE_HAZE > 0.0 ? 1.0 : max(max(lavaMask((EYE + view * flo).xy).a, lavaMask((EYE + view * fhi).xy).a), lavaMask((EYE + view * ((flo + fhi) * 0.5)).xy).a);
	}

	[branch] if (lavaNearby > 0.003)
	{
		float ds = (fhi - flo) / FUME_STEPS;
		float stepLen = ds * len;
		float jitter = frac(52.9829189 * frac(dot(floor(uv / (2.0 * halfTexel)), float2(0.06711056, 0.00583715))));
		[loop] for (int k = 0; k < FUME_STEPS; k++)
		{
			float3 s = EYE + view * (flo + (k + jitter) * ds);
			float4 sm = lavaMask(s.xy);
			float above = max(s.z - BASE_TOP - sm.b * HEIGHT_RANGE, 0.0);
			float3 q = float3(s.xy - FUME_DRIFT * TIME, s.z - TIME * FUME_RISE) * FUME_SCALE;
			float wisp = saturate((tex3Dlod(Noise, float4(q, 0.0)).r - FUME_GAP) / (1.0 - FUME_GAP));
			float sigma = FUME * (sm.a * exp(-above / FUME_FALLOFF) + CAVE_HAZE * exp(-above / CAVE_FALLOFF)) * wisp;
			float a = 1.0 - exp(-sigma * stepLen);
			fumeCol += fumeT * a * lerp(FUME_SMOKE, FUME_EMBER, exp(-above / FUME_LIT));
			fumeT *= 1.0 - a;
		}
	}

	float4 m = lavaMask(p.xy);
	[branch] if (max(m.r, m.g) < 0.003)
	{
		return FINISH(color);
	}

	float h = p.z - (BASE_TOP + m.b * HEIGHT_RANGE);
	[branch] if (abs(h) < SURFACE_EPS && m.r > SURFACE_COVER && n.z > SURFACE_FLAT)
	{
		float2 drift = float2(1.0, 0.6) * TIME * FLOW_SPEED;
		float flow = tex3Dlod(Noise, float4(p.xy * FLOW_SCALE + drift, TIME * 0.01, 0.0)).r;

		return FINISH(color * GLOW * (1.0 + PULSE * (flow - 0.5) * 2.0));
	}

	float hp = max(h, 0.0);
	float texel = MASK_SIZE / MASK_RES;
	float2 grad = float2(lavaMask(p.xy + float2(texel, 0.0)).g, lavaMask(p.xy + float2(0.0, texel)).g) - m.g;
	float gl = length(grad);
	float2 side = gl > 1e-4 ? grad / gl * (1.0 - m.g) * SIDE_DISTANCE : float2(0.0, 0.0);
	float3 toLava = normalize(float3(side, -(hp + HEIGHT_OFFSET)));
	float facing = WRAP + (1.0 - WRAP) * saturate(dot(n, toLava));
	float fall = 1.0 / (1.0 + (hp / FALLOFF) * (hp / FALLOFF));
	float edge = smoothstep(0.02, 0.45, m.r) * exp(-hp / EDGE_HEIGHT);
	float flick = tex3Dlod(Noise, float4(p.xy * FLICKER_SCALE, TIME * FLICKER_SPEED, 0.0)).r;
	float light = STRENGTH * (m.g * fall * facing + edge * EDGE_GLOW) * (1.0 - FLICKER + FLICKER * 2.0 * flick);

	return FINISH(color * (1.0 + LAVA_COLOR * light) + LAVA_COLOR * light * LAVA_ADD);
}
