#define THICK 3500.0
#define DENSITY 0.0025

#ifndef MAX_RANGE
#define MAX_RANGE 40000.0
#define FADE_RANGE 24000.0
#endif

#define LIGHT_STEPS 5
#define LIGHT_STEP 260.0
#define LIGHT_GROW 1.6

#define SHAPE_SCALE (1.0 / 16000.0)

#define COVER_SCALE (1.0 / 47000.0)
#define COVER_SWING 3.6
#define COVER_DRIFT 0.5
#define DETAIL_SCALE (1.0 / 4800.0)
#define WIND float3(70.0, 26.0, 0.0)
#define DETAIL_WIND 2.5

#define HG_G 0.42
#define POWDER 2.6
#define AMBIENT_BASE 0.55
#define ERODE 0.45
#define LOG_RANGE 12.0

float decodeScale(float v)
{
	return exp2((v * 2.0 - 1.0) * LOG_RANGE);
}

float3 unpackFog(float v)
{
	float start = floor(v / 65536.0);
	v -= start * 65536.0;
	float range = floor(v / 256.0);

	return float3(start * 64.0, max(range * 128.0, 1.0), (v - range * 256.0) / 255.0);
}

float heightFraction(float3 p)
{
	return saturate((p.z - BASE_Z) / THICK);
}

#ifdef SHAPE_BLEND
#define SHAPE_MEAN 0.63
#define BIG_SCALE 0.3

static float latticeMix = 0.0;
static float bigMix = 0.0;
#endif

float coverAt(float3 p)
{
	float2 q = (p.xy - WIND.xy * TIME * COVER_DRIFT) * COVER_SCALE;
	float c = tex3Dlod(Shape, float4(q, 0.37, 0.0)).r;
	float k = saturate((c - 0.35) * COVER_SWING);
#ifdef SHAPE_BLEND
	latticeMix = smoothstep(0.55, 0.72, c);
	bigMix = smoothstep(0.55, 0.8, c);
#endif

	k = lerp(k, 1.0, smoothstep(0.45, 0.75, COVERAGE));

	return saturate(COVERAGE * k);
}

float plainShape(float3 q)
{
	return tex3Dlod(Shape, float4(q, 0.0)).r;
}

#ifdef SHAPE_BLEND
float smallShape(float3 q)
{
#ifdef SINGLE_SMALL_LATTICE
	return plainShape(q);
#else
	float3 r = float3(dot(q.xy, float2(0.7986, -0.6018)), dot(q.xy, float2(0.6018, 0.7986)), q.z) * 0.7236 + float3(0.31, 0.57, 0.13);
	float m = latticeMix;
	[branch] if (m <= 0.0)
	{
		return plainShape(q);
	}

	[branch] if (m >= 1.0)
	{
		return plainShape(r);
	}

	float a = plainShape(q);
	float b = plainShape(r);

	return SHAPE_MEAN + (lerp(a, b, m) - SHAPE_MEAN) * rsqrt(m * m + (1.0 - m) * (1.0 - m));
#endif
}

float shapeBlend(float3 q)
{
	float3 r = float3(dot(q.xy, float2(0.2588, 0.9659)), dot(q.xy, float2(-0.9659, 0.2588)), q.z) * float3(BIG_SCALE, BIG_SCALE, 1.0) + float3(0.71, 0.23, 0.0);

	return max(smallShape(q), plainShape(r) * lerp(0.95, 1.1, bigMix));
}
#endif

float densityFrom(float s, float3 p, float h, float erode, float cover)
{
	float grad = saturate(remap(h, 0.0, 0.12, 0.0, 1.0)) * saturate(remap(h, 0.5, 1.0, 1.0, 0.0));
	float d = saturate(remap(s * grad, 1.0 - cover, 1.0, 0.0, 1.0));
	if (d <= 0.0)
	{
		return 0.0;
	}

	float n = tex3Dlod(Detail, float4((p - WIND * DETAIL_WIND * TIME) * DETAIL_SCALE, 0.0)).r;
	float e = lerp(1.0 - n, n, saturate(h * 4.0));

	return saturate(remap(d, e * erode, 1.0, 0.0, 1.0));
}

float cloudDensity(float3 p, float h, float erode, float cover)
{
	float3 q = (p - WIND * TIME) * SHAPE_SCALE;
#ifdef SHAPE_BLEND
	float s = shapeBlend(q);
#else
	float s = plainShape(q);
#endif

	return densityFrom(s, p, h, erode, cover);
}

float lightDensity(float3 p, float h, float erode, float cover)
{
#ifdef LIGHT_PLAIN_SHAPE
	return densityFrom(plainShape((p - WIND * TIME) * SHAPE_SCALE), p, h, erode, cover);
#else
	return cloudDensity(p, h, erode, cover);
#endif
}

float lightTau(float3 p, float erode, float cover)
{
	float tau = 0.0;
	float step = LIGHT_STEP;
	float3 q = p;
	for (int i = 0; i < LIGHT_STEPS; i++)
	{
		q += SUN_DIR * step;
		float h = heightFraction(q);
		if (h > 0.0 && h < 1.0)
		{
			tau += lightDensity(q, h, erode, cover) * DENSITY * step;
		}
		step *= LIGHT_GROW;
	}

	return tau;
}
