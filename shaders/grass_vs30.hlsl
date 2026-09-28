const float4x4 cModelViewProj : register(c4);

#define BLADES 5

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
	float4 blade0  : TEXCOORD3;
	float4 blade1  : TEXCOORD4;
	float4 blade2  : TEXCOORD5;
	float4 blade3  : TEXCOORD6;
	float4 blade4  : TEXCOORD7;
};

float hash(float2 p)
{
	return frac(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

float4 blade(float2 seed, float k)
{
	float2 s = seed + float2(k * 7.31, k * 3.17);
	float root = 0.08 + 0.84 * hash(s);
	float height = 0.3 + 0.7 * sqrt(hash(s + 1.3));
	float lean = (hash(s + 2.7) - 0.5) * 0.7;
	float width = 0.018 + 0.028 * hash(s + 4.1);

	return float4(root, height, lean, width);
}

VS_OUTPUT main(VS_INPUT i)
{
	VS_OUTPUT o;
	o.projPos = mul(i.pos, cModelViewProj);
	o.uv = i.uv;
	o.color = i.color;
	o.wpos = i.pos.xyz;

	float seed1 = i.color.a * 255.0;
	float2 seed = float2(seed1, seed1 * 1.37 + 5.0);
	o.blade0 = blade(seed, 0.0);
	o.blade1 = blade(seed, 1.0);
	o.blade2 = blade(seed, 2.0);
	o.blade3 = blade(seed, 3.0);
	o.blade4 = blade(seed, 4.0);

	return o;
}
