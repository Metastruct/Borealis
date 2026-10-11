float GrassGust(float2 p, float2 windDir, float time, float seed)
{
	float along = dot(p, windDir);

	return sin(time * 1.2 - along * 0.006) * 0.55
	     + sin(time * 0.45 - along * 0.0015 + 1.7) * 0.35
	     + sin(time * 3.1 - along * 0.02 + seed * 0.7) * 0.15 + 0.35;
}
