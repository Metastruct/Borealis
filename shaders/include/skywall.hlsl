#ifndef DEPTH_SCALE
#define DEPTH_SCALE 4000.0
#endif

#define SKYWALL_SLACK 1.004
#define SKYWALL_BIAS  2.0

void ClipSkyWall(sampler wallTex, float2 vpos, float2 invSize, float viewDepth)
{
	float wall = tex2Dlod(wallTex, float4((vpos + 0.5) * invSize, 0.0, 0.0)).r * DEPTH_SCALE;
	clip(wall <= 0.0 || viewDepth <= wall * SKYWALL_SLACK + SKYWALL_BIAS ? 1.0 : -1.0);
}
