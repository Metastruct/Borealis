#define COVER_SPANS_MIN -16384.0
#define COVER_SPANS_SIZE 32768.0
#define COVER_SPANS_COLUMNS 1024.0

float CoverSpansOpen(sampler spans, float3 p, float below)
{
	float2 col = floor((p.xy - COVER_SPANS_MIN) / COVER_SPANS_SIZE * COVER_SPANS_COLUMNS);
	float2 uv = (col + 0.5) / float2(COVER_SPANS_COLUMNS * 2.0, COVER_SPANS_COLUMNS);
	float4 a = tex2Dlod(spans, float4(uv, 0.0, 0.0));
	float4 b = tex2Dlod(spans, float4(uv.x + 0.5, uv.y, 0.0, 0.0));
	float z = (p.z - COVER_SPANS_MIN) / COVER_SPANS_SIZE;
	float zBelow = z + below / COVER_SPANS_SIZE;
	float4 inside = step(z, float4(a.x, a.z, b.x, b.z)) * step(float4(a.y, a.w, b.y, b.w), zBelow);

	return saturate(dot(inside, 1.0));
}
