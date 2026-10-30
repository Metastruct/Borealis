#include "include/cover_spans.hlsl"

const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);

sampler CoverSpans : register(s2);

#define ORIGIN Constants0.xy
#define EXTENT Constants0.z
#define SIZE   Constants0.w
#define BASE_Z Constants1.x

#define SAMPLES 24
#define RADIUS 160.0
#define BELOW 56.0
#define GOLDEN 2.3999632

struct PS_IN
{
	float2 vpos : VPOS;
};

float4 main(PS_IN i) : COLOR
{
	float2 xy = ORIGIN + ((i.vpos + 0.5) / SIZE - 0.5) * EXTENT;
	float4 z = (BASE_Z + float4(0.0, 1.0, 2.0, 3.0) * COVER_EXPOSURE_STEP - COVER_SPANS_MIN) / COVER_SPANS_SIZE;
	float4 zBelow = z + BELOW / COVER_SPANS_SIZE;
	float4 open = float4(0.0, 0.0, 0.0, 0.0);
	[loop] for (int k = 0; k < SAMPLES; k++)
	{
		float s, c;
		sincos(k * GOLDEN, s, c);
		float2 col = CoverSpansColumnOf(xy + float2(c, s) * RADIUS * sqrt((k + 0.5) / SAMPLES));
		float2 uv = (col + 0.5) / float2(COVER_SPANS_COLUMNS * 2.0, COVER_SPANS_COLUMNS);
		float4 a = tex2Dlod(CoverSpans, float4(uv, 0.0, 0.0));
		float4 b = tex2Dlod(CoverSpans, float4(uv.x + 0.5, uv.y, 0.0, 0.0));
		open += float4(CoverSpansInside(a, b, z.x, zBelow.x), CoverSpansInside(a, b, z.y, zBelow.y), CoverSpansInside(a, b, z.z, zBelow.z), CoverSpansInside(a, b, z.w, zBelow.w));
	}

	return open / SAMPLES;
}
