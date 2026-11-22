#define LOCAL_LIGHT_MAX    4.0
#define LOCAL_LIGHT_GROUND 128.0
#define LOCAL_LIGHT_TILE   1536.0

float3 LocalLight(sampler world, sampler dynamic, sampler projected, float3 p, float coverZ, float2 eye, float worldK, float dynK)
{
	float3 g = tex2D(world, frac(p.xy / LOCAL_LIGHT_TILE)).rgb;
	float hz = (p.z - coverZ) / LOCAL_LIGHT_GROUND;
	float3 ground = DynamicLightAt(dynamic, p.xy, eye) + ProjectedLightAt(projected, p.xy, eye);

	return g * g * (LOCAL_LIGHT_MAX * worldK) + ground * (dynK / (1.0 + hz * hz));
}
