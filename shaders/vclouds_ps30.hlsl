#include "include/common.hlsl"
#include "include/slices.hlsl"

const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);
const float4 Extra0 : register(c11);

sampler Frame : register(s0);
sampler Depth : register(s1);
sampler3D Shape : register(s2);
sampler3D Detail : register(s3);
sampler LightMap : register(s4);

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

#define MAP_ORIGIN Extra0.xy
#define MAP_INV    Extra0.z
#define MAP_ON     Extra0.w

#define SHAPE_BLEND
#define SINGLE_SMALL_LATTICE
#define LIGHT_PLAIN_SHAPE

#include "include/cloud_volume.hlsl"

#define STEPS 64
#define STEP_POW 1.5

#define DETAIL_NEAR 18000.0
#define DETAIL_FAR 26000.0
#define DETAIL2_SCALE 2.7
#define DETAIL2_OFFSET float3(0.37, 0.11, 0.73)
#define DETAIL2_EDGE 0.3
#define DETAIL2_GAIN 0.35

#define LIGHT_LOD_T 0.3

#define SKIP_ALPHA (254.5 / 255.0)

struct PS_IN
{
	float4 color : TEXCOORD0;
	float3 wpos  : TEXCOORD1;
	float4 spos  : TEXCOORD2;
};

float mapTransmittance(float3 p)
{
	float4 m = tex2Dlod(LightMap, float4((p.xy - MAP_ORIGIN) * MAP_INV + 0.5, 0.0, 0.0));
	float l = heightFraction(p) * 4.0 - 0.5;

	return m.x + (m.y - m.x) * saturate(l) + (m.z - m.y) * saturate(l - 1.0) + (m.w - m.z) * saturate(l - 2.0);
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
	float3 phases = cloudPhases(dot(ray, SUN_DIR));

	float path = t1 - t0;
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

		float u = (k + jitter) / STEPS;
		float t = t0 + path * pow(u, STEP_POW);
		float ds = path * STEP_POW * pow(max(u, 0.5 / STEPS), STEP_POW - 1.0) / STEPS;
		float3 p = EYE + ray * t;
		float h = heightFraction(p);
		float cover = coverAt(p);
		float base = baseDensity(shapeAt(p, h), h, cover);
		[branch] if (base > 0.0)
		{
			float detailW = saturate(remap(t, DETAIL_FAR, DETAIL_NEAR, 0.0, 1.0));
			float n = MEAN_DETAIL;
			[branch] if (detailW > 0.0)
			{
				n = detailAt(p, h, 1.0, 0.0);
				float w2 = saturate((DETAIL2_EDGE - base) / DETAIL2_EDGE) * DETAIL2_GAIN;
				[branch] if (w2 > 0.0)
				{
					n = saturate(n + (detailAt(p, h, DETAIL2_SCALE, DETAIL2_OFFSET) - 0.5) * w2);
				}
				n = lerp(MEAN_DETAIL, n, detailW);
			}

			float dens = erodeBy(base, n, h, erode) * saturate(remap(t, MAX_RANGE, FADE_RANGE, 0.0, 1.0));
			[branch] if (dens > 0.0)
			{
				debugDens = max(debugDens, dens);

				float sigma = dens * DENSITY;
				float a = 1.0 - exp(-sigma * ds);

				float beer;
				[branch] if (MAP_ON > 0.5)
				{
					[branch] if (T > LIGHT_LOD_T)
					{
						beer = exp(-nearLightTau(p, erode, cover)) * mapTransmittance(p + SUN_DIR * LIGHT_NEAR_REACH);
					}
					else
					{
						beer = mapTransmittance(p);
					}
				}
				else
				{
					beer = exp(-lightTau(p, erode, cover));
				}

				float3 col = lerp(cloudLight(beer, sigma, dens, h, phases, sunCol, ambCol), fogCol, saturate((t - fog.x) / fog.y) * fog.z);

				L += col * a * T;
				T *= 1.0 - a;
			}
		}
	}

	if (i.color.b > 0.25)
	{
		return float4(debugDens.xxx, 1.0);
	}

	return float4(scene * T + L, 1.0);
}
