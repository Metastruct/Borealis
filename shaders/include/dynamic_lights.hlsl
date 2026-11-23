#define DYNAMIC_LIGHT_CELL 64.0
#define DYNAMIC_LIGHT_CELLS 24.0
#define DYNAMIC_LIGHT_GROUND 128.0

float3 DynamicLightAt(sampler lights, float2 xy, float2 eye)
{
	float2 g = xy / DYNAMIC_LIGHT_CELL - floor(eye / DYNAMIC_LIGHT_CELL + 0.5) + DYNAMIC_LIGHT_CELLS * 0.5;
	float2 edge = saturate(min(g, DYNAMIC_LIGHT_CELLS - g) - 0.5);

	return tex2Dlod(lights, float4(g / DYNAMIC_LIGHT_CELLS, 0.0, 0.0)).rgb * 2.0 * edge.x * edge.y;
}

float3 ProjectedLightAt(sampler lights, float2 xy, float2 eye)
{
	float2 g = xy / DYNAMIC_LIGHT_CELL - floor(eye / DYNAMIC_LIGHT_CELL + 0.5) + DYNAMIC_LIGHT_CELLS * 0.5;
	float2 edge = saturate(min(g, DYNAMIC_LIGHT_CELLS - g) - 0.5);

	return tex2Dlod(lights, float4(g.x / DYNAMIC_LIGHT_CELLS, 1.0 - g.y / DYNAMIC_LIGHT_CELLS, 0.0, 0.0)).rgb * 2.0 * edge.x * edge.y;
}

float3 GroundLight(sampler dynamic, sampler projected, float3 p, float coverZ, float2 eye, float k)
{
	float hz = (p.z - coverZ) / DYNAMIC_LIGHT_GROUND;

	return (DynamicLightAt(dynamic, p.xy, eye) + ProjectedLightAt(projected, p.xy, eye)) * (k / (1.0 + hz * hz));
}
