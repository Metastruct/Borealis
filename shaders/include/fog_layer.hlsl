float FogLayerDepth(float density, float base, float falloff, float z0, float z1, float length)
{
	float u0 = max(z0 - base, 0.0) / falloff;
	float u1 = max(z1 - base, 0.0) / falloff;
	float du = u1 - u0;
	float mean = abs(du) > 1e-3 ? (exp(-u0) - exp(-u1)) / du : exp(-u0);

	return density * length * mean;
}
