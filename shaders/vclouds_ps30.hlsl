#include "include/common.hlsl"
#include "include/slices.hlsl"

const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);

sampler Frame : register(s0);
sampler Depth : register(s1);
sampler3D Shape : register(s2);
sampler3D Detail : register(s3);

#define EYE      Constants0.xyz
#define LIGHT_P  Constants0.w
#define FWD      Constants1.xyz
#define TIME     Constants1.w
#define SUN_DIR  Constants2.xyz
#define AMB_P    Constants2.w
#define BASE_Z   Constants3.x
#define FOG_HUE  Constants3.y
#define COVERAGE Constants3.z
#define FOG_RAMP Constants3.w

#define THICK 3500.0
#define DENSITY 0.0025

#define MAX_RANGE 40000.0
#define FADE_RANGE 24000.0

#define STEPS 64
#define LIGHT_STEPS 5
#define LIGHT_STEP 260.0
#define LIGHT_GROW 1.6

#define SHAPE_SCALE (1.0 / 16000.0)

#define COVER_SCALE (1.0 / 47000.0)
#define COVER_SWING 3.6
#define COVER_DRIFT 0.5
#define DETAIL_SCALE (1.0 / 1200.0)
#define WIND float3(70.0, 26.0, 0.0)
#define DETAIL_WIND 2.5

#define HG_G 0.42
#define POWDER 2.6
#define AMBIENT_BASE 0.55
#define ERODE 0.45
#define LOG_RANGE 12.0

#define SKIP_ALPHA (254.5 / 255.0)

struct PS_IN
{
	float4 color : TEXCOORD0;
	float3 wpos  : TEXCOORD1;
	float4 spos  : TEXCOORD2;
};

float decodeScale(float v)
{
	return exp2((v * 2.0 - 1.0) * LOG_RANGE);
}

float3 unpackFog(float v)
{
	float start = floor(v / 65536.0);
	v -= start * 65536.0;
	float range = floor(v / 256.0);

	return float3(start * 64.0, max(range * 128.0, 1.0), (v - range * 256.0) / 255.0);
}

float heightFraction(float3 p)
{
	return saturate((p.z - BASE_Z) / THICK);
}

float coverAt(float3 p)
{
	float2 q = (p.xy - WIND.xy * TIME * COVER_DRIFT) * COVER_SCALE;
	float c = tex3Dlod(Shape, float4(q, 0.37, 0.0)).r;
	float k = saturate((c - 0.35) * COVER_SWING);

	k = lerp(k, 1.0, smoothstep(0.45, 0.75, COVERAGE));

	return saturate(COVERAGE * k);
}

float shapeDensity(float3 p, float h, float cover)
{
	float grad = saturate(remap(h, 0.0, 0.12, 0.0, 1.0)) * saturate(remap(h, 0.5, 1.0, 1.0, 0.0));
	float s = tex3Dlod(Shape, float4((p - WIND * TIME) * SHAPE_SCALE, 0.0)).r;

	return saturate(remap(s * grad, 1.0 - cover, 1.0, 0.0, 1.0));
}

float cloudDensity(float3 p, float h, float erode, float cover)
{
	float d = shapeDensity(p, h, cover);
	if (d <= 0.0)
	{
		return 0.0;
	}

	float n = tex3Dlod(Detail, float4((p - WIND * DETAIL_WIND * TIME) * DETAIL_SCALE, 0.0)).r;
	float e = lerp(1.0 - n, n, saturate(h * 4.0));

	return saturate(remap(d, e * erode, 1.0, 0.0, 1.0));
}

float lightTau(float3 p, float erode, float cover)
{
	float tau = 0.0;
	float step = LIGHT_STEP;
	float3 q = p;
	for (int i = 0; i < LIGHT_STEPS; i++)
	{
		q += SUN_DIR * step;
		float h = heightFraction(q);
		if (h > 0.0 && h < 1.0)
		{
			tau += cloudDensity(q, h, erode, cover) * DENSITY * step;
		}
		step *= LIGHT_GROW;
	}

	return tau;
}

