#ifdef DX12
#define DX9_HALF_TEXEL(t) ((t) * 0.0)
#else
#define DX9_HALF_TEXEL(t) (t)
#endif

float DeviceDepth(float d)
{
#ifdef DX12
	return 1.0 - d;
#else
	return d;
#endif
}
