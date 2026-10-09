float3 unpackColor(float v)
{
	float r = floor(v / 65536.0);
	v -= r * 65536.0;
	float g = floor(v / 256.0);
	float b = v - g * 256.0;

	return float3(r, g, b) / 255.0;
}

float hash(float2 p)
{
	return frac(dot(p, float2(0.3183, 0.3679)) * 17.31 + p.x * p.y * 0.0117);
}

float remap(float v, float a, float b, float c, float d)
{
	return c + (v - a) * (d - c) / (b - a);
}
