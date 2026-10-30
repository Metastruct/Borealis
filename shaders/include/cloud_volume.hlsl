#define THICK 6000.0
#ifndef DENSITY
#define DENSITY 0.0025
#endif

#ifndef MAX_RANGE
#define MAX_RANGE 40000.0
#define FADE_RANGE 24000.0
#endif

#define LIGHT_STEPS 5
#define LIGHT_DETAIL_STEPS 2
#define LIGHT_STEP 70.0
#define LIGHT_GROW 2.2
#define LIGHT_NEAR_DISTANCE 224.0

#define SHAPE_SCALE (1.0 / 16000.0)

#define COVER_SCALE (1.0 / 47000.0)
#define COVER_SWING 3.6
#define COVER_DRIFT 0.5
#define DETAIL_SCALE (1.0 / 4800.0)
#define WIND float3(70.0, 26.0, 0.0)
#define DETAIL_WIND 2.5

#define BASE_RAMP 420.0
#define TOP_LOW 0.3
#define TALL_LO 0.6
#define TALL_HI 0.85
#define TOP_FALL 0.2
#define TOP_SLOPE 0.25
#define OVERCAST_TOP 0.75
#define SHEAR float2(610.0, 225.0)

#define HG_FWD 0.65
#define HG_BACK -0.25
#define HG_MIX 0.65
#define POWDER 2.6
#define AMBIENT_BASE 0.55
#define AMBIENT_OCCLUSION 0.5
#define ERODE 0.45
#define MEAN_DETAIL 0.5
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

static float columnTop = 1.0;

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

	columnTop = lerp(lerp(TOP_LOW, 1.0, smoothstep(TALL_LO, TALL_HI, c)), OVERCAST_TOP, smoothstep(0.55, 0.8, COVERAGE));

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

float3 sheared(float3 p, float h)
{
	return p + float3(SHEAR * h, 0.0);
}

float3 shapeCoord(float3 p, float h)
{
	return (sheared(p, h) - WIND * TIME) * SHAPE_SCALE;
}

float shapeAt(float3 p, float h)
{
#ifdef SHAPE_BLEND
	return shapeBlend(shapeCoord(p, h));
#else
	return plainShape(shapeCoord(p, h));
#endif
}

float lightShapeAt(float3 p, float h)
{
#ifdef LIGHT_PLAIN_SHAPE
	return plainShape(shapeCoord(p, h));
#else
	return shapeAt(p, h);
#endif
}

float profile(float h)
{
	float x = h / columnTop;

	return saturate(h * (THICK / BASE_RAMP)) * (1.0 - TOP_SLOPE * x) * saturate((1.0 - x) * (1.0 / TOP_FALL));
}

float baseDensity(float s, float h, float cover)
{
	return saturate(remap(s * profile(h), 1.0 - cover, 1.0, 0.0, 1.0));
}

float detailAt(float3 p, float h, float scale, float3 offset)
{
	return tex3Dlod(Detail, float4((sheared(p, h) - WIND * DETAIL_WIND * TIME) * (DETAIL_SCALE * scale) + offset, 0.0)).r;
}

float erodeBy(float d, float n, float h, float erode)
{
	float e = lerp(1.0 - n, n, saturate(h / columnTop * 4.0));

	return saturate(remap(d, e * erode, 1.0, 0.0, 1.0));
}

float densityFrom(float s, float3 p, float h, float erode, float cover)
{
	float d = baseDensity(s, h, cover);
	if (d <= 0.0)
	{
		return 0.0;
	}

	return erodeBy(d, detailAt(p, h, 1.0, 0.0), h, erode);
}

float cloudDensity(float3 p, float h, float erode, float cover)
{
	return densityFrom(shapeAt(p, h), p, h, erode, cover);
}

float lightDensity(float3 p, float h, float erode, float cover, bool detail)
{
	float d = baseDensity(lightShapeAt(p, h), h, cover);
	if (d <= 0.0)
	{
		return 0.0;
	}

	return erodeBy(d, detail ? detailAt(p, h, 1.0, 0.0) : MEAN_DETAIL, h, erode);
}

void lightMarch(inout float3 q, inout float step, inout float tau, int steps, float erode, float cover, bool detail)
{
	[loop] for (int i = 0; i < steps; i++)
	{
		q += SUN_DIR * step;
		float h = (q.z - BASE_Z) / THICK;
		if ((SUN_DIR.z >= 0.0 && h >= columnTop) || (SUN_DIR.z <= 0.0 && h <= 0.0))
		{
			break;
		}

		[branch] if (h > 0.0)
		{
			tau += lightDensity(q, h, erode, cover, detail) * DENSITY * step;
		}
		step *= LIGHT_GROW;
	}
}

float nearLightTau(float3 p, float erode, float cover)
{
	float tau = 0.0;
	float step = LIGHT_STEP;
	float3 q = p;
	lightMarch(q, step, tau, LIGHT_DETAIL_STEPS, erode, cover, true);

	return tau;
}

float lightTau(float3 p, float erode, float cover)
{
	float tau = 0.0;
	float step = LIGHT_STEP;
	float3 q = p;
	lightMarch(q, step, tau, LIGHT_DETAIL_STEPS, erode, cover, true);
	lightMarch(q, step, tau, LIGHT_STEPS - LIGHT_DETAIL_STEPS, erode, cover, false);

	return tau;
}

float hgPhase(float cosT, float g)
{
	float g2 = g * g;

	return (1.0 - g2) / pow(max(1.0 + g2 - 2.0 * g * cosT, 1e-3), 1.5);
}

float dualPhase(float cosT, float scale)
{
	return lerp(hgPhase(cosT, HG_BACK * scale), hgPhase(cosT, HG_FWD * scale), HG_MIX);
}

float3 cloudPhases(float cosSun)
{
	return float3(dualPhase(cosSun, 1.0), dualPhase(cosSun, 0.5), dualPhase(cosSun, 0.25)) * float3(1.0, 0.5, 0.25) / 1.75;
}

float sunScatter(float transmittance, float3 phases)
{
	float b1 = sqrt(transmittance);

	return dot(float3(transmittance, b1, sqrt(b1)), phases);
}

float3 cloudLight(float transmittance, float sigma, float sampleDensity, float h, float3 phases, float3 sunCol, float3 ambCol)
{
	float powder = 1.0 - exp(-sigma * POWDER * 400.0);
	float3 sun = sunCol * sunScatter(transmittance, phases) * lerp(1.0, powder, 0.7);
	float3 amb = ambCol * lerp(AMBIENT_BASE, 1.0, saturate(h / columnTop)) * lerp(1.0, AMBIENT_OCCLUSION, sampleDensity);

	return sun + amb;
}
