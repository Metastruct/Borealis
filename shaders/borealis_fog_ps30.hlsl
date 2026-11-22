#include "include/slices.hlsl"
#include "include/cover_spans.hlsl"

const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);

sampler Frame : register(s0);
sampler Depth : register(s1);
sampler3D Noise : register(s2);
sampler CoverTex : register(s3);
sampler CoverSpans : register(s4);
sampler Exposure : register(s5);

const float4 Constants11 : register(c11);
const float4 Constants12 : register(c12);

#define EYE      Constants0.xyz
#define DENSITY  Constants0.w
#define FWD      Constants1.xyz
#define TIME     Constants1.w
#define SUN_DIR  Constants2.xyz
#define BASE_Z   Constants2.w
#define FOG_COL  Constants3.xyz
#define FALLOFF  Constants3.w
#define SPANS_ON Constants11.x
#define EXPOSURE_FRAME Constants12

#define STEPS 24
#define MAX_RANGE 5000.0
#define SKIP_ALPHA (254.5 / 255.0)
#define NOISE_SCALE (1.0 / 1100.0)
#define NOISE_FADE 3500.0
#define WIND float3(0.012, 0.005, -0.003)
#define AMBIENT_K 0.6
#define SUN_K 0.4
#define SUN_MIN_Z 0.08
#define HG_G 0.42
#define THIN 1e-6
#define COLUMN 24.0
#define COLUMNS 64.0
#define COVER_RANGE 30.0
#define Z_MIN -16384.0
#define Z_RANGE 32768.0
#define EXPOSED_MIN 0.2
#define EXPOSED_MAX 0.6
#define ROOFED_MIN 0.3
#define ROOFED_MAX 0.55

struct PS_IN
{
	float4 color : TEXCOORD0;
	float3 wpos  : TEXCOORD1;
	float4 spos  : TEXCOORD2;
};

float heightFactor(float z)
{
	return exp(-max(z - BASE_Z, 0.0) / FALLOFF);
}

float sunTau(float3 p, float h)
{
	float sz = max(SUN_DIR.z, SUN_MIN_Z);
	float above = DENSITY * FALLOFF * h;
	float below = DENSITY * max(BASE_Z - p.z, 0.0);

	return (above + below) / sz;
}

bool sheltered(float3 p, float2 eyeCol)
{
	float2 col = floor(p.xy / COLUMN);
	float2 off = abs(col - eyeCol);
	bool covered = false;
	[branch] if (max(off.x, off.y) <= COVER_RANGE)
	{
		float2 c = tex2Dlod(CoverTex, float4(frac(col / COLUMNS) + 0.5 / COLUMNS, 0.0, 0.0)).rg;
		covered = p.z < (c.r * 65280.0 + c.g * 255.0) / 65535.0 * Z_RANGE + Z_MIN;
	}
	else if (SPANS_ON > 0.5)
	{
		covered = CoverSpansOpen(CoverSpans, p, 0.0) < 0.5;
	}

	return covered;
}

float exposure(float3 p, float2 eyeCol)
{
	bool roofed = sheltered(p, eyeCol);
	float open = roofed ? 0.0 : 1.0;
	[branch] if (EXPOSURE_FRAME.z > 0.0)
	{
		float2 baked = CoverExposureAt(Exposure, p, EXPOSURE_FRAME);
		float e = roofed ? smoothstep(ROOFED_MIN, ROOFED_MAX, baked.x) : smoothstep(EXPOSED_MIN, EXPOSED_MAX, baked.x);
		open = lerp(open, e, baked.y);
	}

	return open;
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

	float depthSample = tex2Dlod(Depth, float4(uv, 0.0, 0.0)).r;
	float d = depthSample * DEPTH_SCALE;
	if (IsSkyDepth(depthSample))
	{
		d = MAX_RANGE * 2.0;
	}

	d = SliceDepth(d, frame.a * 255.0, max(floor(i.color.b * 255.0 + 0.5), 1.0));

	float3 ray = normalize(i.wpos - EYE);
	float cosF = max(dot(ray, FWD), 0.05);
	float tEnd = min(d / cosF, MAX_RANGE);

	if (i.color.b > 0.75)
	{
		return float4(saturate(d / 8000.0).xxx, 1.0);
	}
	if (i.color.b > 0.25)
	{
		float3 hit = EYE + ray * tEnd;
		return float4(tex3Dlod(Noise, float4(hit * NOISE_SCALE - WIND * TIME, 0.0)).rrr, 1.0);
	}

	float ds = tEnd / STEPS;
	float jitter = frac(52.9829189 * frac(dot(uv * float2(1920.0, 1080.0), float2(0.06711056, 0.00583715))));

	float cosSun = dot(ray, SUN_DIR);
	float g2 = HG_G * HG_G;
	float phase = (1.0 - g2) / pow(max(1.0 + g2 - 2.0 * HG_G * cosSun, 1e-3), 1.5);
	float warm = 1.0 - saturate(SUN_DIR.z / 0.5);
	float3 sunTint = FOG_COL * lerp(float3(1.0, 1.0, 1.0), float3(1.25, 0.8, 0.5), warm);
	float sunGain = i.color.r * SUN_K * phase * saturate((SUN_DIR.z + 0.05) / 0.1);
	float3 ambient = FOG_COL * AMBIENT_K;
	float2 eyeCol = floor(EYE.xy / COLUMN);

	float T = 1.0;
	float3 L = float3(0.0, 0.0, 0.0);
	[loop]
	for (int k = 0; k < STEPS; k++)
	{
		float t = (k + jitter) * ds;
		float3 p = EYE + ray * t;
		float h = heightFactor(p.z);
		if (ray.z > 0.0 && DENSITY * h * ds < THIN)
		{
			break;
		}

		float open = exposure(p, eyeCol);
		[branch] if (open > 0.0)
		{
			float nStr = i.color.g * saturate(1.0 - t / NOISE_FADE);
			float m = open;
			[branch] if (nStr > 0.0)
			{
				float n = tex3Dlod(Noise, float4(p * NOISE_SCALE - WIND * TIME, 0.0)).r;
				m *= lerp(1.0, saturate((n - 0.25) * 2.2), nStr);
			}

			float a = 1.0 - exp(-DENSITY * h * m * ds);
			float3 li = ambient + sunTint * sunGain * exp(-sunTau(p, h));
			L += li * a * T;
			T *= 1.0 - a;
		}
	}

	return float4(scene * T + L, 1.0);
}
