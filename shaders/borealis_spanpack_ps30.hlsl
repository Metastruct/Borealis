#include "include/cover_spans.hlsl"

sampler SpanBytes : register(s1);

struct PS_IN
{
	float2 vpos : VPOS;
};

float Unpack(float2 bytes)
{
	float2 b = floor(bytes * 255.0 + 0.5);

	return (b.y * 256.0 + b.x) / 65535.0;
}

float4 main(PS_IN i) : COLOR
{
	float2 texel = floor(i.vpos);
	float v = (texel.y + 0.5) / COVER_SPANS_COLUMNS;
	float4 a = tex2Dlod(SpanBytes, float4((texel.x * 2.0 + 0.5) / (COVER_SPANS_COLUMNS * 4.0), v, 0.0, 0.0));
	float4 b = tex2Dlod(SpanBytes, float4((texel.x * 2.0 + 1.5) / (COVER_SPANS_COLUMNS * 4.0), v, 0.0, 0.0));

	return float4(Unpack(a.rg), Unpack(a.ba), Unpack(b.rg), Unpack(b.ba));
}
