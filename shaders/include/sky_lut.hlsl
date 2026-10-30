#define LUT_PI 3.14159265

static const float LUT_HORIZON = -acos(R_EARTH / (R_EARTH + EYE_H));

float lutRange(float l)
{
	return l >= 0.0 ? (LUT_PI * 0.5 - LUT_HORIZON) : (LUT_PI * 0.5 + LUT_HORIZON);
}

float2 lutUV(float3 dir)
{
	float az = atan2(dir.y, dir.x);
	float l = asin(clamp(dir.z, -1.0, 1.0)) - LUT_HORIZON;

	return float2(az / (2.0 * LUT_PI) + 0.5, 0.5 + 0.5 * sign(l) * sqrt(abs(l) / lutRange(l)));
}

float3 lutDir(float2 uv)
{
	float az = (uv.x - 0.5) * 2.0 * LUT_PI;
	float s = uv.y * 2.0 - 1.0;
	float elevation = sign(s) * s * s * lutRange(s) + LUT_HORIZON;
	float ce = cos(elevation);

	return float3(ce * cos(az), ce * sin(az), sin(elevation));
}
