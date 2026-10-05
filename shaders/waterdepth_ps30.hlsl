#define DEPTH_SCALE 4000.0

struct PS_IN
{
	float2 uv    : TEXCOORD0;
	float4 color : TEXCOORD1;
	float3 wpos  : TEXCOORD2;
	float4 spos  : TEXCOORD3;
};

float4 main(PS_IN i) : COLOR
{
	float d = i.spos.w / DEPTH_SCALE;

	return float4(d, d, d, 1.0);
}
