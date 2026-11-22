#include "include/common.hlsl"
#include "include/slices.hlsl"
#include "include/cover_spans.hlsl"

const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants11 : register(c11);
const float4 Constants12 : register(c12);

sampler Frame : register(s0);
sampler Depth : register(s1);
sampler ShadowMap : register(s2);
sampler CoverSpans : register(s3);
sampler Exposure : register(s4);

#define EYE       Constants0.xyz
#define STRENGTH  Constants0.w
#define FWD       Constants1.xyz
#define BASE_Z    Constants1.w
#define SUN_DIR   Constants2.xyz

#define MAP_ORIGIN Constants11.xy
#define MAP_INV    Constants11.z
#define SPANS_ON   Constants11.w
#define EXPOSURE_FRAME Constants12

#define FADE_START 9000.0
#define FADE_END 20000.0

#define MIN_SUN_Z 0.03
#define MAP_EDGE 0.05

#define SUN_OFFSET 48.0
#define OPEN_BELOW 32.0
#define RING_RADIUS 128.0
#define RING_BELOW 56.0
#define RING_TWIST 0.3
#define EXPOSED_MIN 0.2
#define EXPOSED_MAX 0.6
#define CLEAR_MIN 0.9
#define EXPOSURE_LIFT 208.0

#define SHADOW_COL float3(0.35, 0.40, 0.52)
#define OPACITY 3.0

struct PS_IN
{
	float4 color : TEXCOORD0;
	float3 wpos  : TEXCOORD1;
	float4 spos  : TEXCOORD2;
};

float4 main(PS_IN i) : COLOR
{
	float2 uv = i.spos.xy / i.spos.w * float2(0.5, -0.5) + 0.5;

	uv += float2(abs(ddx(uv).x), abs(ddy(uv).y)) * 0.5;
	float4 frame = tex2D(Frame, uv);
	float3 scene = frame.rgb;

	float depthSample = tex2D(Depth, uv).r;
	float d = depthSample * DEPTH_SCALE;
	if (IsSkyDepth(depthSample))
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

	float3 p = EYE + ray * t;
	float2 m = (p.xy + SUN_DIR.xy / max(SUN_DIR.z, MIN_SUN_Z) * max(BASE_Z - p.z, 0.0) - MAP_ORIGIN) * MAP_INV + 0.5;
	float2 edge = saturate(min(m, 1.0 - m) / MAP_EDGE);
	float shade = (1.0 - pow(tex2Dlod(ShadowMap, float4(m, 0.0, 0.0)).r, OPACITY)) * edge.x * edge.y * STRENGTH * fade;
	[branch] if (shade > 0.0 && SPANS_ON > 0.5)
	{
		float2 baked = float2(0.0, 0.0);
		[branch] if (EXPOSURE_FRAME.z > 0.0)
		{
			baked = CoverExposureAt(Exposure, p + float3(0.0, 0.0, EXPOSURE_LIFT), EXPOSURE_FRAME);
		}

		float exposed = baked.x;
		[branch] if (baked.y < 1.0)
		{
			exposed = lerp(CoverSpansExposure(CoverSpans, p, RING_RADIUS, RING_BELOW, RING_TWIST), baked.x, baked.y);
		}

		shade *= smoothstep(EXPOSED_MIN, EXPOSED_MAX, exposed);
		[branch] if (shade > 0.0 && exposed > CLEAR_MIN)
		{
			shade *= lerp(1.0, CoverSpansOpenSmooth(CoverSpans, p + SUN_DIR * SUN_OFFSET, OPEN_BELOW), smoothstep(CLEAR_MIN, 1.0, exposed));
		}
	}

	return float4(scene * lerp(float3(1.0, 1.0, 1.0), SHADOW_COL, shade), 1.0);
}
