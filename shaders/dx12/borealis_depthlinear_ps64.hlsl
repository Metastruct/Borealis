float4 Constants0 : register(c0);

Texture2D<float> DepthTex : register(t0);

#define ZNEAR Constants0.x
#define ZFAR  Constants0.y

struct PS_IN
{
	float4 pos   : SV_Position;
	float2 uv    : TEXCOORD0;
	float4 color : TEXCOORD1;
};

float4 main(PS_IN i) : SV_Target
{
	float d = DepthTex.Load(int3(i.pos.xy, 0));
	if (d <= 0.0)
	{
		return float4(1.0, 0.0, 0.0, 1.0);
	}

	float z = ZNEAR * ZFAR / (ZNEAR + d * (ZFAR - ZNEAR));

	return float4(z / 4000.0, 0.0, 0.0, 1.0);
}
