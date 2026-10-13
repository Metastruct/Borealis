#define RAIN_RIPPLE_CELL 20.0
#define RAIN_RIPPLE_RATE 1.3
#define RAIN_HEAVY_CELL 13.0
#define RAIN_HEAVY_RATE 2.1
#define RAIN_HEAVY_START 0.5
#define RAIN_HEAVY_FAR_BLUR 0.6
#define RAIN_RIPPLE_RADIUS 6.0
#define RAIN_RIPPLE_FREQ 3.0
#define RAIN_RIPPLE_SHARP 0.4
#define RAIN_RIPPLE_STRENGTH 0.4
#define RAIN_RIPPLE_FADE_START 600.0
#define RAIN_RIPPLE_FADE_END 1200.0

float2 RainHash(float2 p)
{
	float3 p3 = frac(p.xyx * float3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);

	return frac((p3.xx + p3.yz) * p3.zy);
}

float2 RainRipple(float2 q, float seed, float size, float rate, float density, float time)
{
	float2 cell = floor(q / size);
	float cycle = time * rate + RainHash(cell + seed).x;
	float phase = frac(cycle);
	float2 drop = RainHash(cell + seed + floor(cycle) * 17.31);
	float2 v = q - (cell + 0.25 + 0.5 * drop) * size;
	float d = length(v);
	float x = d - phase * RAIN_RIPPLE_RADIUS * size / RAIN_RIPPLE_CELL;
	float fade = (1.0 - phase) * (1.0 - phase) * step(frac((drop.x + drop.y) * 31.7), density);

	return v / max(d, 1e-3) * cos(x * RAIN_RIPPLE_FREQ) * exp(-x * x * RAIN_RIPPLE_SHARP) * fade;
}

float RainHeavy(float rain)
{
	return saturate((rain - RAIN_HEAVY_START) / (1.0 - RAIN_HEAVY_START));
}

float RainNear(float distance)
{
	return saturate((RAIN_RIPPLE_FADE_END - distance) / (RAIN_RIPPLE_FADE_END - RAIN_RIPPLE_FADE_START));
}

float2 RainRipples(float2 p, float rain, float time)
{
	float heavy = RainHeavy(rain);
	float2 slope = RainRipple(p, 0.0, RAIN_RIPPLE_CELL, RAIN_RIPPLE_RATE, rain, time) + RainRipple(p + RAIN_RIPPLE_CELL * 0.5, 37.0, RAIN_RIPPLE_CELL, RAIN_RIPPLE_RATE, rain, time);
	[branch] if (heavy > 0.0)
	{
		slope += RainRipple(p, 71.0, RAIN_HEAVY_CELL, RAIN_HEAVY_RATE, heavy, time) + RainRipple(p + RAIN_HEAVY_CELL * 0.5, 113.0, RAIN_HEAVY_CELL, RAIN_HEAVY_RATE, heavy, time);
	}

	return slope * RAIN_RIPPLE_STRENGTH;
}
