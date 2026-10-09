#define DEPTH_SCALE 4000.0
#define SKY_EPS     0.0005
#define SLICES      32.0
#define SLICE_NEAR  16.0
#define SLICE_RATIO 1.2219785 // (8000 / 16) ^ (1 / 31)
#define SLICE_SLACK 1.02
#define SLICE_EXACT 64.0

float ExactDepthAlpha(float viewDepth)
{
	return (SLICE_EXACT + log(max(viewDepth, SLICE_NEAR) / SLICE_NEAR) / log(SLICE_RATIO)) / 255.0;
}

bool IsSkyDepth(float raw)
{
	return raw <= 0.0 || abs(raw - 1.0) < SKY_EPS;
}

float SliceDepth(float d, float code, float samples)
{
	float ks = floor(code + 0.5) - 1.0;
	if (code > SLICE_EXACT - 0.5)
	{
		if (d > SLICE_NEAR * pow(SLICE_RATIO, code - SLICE_EXACT + 1.0))
		{
			d = SLICE_NEAR * pow(SLICE_RATIO, code - SLICE_EXACT);
		}
	}
	else
	{
		d = max(d, SLICE_NEAR * pow(SLICE_RATIO, SLICES - 1.0 - samples * (SLICES - code)) / SLICE_SLACK);
		if (ks < SLICES - 1.0 && d > SLICE_NEAR * pow(SLICE_RATIO, ks + 1.0) * SLICE_SLACK)
		{
			d = SLICE_NEAR * pow(SLICE_RATIO, ks + 0.5);
		}
	}

	return d;
}