float4 main(PS_IN i) : COLOR
{
	float2 uv = i.spos.xy / i.spos.w * float2(0.5, -0.5) + 0.5;

	uv += float2(abs(ddx(uv).x), abs(ddy(uv).y)) * 0.5;
	float4 frame = tex2D(Frame, uv);
	float3 scene = frame.rgb;
	[branch] if (frame.a > SKIP_ALPHA)
	{
		return float4(scene, 1.0);
	}

	float raw = tex2Dlod(Depth, float4(uv, 0.0, 0.0)).r;
	float d = raw * DEPTH_SCALE;
	if (IsSkyDepth(raw))
	{
		d = MAX_RANGE * 4.0;
	}

	d = SliceDepth(d, frame.a * 255.0, max(floor(i.color.b * 255.0 + 0.5), 1.0));

	float3 ray = normalize(i.wpos - EYE);
	float cosF = max(dot(ray, FWD), 0.05);
	float tScene = d / cosF;

	if (i.color.b > 0.75)
	{
		float ks = floor(frame.a * 255.0 + 0.5) - 1.0;
		if (ks < 0.0) return float4(1.0, 0.0, 0.0, 1.0);
		if (ks >= SLICES - 1.0) return float4(0.0, 0.0, 1.0, 1.0);

		return float4(0.0, saturate(SLICE_NEAR * pow(SLICE_RATIO, ks + 0.5) / 6000.0), 0.0, 1.0);
	}

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
	t1 = min(min(t1, tScene), MAX_RANGE);
	if (t1 <= t0)
	{
		return float4(scene, 1.0);
	}

	float erode = ERODE;
	float3 sunCol = unpackColor(LIGHT_P) * decodeScale(i.color.g);
	float3 ambCol = unpackColor(AMB_P) * decodeScale(i.color.r);
	float3 fogCol = unpackColor(FOG_HUE) * decodeScale(i.color.a);
	float3 fog = unpackFog(FOG_RAMP);

	float cosSun = dot(ray, SUN_DIR);
	float g2 = HG_G * HG_G;
	float phase = (1.0 - g2) / pow(max(1.0 + g2 - 2.0 * HG_G * cosSun, 1e-3), 1.5);

	float ds = (t1 - t0) / STEPS;
	float jitter = frac(52.9829189 * frac(dot(uv * float2(1920.0, 1080.0), float2(0.06711056, 0.00583715))));

	float T = 1.0;
	float3 L = 0.0;
	float debugDens = 0.0;

	for (int k = 0; k < STEPS; k++)
	{
		if (T < 0.02)
		{
			break;
		}

		float t = t0 + (k + jitter) * ds;
		if (t > t1)
		{
			break;
		}

		float3 p = EYE + ray * t;
		float h = heightFraction(p);
		float cover = coverAt(p);
		float dens = cloudDensity(p, h, erode, cover);
		if (dens <= 0.0)
		{
			continue;
		}

		dens *= saturate(remap(t, MAX_RANGE, FADE_RANGE, 0.0, 1.0));
		debugDens = max(debugDens, dens);

		float sigma = dens * DENSITY;
		float a = 1.0 - exp(-sigma * ds);

		float beer = exp(-lightTau(p, erode, cover));
		float powder = 1.0 - exp(-sigma * POWDER * 400.0);
		float3 sun = sunCol * phase * beer * lerp(1.0, powder, 0.7);
		float3 amb = ambCol * lerp(AMBIENT_BASE, 1.0, h);

		float3 col = lerp(sun + amb, fogCol, saturate((t - fog.x) / fog.y) * fog.z);

		L += col * a * T;
		T *= 1.0 - a;
	}

	if (i.color.b > 0.25)
	{
		return float4(debugDens.xxx, 1.0);
	}

	return float4(scene * T + L, 1.0);
}
