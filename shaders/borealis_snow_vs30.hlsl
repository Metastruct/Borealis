const float4 cEyePosWaterZ : register(c2);
const float4x4 cViewProj : register(c8);
const float3 cAmbientCube[6] : register(c21);

#define EYE      cEyePosWaterZ.xyz
#define TIME     cAmbientCube[0].x
#define COUNT    cAmbientCube[0].y
#define PIXEL    cAmbientCube[0].z
#define RIGHT    cAmbientCube[1]
#define UP       cAmbientCube[2]
#define DRIFT    cAmbientCube[3].xy

#define TILE        256.0
#define PERIOD      160.0
#define WRAP        64.0
#define SPEED_STEP  (PERIOD / WRAP)
#define SPEED_MIN   14.0
#define SPEED_STEPS 12.0
#define SIZE_MIN    1.0
#define SIZE_MAX    2.0
#define MIN_PIXELS  1.5
#define SWAY        5.0
#define SLANT       0.15
#define SLANT_SPAN  1000.0
#define REST        3.0
#define FADE_END    760.0
#define Z_FADE_END  400.0
#define PI          3.14159265

struct VS_INPUT
{
	float4 pos : POSITION;
	float2 uv  : TEXCOORD0;
};

struct VS_OUTPUT
{
	float4 projPos : POSITION;
	float2 uv      : TEXCOORD0;
	float3 centre  : TEXCOORD1;
	float2 info    : TEXCOORD2;
};

float3 hash33(float3 p)
{
	p = frac(p * float3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);

	return frac((p.xxy + p.yxx) * p.zyx);
}

VS_OUTPUT main(VS_INPUT i)
{
	VS_OUTPUT o = (VS_OUTPUT)0;
	o.projPos = float4(0.0, 0.0, -1.0, 1.0);

	float p = i.uv.x;
	float rep = floor(i.uv.y / 4.0 + 0.01);
	float corner = i.uv.y - rep * 4.0;
	if (p >= COUNT)
	{
		return o;
	}

	float2 base = i.pos.xy;
	float coverZ = i.pos.z;
	if (length(base - EYE.xy) > FADE_END + SWAY + (SLANT + length(DRIFT)) * SLANT_SPAN)
	{
		return o;
	}

	float2 local = fmod(base, TILE);
	float3 hA = hash33(float3(local, p));
	float3 hB = hash33(float3(local, p + 0.37));
	float3 hC = hash33(float3(local, p + 0.71));

	float speed = (SPEED_MIN + floor(hA.z * SPEED_STEPS)) * SPEED_STEP;
	float size = lerp(SIZE_MIN, SIZE_MAX, hB.y);
	float zRest = coverZ + size * 0.5;
	float z0 = frac((hB.x * PERIOD - TIME * speed) / PERIOD) * PERIOD;
	float zLow = max(EYE.z - Z_FADE_END, zRest) - REST * speed;
	float zv = (floor((zLow - z0) / PERIOD) + rep) * PERIOD + z0;

	float rest = max(zRest - zv, 0.0) / speed;
	if (rest >= REST)
	{
		return o;
	}

	float z = max(zv, zRest);
	if (z < EYE.z - Z_FADE_END || z > EYE.z + Z_FADE_END)
	{
		return o;
	}

	float t = TIME - rest;
	float sw = 2.0 * PI * (1.0 + floor(hB.y * 3.0)) / WRAP;
	float2 slant = (hC.xy - 0.5) * 2.0 * SLANT;
	float2 sway = float2(sin(t * sw + hB.z * 2.0 * PI), cos(t * sw * 2.0 + hC.z * 2.0 * PI)) * SWAY * hC.x;
	float3 centre = float3(base + sway + (slant + DRIFT) * min(z - coverZ, SLANT_SPAN), z);

	float dist = length(centre - EYE);
	if (dist > FADE_END)
	{
		return o;
	}

	float s = max(size, PIXEL * dist * MIN_PIXELS);
	float2 c = float2(corner > 0.5 && corner < 2.5 ? 1.0 : -1.0, corner > 1.5 ? 1.0 : -1.0);
	float3 world = centre + (RIGHT * c.x + UP * c.y) * s;

	o.projPos = mul(float4(world, 1.0), cViewProj);
	o.uv = c;
	o.centre = centre;
	o.info = float2((size / s) * (size / s), 1.0 - smoothstep(REST * 0.4, REST, rest));

	return o;
}
