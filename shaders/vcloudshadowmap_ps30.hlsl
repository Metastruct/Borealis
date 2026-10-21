#include "include/common.hlsl"

const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);

sampler3D Shape : register(s2);
sampler3D Detail : register(s3);

#define MAP_ORIGIN Constants0.xy
#define MAP_EXTENT Constants0.z
#define TIME       Constants0.w
#define SUN_DIR    Constants1.xyz
#define BASE_Z     Constants1.w
#define COVERAGE   Constants2.x
#define MAP_SIZE   Constants2.y
#define EYE        Constants3.xyz

#define SHAPE_BLEND
#define SINGLE_SMALL_LATTICE

#include "include/cloud_volume.hlsl"

#define STEPS 16
#define MIN_SUN_Z 0.03

struct PS_IN
{
	float2 vpos : VPOS;
};

float4 main(PS_IN i) : COLOR
{
	float2 xy = MAP_ORIGIN + ((i.vpos + 0.5) / MAP_SIZE - 0.5) * MAP_EXTENT;
	float3 rise = float3(SUN_DIR.xy / max(SUN_DIR.z, MIN_SUN_Z), 1.0);
	float dz = THICK / STEPS;
	float tau = 0.0;
	[loop] for (int k = 0; k < STEPS; k++)
	{
		float h = (k + 0.5) / STEPS;
		float3 q = float3(xy, BASE_Z) + rise * (h * THICK);
		float reach = saturate(remap(length(q - EYE), MAX_RANGE, FADE_RANGE, 0.0, 1.0));
		[branch] if (reach > 0.0)
		{
			float cover = coverAt(q);
			[branch] if (h < columnTop)
			{
				tau += lightDensity(q, h, ERODE, cover, false) * reach;
			}
		}
	}

	return exp(-tau * DENSITY * dz * length(rise)).xxxx;
}
