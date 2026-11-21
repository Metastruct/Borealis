#include "include/common.hlsl"

const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);

sampler3D Shape : register(s2);
sampler3D Detail : register(s3);

#define MAP_ORIGIN Constants0.xy
#define MAP_EXTENT Constants0.z
#define TIME       Constants0.w
#define SUN_DIR    Constants1.xyz
#define BASE_Z     Constants1.w
#define COVERAGE   Constants2.x
#define MAP_SIZE   Constants2.y
#define DENSITY_GAIN Constants2.z
#define DENSITY (BASE_DENSITY * DENSITY_GAIN)
#define OVERCAST   Constants2.w
#define OVERCAST_MIX OVERCAST
#define OVERCAST_TOP 0.35

#define SHAPE_BLEND
#define SINGLE_SMALL_LATTICE
#define LIGHT_PLAIN_SHAPE

#include "include/cloud_volume.hlsl"

#define MAP_DISTANCE 2724.0
#define MAP_STEPS 6

struct PS_IN
{
	float2 vpos : VPOS;
};

float layerTransmittance(float2 xy, float layer, float cover)
{
	float3 q = float3(xy, BASE_Z + (layer + 0.5) * 0.25 * THICK);
	float ds = MAP_DISTANCE / MAP_STEPS;
	float tau = 0.0;
	[loop] for (int k = 0; k < MAP_STEPS; k++)
	{
		float3 s = q + SUN_DIR * ((k + 0.5) * ds);
		float h = (s.z - BASE_Z) / THICK;
		[branch] if (h > 0.0 && h < columnTop)
		{
			tau += lightDensity(s, h, ERODE, cover, false);
		}
	}

	return exp(-tau * DENSITY * ds);
}

float4 main(PS_IN i) : COLOR
{
	float2 xy = MAP_ORIGIN + ((i.vpos + 0.5) / MAP_SIZE - 0.5) * MAP_EXTENT;
	float cover = coverAt(float3(xy, BASE_Z));

	return float4(layerTransmittance(xy, 0.0, cover), layerTransmittance(xy, 1.0, cover), layerTransmittance(xy, 2.0, cover), layerTransmittance(xy, 3.0, cover));
}
