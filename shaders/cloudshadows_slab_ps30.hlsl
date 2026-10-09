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

#define EYE       Constants0.xyz
#define TIME      Constants0.w
#define FWD       Constants1.xyz
#define BASE_Z    Constants1.w
#define SUN_DIR   Constants2.xyz
#define COVERAGE  Constants2.w
#define STRENGTH  Constants3.w

#define FADE_START 9000.0
#define FADE_END 20000.0

#define MIN_SUN_Z 0.02

#define SHADOW_COL float3(0.60, 0.65, 0.76)

#define THICK 3500.0

#define DENSITY 0.0005
#define SHAPE_SCALE (1.0 / 16000.0)
#define COVER_SCALE (1.0 / 47000.0)
#define COVER_SWING 3.6
#define COVER_DRIFT 0.5
#define DETAIL_SCALE (1.0 / 1200.0)
#define DETAIL_WIND 2.5
#define ERODE 0.45
#define WIND float3(70.0, 26.0, 0.0)
#define SLAB_STEPS 4

struct PS_IN
{
	float4 color : TEXCOORD0;
	float3 wpos  : TEXCOORD1;
	float4 spos  : TEXCOORD2;
};

float coverAt(float3 p)
{
	float2 q = (p.xy - WIND.xy * TIME * COVER_DRIFT) * COVER_SCALE;
	float c = tex3Dlod(Shape, float4(q, 0.37, 0.0)).r;
	float k = saturate((c - 0.35) * COVER_SWING);
	k = lerp(k, 1.0, smoothstep(0.45, 0.75, COVERAGE));

	return saturate(COVERAGE * k);
}

float cloudDensity(float3 p, float cover)
{
	float h = saturate((p.z - BASE_Z) / THICK);
	float grad = saturate(remap(h, 0.0, 0.12, 0.0, 1.0)) * saturate(remap(h, 0.5, 1.0, 1.0, 0.0));
	float s = tex3Dlod(Shape, float4((p - WIND * TIME) * SHAPE_SCALE, 0.0)).r;
	float d = saturate(remap(s * grad, 1.0 - cover, 1.0, 0.0, 1.0));
	if (d <= 0.0)
	{
		return 0.0;
	}

	float n = tex3Dlod(Detail, float4((p - WIND * DETAIL_WIND * TIME) * DETAIL_SCALE, 0.0)).r;
	float e = lerp(1.0 - n, n, saturate(h * 4.0));

	return saturate(remap(d, e * ERODE, 1.0, 0.0, 1.0));
}

float slabShade(float3 p, float sz)
{
	float t0 = (BASE_Z - p.z) / sz;
	float t1 = (BASE_Z + THICK - p.z) / sz;
	t0 = max(t0, 0.0);
	if (t1 <= t0)
	{
		return 0.0;
	}

	float cover = coverAt(p + SUN_DIR * (t0 + t1) * 0.5);

	float ds = (t1 - t0) / SLAB_STEPS;
	float tau = 0.0;
	for (int k = 0; k < SLAB_STEPS; k++)
	{
		tau += cloudDensity(p + SUN_DIR * (t0 + ((float)k + 0.5) * ds), cover);
	}

	return 1.0 - exp(-tau * ds * DENSITY);
}

float4 main(PS_IN i) : COLOR
{
	float2 uv = i.spos.xy / i.spos.w * float2(0.5, -0.5) + 0.5;

	uv += float2(abs(ddx(uv).x), abs(ddy(uv).y)) * 0.5;
	float4 frame = tex2D(Frame, uv);
	float3 scene = frame.rgb;

	float raw = tex2D(Depth, uv).r;
	float d = raw * DEPTH_SCALE;
	if (IsSkyDepth(raw))
	{
		d = FADE_END * 4.0;
	}

	d = SliceDepth(d, frame.a * 255.0, max(floor(i.color.b * 255.0 + 0.5), 1.0));

	float3 ray = normalize(i.wpos - EYE);
	float cosF = max(dot(ray, FWD), 0.05);
	float t = d / cosF;
	float fade = saturate(remap(t, FADE_END, FADE_START, 0.0, 1.0));
	if (fade <= 0.0)
	{
		return float4(scene, 1.0);
	}

	float shade = slabShade(EYE + ray * t, max(SUN_DIR.z, MIN_SUN_Z)) * STRENGTH * fade;

	if (i.color.b > 0.25)
	{
		return float4(shade.xxx, 1.0);
	}

	return float4(scene * lerp(float3(1.0, 1.0, 1.0), SHADOW_COL, shade), 1.0);
}
