#define LOCAL_LIGHT_MAX  4.0
#define LOCAL_LIGHT_TILE 1536.0

float3 WorldLight(sampler world, float2 xy, float k)
{
	float3 g = tex2D(world, frac(xy / LOCAL_LIGHT_TILE)).rgb;

	return g * g * (LOCAL_LIGHT_MAX * k);
}
