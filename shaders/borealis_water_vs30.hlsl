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
	float4 spos    : TEXCOORD3;
	float4 row0    : TEXCOORD4;
	float4 row1    : TEXCOORD5;
	float4 row2    : TEXCOORD6;
	float4 row3    : TEXCOORD7;
};

VS_OUTPUT main(VS_INPUT i)
{
	VS_OUTPUT o;
	o.projPos = mul(i.pos, cModelViewProj);
	o.spos    = o.projPos;
	o.uv      = i.uv;
	o.color   = i.color;
	o.wpos    = i.pos.xyz;
	o.row0    = cModelViewProj[0];
	o.row1    = cModelViewProj[1];
	o.row2    = cModelViewProj[2];
	o.row3    = cModelViewProj[3];

	return o;
}
