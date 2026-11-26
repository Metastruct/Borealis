sampler Stamp : register(s0);

#define LEVEL 768.0
#define STRIDE 770.0
#define ATLAS 1540.0
#define RADIUS 2
#define SIGMA2 2.0
#define GAIN 1.6

float4 main(float2 vpos : VPOS) : COLOR
{
	float2 px = floor(vpos);
	float2 origin = floor(px / STRIDE) * STRIDE + 1.0;
	float2 l = px - origin;
	float mask = 0.0;
	float weights = 0.0;
	float press = 0.0;
	[unroll] for (int y = -RADIUS; y <= RADIUS; y++)
	{
		[unroll] for (int x = -RADIUS; x <= RADIUS; x++)
		{
			float w = exp(-(x * x + y * y) / SIGMA2);
			float2 t = l + float2(x, y);
			t -= floor(t / LEVEL) * LEVEL;
			float2 s = tex2Dlod(Stamp, float4((origin + t + 0.5) / ATLAS, 0.0, 0.0)).rg;
			mask += s.r * w;
			weights += w;
			press = max(press, s.g * w);
		}
	}

	return float4(saturate(mask / weights * GAIN), press, 0.0, 1.0);
}
