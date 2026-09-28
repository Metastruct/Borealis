const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);

sampler Frame : register(s0);
sampler Depth : register(s1);
sampler3D Noise : register(s2);

#define EYE      Constants0.xyz
#define DENSITY  Constants0.w
#define FWD      Constants1.xyz
#define TIME     Constants1.w
#define SUN_DIR  Constants2.xyz
#define BASE_Z   Constants2.w
#define FOG_COL  Constants3.xyz
#define FALLOFF  Constants3.w

#define STEPS 24
#define MAX_RANGE 5000.0
#define DEPTH_SCALE 4000.0
#define SLICE_NEAR 16.0
#define SLICE_RATIO 1.2219785
#define NOISE_SCALE (1.0 / 1100.0)
#define NOISE_FADE 3500.0
#define WIND float3(0.012, 0.005, 0.003)
#define AMBIENT_K 0.6
#define SUN_K 0.4
#define SUN_MIN_Z 0.08

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

float sunTau(float3 p)
{
	float sz = max(SUN_DIR.z, SUN_MIN_Z);
	float above = DENSITY * FALLOFF * heightFactor(p.z);
	float below = DENSITY * max(BASE_Z - p.z, 0.0);

	return (above + below) / sz;
}

float density(float3 p, float nStr)
{
	float n = tex3Dlod(Noise, float4(p * NOISE_SCALE + WIND * TIME, 0.0)).r;
	float m = lerp(1.0, saturate((n - 0.25) * 2.2), nStr);

	return DENSITY * heightFactor(p.z) * m;
}

float4 main(PS_IN i) : COLOR
{
	float2 uv = i.spos.xy / i.spos.w * float2(0.5, -0.5) + 0.5;

	uv -= float2(abs(ddx(uv).x), abs(ddy(uv).y)) * 0.5;
	float4 frame = tex2D(Frame, uv);
	float3 scene = frame.rgb;
	float d = tex2D(Depth, uv).r * DEPTH_SCALE;
	if (d <= 0.0) d = MAX_RANGE * 2.0;
	float ks = floor(frame.a * 255.0 + 0.5) - 1.0;
	float dSlice = (ks < 0.0) ? 0.0 : SLICE_NEAR * pow(SLICE_RATIO, ks + 0.5);
	d = min(d, dSlice);

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
		return float4(tex3Dlod(Noise, float4(hit * NOISE_SCALE + WIND * TIME, 0.0)).rrr, 1.0);
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

	float T = 1.0;
	float3 L = float3(0.0, 0.0, 0.0);
	for (int k = 0; k < STEPS; k++)
	{
		float t = (k + jitter) * ds;
		float3 p = EYE + ray * t;
		float nStr = i.color.g * saturate(1.0 - t / NOISE_FADE);
		float a = 1.0 - exp(-density(p, nStr) * ds);
		float3 li = ambient + sunTint * sunGain * exp(-sunTau(p));
		L += li * a * T;
		T *= 1.0 - a;
	}

	return float4(scene * T + L, 1.0);
}
