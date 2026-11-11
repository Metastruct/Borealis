const float4x4 cModelViewProj : register(c4);

#ifdef WIND_LEAN
const float3 cAmbientCube[6] : register(c21);

#define TIME     cAmbientCube[0].x
#define LEAN     cAmbientCube[0].y
#define QUAD_H   cAmbientCube[0].z
#define WIND_DIR float2(0.9396926, 0.3420201)
#define LEAN_MAX 0.95
#define PUSH_LEAN 0.85
#define PUSH_ABOVE 40.0
#define PUSH_BELOW 32.0

float2 Push(float3 slot, float3 root)
{
	float2 centre = float2(slot.x, floor(slot.y));
	float radius = max(frac(slot.y) * 128.0, 1.0);
	float strength = frac(slot.z) / 0.99;
	float2 d = root.xy - centre;
	float dist = length(d);
	float k = saturate(1.0 - dist / radius);
	k = k * k * (3.0 - 2.0 * k);
	float dz = floor(slot.z) - root.z;
	float vertical = saturate(1.0 - max(dz, 0.0) / PUSH_ABOVE) * saturate(1.0 + min(dz, 0.0) / PUSH_BELOW);

	return d / max(dist, 1e-3) * (k * strength * vertical * PUSH_LEAN);
}
#endif

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
	float seed1 = i.color.a * 255.0;
	float4 pos = i.pos;

#ifdef WIND_LEAN
	float heightScale = 0.5 + floor(i.uv.x * 0.5 + 0.001) / 7.0 * 0.9;
	float h = QUAD_H * heightScale * (1.0 - i.uv.y);
	float3 root = float3(pos.xy, pos.z - h);
	float2 lean = WIND_DIR * min(LEAN * (0.5 + 0.5 * GrassGust(pos.xy, WIND_DIR, TIME, seed1)), LEAN_MAX);
	[branch] if (frac(cAmbientCube[1].z) > 0.0)
	{
		lean += Push(cAmbientCube[1], root) + Push(cAmbientCube[2], root) + Push(cAmbientCube[3], root) + Push(cAmbientCube[4], root) + Push(cAmbientCube[5], root);
	}
	float s = length(lean);
	lean *= min(s, LEAN_MAX) / max(s, 1e-4);
	s = min(s, LEAN_MAX);
	pos.xy += lean * h;
	pos.z -= h * (1.0 - sqrt(1.0 - s * s));
#endif

	o.projPos = mul(pos, cModelViewProj);
	o.uv = i.uv;
	o.color = i.color;
	o.wpos = pos.xyz;

	float2 seed = float2(seed1, seed1 * 1.37 + 5.0);
	o.blade0 = blade(seed, 0.0);
	o.blade1 = blade(seed, 1.0);
	o.blade2 = blade(seed, 2.0);
	o.blade3 = blade(seed, 3.0);
	o.blade4 = blade(seed, 4.0);

	return o;
}
