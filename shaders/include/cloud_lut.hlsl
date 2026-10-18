#define CLOUD_LUT_PI 3.14159265
#define CLOUD_LUT_SPLIT 0.25

float2 cloudLutUV(float3 dir, float side)
{
	float az = atan2(dir.y, dir.x);
	float e = asin(clamp(dir.z * side, -1.0, 1.0)) * (2.0 / CLOUD_LUT_PI);
	float v = e >= 0.0 ? CLOUD_LUT_SPLIT + (1.0 - CLOUD_LUT_SPLIT) * e : CLOUD_LUT_SPLIT * (1.0 + e);

	return float2(az / (2.0 * CLOUD_LUT_PI) + 0.5, v);
}

float3 cloudLutDir(float2 uv, float side)
{
	float e = uv.y >= CLOUD_LUT_SPLIT ? (uv.y - CLOUD_LUT_SPLIT) / (1.0 - CLOUD_LUT_SPLIT) : uv.y / CLOUD_LUT_SPLIT - 1.0;
	float elev = e * (CLOUD_LUT_PI * 0.5);
	float az = (uv.x - 0.5) * (2.0 * CLOUD_LUT_PI);
	float ce = cos(elev);

	return float3(ce * cos(az), ce * sin(az), sin(elev) * side);
}
