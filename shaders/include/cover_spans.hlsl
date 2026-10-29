#define COVER_SPANS_MIN -16384.0
#define COVER_SPANS_SIZE 32768.0
#define COVER_SPANS_COLUMNS 1024.0

#define COVER_EXPOSURE_STEP 256.0
#define COVER_EXPOSURE_EDGE 0.1

float2 CoverSpansColumnOf(float2 xy)
{
	return floor((xy - COVER_SPANS_MIN) / COVER_SPANS_SIZE * COVER_SPANS_COLUMNS);
}

float CoverSpansInside(float4 a, float4 b, float z, float zBelow)
{
	float4 inside = step(z, float4(a.x, a.z, b.x, b.z)) * step(float4(a.y, a.w, b.y, b.w), zBelow);

	return saturate(dot(inside, 1.0));
}

float CoverSpansColumn(sampler spans, float2 col, float z, float zBelow)
{
	float2 uv = (col + 0.5) / float2(COVER_SPANS_COLUMNS * 2.0, COVER_SPANS_COLUMNS);
	float4 a = tex2Dlod(spans, float4(uv, 0.0, 0.0));
	float4 b = tex2Dlod(spans, float4(uv.x + 0.5, uv.y, 0.0, 0.0));

	return CoverSpansInside(a, b, z, zBelow);
}

float CoverSpansOpen(sampler spans, float3 p, float below)
{
	float z = (p.z - COVER_SPANS_MIN) / COVER_SPANS_SIZE;

	return CoverSpansColumn(spans, CoverSpansColumnOf(p.xy), z, z + below / COVER_SPANS_SIZE);
}

float CoverSpansOpenSmooth(sampler spans, float3 p, float below)
{
	float2 g = (p.xy - COVER_SPANS_MIN) / COVER_SPANS_SIZE * COVER_SPANS_COLUMNS - 0.5;
	float2 col = floor(g);
	float2 f = g - col;
	float z = (p.z - COVER_SPANS_MIN) / COVER_SPANS_SIZE;
	float zBelow = z + below / COVER_SPANS_SIZE;
	float o00 = CoverSpansColumn(spans, col, z, zBelow);
	float o10 = CoverSpansColumn(spans, col + float2(1.0, 0.0), z, zBelow);
	float o01 = CoverSpansColumn(spans, col + float2(0.0, 1.0), z, zBelow);
	float o11 = CoverSpansColumn(spans, col + float2(1.0, 1.0), z, zBelow);

	return lerp(lerp(o00, o10, f.x), lerp(o01, o11, f.x), f.y);
}

float CoverSpansExposure(sampler spans, float3 p, float radius, float below, float twist)
{
	float open = 0.0;
	[unroll] for (int k = 0; k < 8; k++)
	{
		float s, c;
		sincos(twist + k * 0.78539816, s, c);
		open += CoverSpansOpen(spans, float3(p.xy + float2(c, s) * radius, p.z), below);
	}

	return open / 8.0;
}

float2 CoverExposureAt(sampler exposure, float3 p, float4 frame)
{
	float2 uv = (p.xy - frame.xy) * frame.z + 0.5;
	float window = saturate(min(min(uv.x, uv.y), min(1.0 - uv.x, 1.0 - uv.y)) / COVER_EXPOSURE_EDGE);
	float4 e = tex2Dlod(exposure, float4(uv, 0.0, 0.0));
	float u = clamp((p.z - frame.w) / COVER_EXPOSURE_STEP, 0.0, 3.0);
	float4 w = saturate(1.0 - abs(u - float4(0.0, 1.0, 2.0, 3.0)));

	return float2(dot(e, w), window);
}
