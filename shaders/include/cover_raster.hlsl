const float4 RasterView : register(c15);
const float4 RasterInfo : register(c16);

sampler Raster : register(s7);

#define RASTER_CUT   RasterInfo.x
#define RASTER_ON    RasterInfo.y
#define RASTER_SIZE  RasterInfo.z
#define RASTER_SCALE 4000.0
#define RASTER_SHORE_DEPTH 8.0

float2 RasterPixel(float3 p)
{
	float2 s = (p.xy - RasterView.xy) * (RasterView.w / (RasterView.z - p.z));

	return float2(s.x, -s.y) * (RASTER_SIZE * 0.5) + RASTER_SIZE * 0.5;
}

bool RasterInside(float2 px)
{
	return RASTER_ON > 0.5 && all(px >= 0.0) && all(px <= RASTER_SIZE - 1.0);
}

float RasterHeight(float2 texel)
{
	return RasterView.z - RASTER_SCALE * tex2Dlod(Raster, float4((texel + 0.5) / RASTER_SIZE, 0.0, 0.0)).r;
}

float RasterBlockZ(float3 p, float columnZ, float shore)
{
	float2 px = RasterPixel(p);
	[branch] if (columnZ > RASTER_CUT || !RasterInside(px))
	{
		return columnZ;
	}

	float offset = shore * 255.0;
	float level = offset < 254.5 ? columnZ - offset / 254.0 * RASTER_SHORE_DEPTH : -1e9;

	return max(RasterHeight(floor(px)), level);
}
