sampler Stamp : register(s0);

#define TRAIL_TEXELS 1024.0
#define RADIUS 2
#define SIGMA2 2.0
#define GAIN 1.6

float4 main(float2 vpos : VPOS) : COLOR
{
	float2 uv = (vpos + 0.5) / TRAIL_TEXELS;
	float sum = 0.0;
	float weights = 0.0;
	[unroll] for (int y = -RADIUS; y <= RADIUS; y++)
	{
		[unroll] for (int x = -RADIUS; x <= RADIUS; x++)
		{
			float w = exp(-(x * x + y * y) / SIGMA2);
			sum += tex2Dlod(Stamp, float4(uv + float2(x, y) / TRAIL_TEXELS, 0.0, 0.0)).r * w;
			weights += w;
		}
	}

	float v = saturate(sum / weights * GAIN);

	return float4(v, v, v, 1.0);
}
