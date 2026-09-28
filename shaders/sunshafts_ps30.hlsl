const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);

sampler Src : register(s0);

#define SUN_UV   Constants0.xy
#define RAY_LEN  Constants0.z
#define DECAY    Constants0.w
#define RADIUS   Constants1.x
#define ASPECT   Constants1.y
#define FALLOFF  Constants1.z
#define GAIN     Constants1.w
#define STEPS 16

struct PS_IN
{
	float2 uv : TEXCOORD0;
};

float4 main(PS_IN i) : COLOR
{
	float2 uv = i.uv;
	float2 step = (SUN_UV - uv) * (RAY_LEN / STEPS);
	float w = 1.0;
	float sum = 0.0;
	float wsum = 0.0;
	for (int k = 0; k < STEPS; k++)
	{
		float2 p = uv + step * k;
		float inside = (p.x >= 0.0 && p.x <= 1.0 && p.y >= 0.0 && p.y <= 1.0) ? 1.0 : 0.0;
		float4 t = tex2D(Src, p);
		float v = (FALLOFF > 0.5 ? t.a : t.r) * inside;
		if (FALLOFF > 0.5)
		{
			float2 d = (p - SUN_UV) * float2(ASPECT, 1.0);
			float f = saturate(1.0 - length(d) / RADIUS);
			v *= f * f;
		}

		sum += v * w;
		wsum += w;
		w *= DECAY;
	}

	float r = sum / wsum * GAIN;

	return float4(r, r, r, 1.0);
}
