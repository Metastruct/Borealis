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
	float4 color   : TEXCOORD0;
	float3 wpos    : TEXCOORD1;
	float4 spos    : TEXCOORD2;
};

VS_OUTPUT main(VS_INPUT i)
{
	VS_OUTPUT o;
	o.projPos = mul(i.pos, cModelViewProj);
	o.color = i.color;
	o.wpos = i.pos.xyz;
	o.spos = o.projPos;

	return o;
}
