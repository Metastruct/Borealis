const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);

#define FWD        Constants0.xyz
#define BRIGHTNESS Constants0.w
#define RIGHT_S    Constants1.xyz
#define HALF_H     Constants1.w
#define SUN_DIR    Constants2.xyz
#define MOON_RGB   Constants2.w
#define SUN_I      20.0
#define MOON_DIR   Constants3.xyz
#define MOON_I     Constants3.w

// km
#define R_EARTH 6371.0
#define R_ATMO  6471.0
#define H_R     8.0
#define H_M     1.2
#define EYE_H   0.2
static const float3 BETA_R = float3(5.8e-3, 13.5e-3, 33.1e-3);
static const float3 BETA_O = float3(0.65e-3, 1.881e-3, 0.085e-3);
#define O_CENTER 25.0 // ozone layer: tent profile, km
#define O_WIDTH  15.0
#define BETA_M  5e-3
#define MIE_G   0.76
#define MIE_EXT 1.1

#define N_VIEW  12
#define N_LIGHT 4

#define SUN_DISC_COS 0.9997
#define SUN_DISC 0.15
#define GROUND_ALBEDO 0.18
#define EXPOSURE 1.2
#define MOON_SKIP_Z 0.15

struct PS_IN
{
	float2 uv : TEXCOORD0;
};

float exitDist(float3 o, float3 d, float r)
{
	float b = dot(o, d);
	float c = dot(o, o) - r * r;

	return -b + sqrt(max(b * b - c, 0.0));
}

// x = Rayleigh, y = Mie, z = ozone density at altitude h
float3 density(float h)
{
	h = max(h, 0.0);
	float2 e = exp(-h / float2(H_R, H_M));

	return float3(e, saturate(1.0 - abs(h - O_CENTER) / O_WIDTH));
}

float3 extinction(float3 od)
{
	return BETA_R * od.x + BETA_M * MIE_EXT * od.y + BETA_O * od.z;
}

float3 lightDepth(float3 p, float3 l, out float lit)
{
	float b = dot(p, l);
	float c = dot(p, p) - R_EARTH * R_EARTH;
	lit = (b < 0.0 && b * b > c) ? 0.0 : 1.0;

	float len = exitDist(p, l, R_ATMO);
	float ds = len / N_LIGHT;
	float3 od = 0.0;
	for (int i = 0; i < N_LIGHT; i++)
	{
		float3 q = p + l * (ds * (i + 0.5));
		od += density(length(q) - R_EARTH) * ds;
	}

	return od;
}

float3 scatter(float3 o, float3 dir, float len, float3 l, float3 lightCol, out float3 transmittance)
{
	float mu = dot(dir, l);
	float phaseR = 3.0 / (16.0 * 3.14159265) * (1.0 + mu * mu);
	float g2 = MIE_G * MIE_G;
	float phaseM = 3.0 / (8.0 * 3.14159265) * (1.0 - g2) * (1.0 + mu * mu) / ((2.0 + g2) * pow(1.0 + g2 - 2.0 * MIE_G * mu, 1.5));

	float3 odView = 0.0;
	float3 sumR = 0.0;
	float3 sumM = 0.0;
	float tPrev = 0.0;
	for (int i = 0; i < N_VIEW; i++)
	{
		float u1 = (i + 1.0) / N_VIEW;
		float tNext = len * u1 * u1;
		float ds = tNext - tPrev;
		float3 q = o + dir * (tPrev + ds * 0.5);
		tPrev = tNext;
		float3 dens = density(length(q) - R_EARTH) * ds;
		odView += dens;

		float lit;
		float3 odLight = lightDepth(q, l, lit);
		float3 attn = exp(-extinction(odView + odLight)) * lit;
		sumR += attn * dens.x;
		sumM += attn * dens.y;
	}

	transmittance = exp(-extinction(odView));

	return lightCol * (sumR * BETA_R * phaseR + sumM * BETA_M * phaseM);
}

float hash12(float2 p)
{
	return frac(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

float3 unpackColor(float v)
{
	float r = floor(v / 65536.0);
	v -= r * 65536.0;
	float g = floor(v / 256.0);
	float b = v - g * 256.0;

	return float3(r, g, b) / 255.0;
}

float4 main(PS_IN i) : COLOR
{
	float2 ndc = float2(i.uv.x * 2.0 - 1.0, 1.0 - i.uv.y * 2.0);
	float3 up = normalize(cross(RIGHT_S, FWD)) * HALF_H;
	float3 dir = normalize(FWD + RIGHT_S * ndc.x + up * ndc.y);

	float3 o = float3(0.0, 0.0, R_EARTH + EYE_H);

	float b = dot(o, dir);
	float c = dot(o, o) - R_EARTH * R_EARTH;
	float disc = b * b - c;
	bool ground = b < 0.0 && disc > 0.0;
	float len = ground ? (-b - sqrt(disc)) : exitDist(o, dir, R_ATMO);

	float3 sunCol = float3(1.0, 0.96, 0.9) * SUN_I;
	float3 moonCol = unpackColor(MOON_RGB) * (SUN_I * MOON_I);

	float3 tSun, tMoon;
	float3 col = scatter(o, dir, len, SUN_DIR, sunCol, tSun);
	if (SUN_DIR.z < MOON_SKIP_Z)
	{
		col += scatter(o, dir, len, MOON_DIR, moonCol, tMoon);
	}

	if (ground)
	{
		float3 litG;
		float3 gp = o + dir * len;
		float sunUp = saturate(dot(normalize(gp), SUN_DIR) + 0.05);
		float moonUp = saturate(dot(normalize(gp), MOON_DIR) + 0.05);
		float3 groundCol = GROUND_ALBEDO / 3.14159265 * (sunCol * sunUp * 0.05 + moonCol * moonUp * 0.05);
		col += groundCol * tSun;
	}
	else
	{
		float mu = dot(dir, SUN_DIR);
		float discK = smoothstep(SUN_DISC_COS - 0.0004, SUN_DISC_COS + 0.0002, mu);
		col += sunCol * tSun * discK * SUN_DISC;
	}

	col = 1.0 - exp(-max(col, 0.0) * EXPOSURE);

	col += (hash12(i.uv * 1024.0) - 0.5) * (1.0 / 255.0);

	return float4(max(col, 0.0) * BRIGHTNESS, 1.0);
}
