const float4x4 cModelViewProj : register(c4);

struct VS_INPUT
{
	float4 pos   : POSITION;
	float2 uv    : TEXCOORD0;
	float4 color : COLOR0;
};

struct VS_OUTPUT
{
	float4 projPos : POSITION;
	float2 uv      : TEXCOORD0;
	float4 color   : TEXCOORD1;
	float3 wpos    : TEXCOORD2;
};

VS_OUTPUT main(VS_INPUT i)
{
	VS_OUTPUT o;
	o.projPos = mul(i.pos, cModelViewProj);
	o.uv = i.uv;
	o.color = i.color;
	o.wpos = i.pos.xyz;

	return o;
}
