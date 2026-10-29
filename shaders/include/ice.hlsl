#define ICE_GOLDEN 1.618034

float IceNoise(sampler3D noise, float2 p, float tile, float w)
{
	float a = tex3Dlod(noise, float4(p / tile, w, 0.0)).r;
	float2 q = float2(p.x * 0.8 - p.y * 0.6, p.x * 0.6 + p.y * 0.8) / (tile * ICE_GOLDEN);
	float b = tex3Dlod(noise, float4(q + 0.37, frac(w + 0.31), 0.0)).r;

	return saturate(0.5 + (a + b - 1.0) * 0.7);
}

float2 IceHash2(float2 p)
{
	return frac(sin(float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)))) * 43758.5453);
}

float4 IceCell(float2 p, float scale)
{
	float2 g = p / scale;
	float2 cell = floor(g);
	float2 f = g - cell;
	float d1 = 8.0;
	float2 m1 = float2(0.0, 0.0);
	float2 id = cell;
	[unroll] for (int y = -1; y <= 1; y++)
	{
		[unroll] for (int x = -1; x <= 1; x++)
		{
			float2 o = float2(x, y);
			float2 r = o + IceHash2(cell + o) - f;
			float d = dot(r, r);
			if (d < d1)
			{
				d1 = d;
				m1 = r;
				id = cell + o;
			}
		}
	}

	return float4(m1 * scale, id);
}

float3 IceCracks(float2 p, float scale)
{
	float2 g = p / scale;
	float2 cell = floor(g);
	float2 f = g - cell;
	float d1 = 8.0;
	float d2 = 8.0;
	float2 m1 = float2(0.0, 0.0);
	float2 m2 = float2(0.0, 0.0);
	[unroll] for (int y = -1; y <= 1; y++)
	{
		[unroll] for (int x = -1; x <= 1; x++)
		{
			float2 o = float2(x, y);
			float2 r = o + IceHash2(cell + o) - f;
			float d = dot(r, r);
			if (d < d1)
			{
				d2 = d1;
				m2 = m1;
				d1 = d;
				m1 = r;
			}
			else if (d < d2)
			{
				d2 = d;
				m2 = r;
			}
		}
	}

	float2 across = normalize(m2 - m1);

	return float3(dot((m1 + m2) * 0.5, across) * scale, across);
}
