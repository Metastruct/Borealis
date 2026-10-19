const float4 Constants0 : register(c0);

sampler Mask : register(s0);

#define TEXEL Constants0.xy
#define WIDTH Constants0.z

#define GROUP_SCALE 8.0
#define DIST_SCALE 16.0
#define CODE_BASE 225.0
#define CODE_STEP 5.0
#define CODE_TOLERANCE 2.0

struct PS_IN
{
	float2 uv    : TEXCOORD0;
	float4 color : TEXCOORD1;
	float2 vpos  : VPOS;
};

float group(float2 uv)
{
	float a = tex2Dlod(Mask, float4(uv, 0.0, 0.0)).a * 255.0;
	float id = floor((a - CODE_BASE) / CODE_STEP + 0.5);

	return id >= 1.0 && abs(a - CODE_BASE - id * CODE_STEP) < CODE_TOLERANCE ? id : 0.0;
}

float4 main(PS_IN i) : COLOR0
{
	float2 uv = (i.vpos + 0.5) * TEXEL;

	float best = DIST_SCALE;
	float id = 0.0;
	[loop] for (float x = -WIDTH; x <= WIDTH; x += 1.0)
	{
		float k = group(uv + float2(x * TEXEL.x, 0.0));
		if (k > 0.0 && abs(x) < best)
		{
			best = abs(x);
			id = k;
		}
	}

	return id > 0.0 ? float4(best / DIST_SCALE, id / GROUP_SCALE, 0.0, 1.0) : float4(1.0, 0.0, 0.0, 1.0);
}
