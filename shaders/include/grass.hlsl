const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);
const float4 Constants11 : register(c11);
const float4 Constants12 : register(c12);
const float4 Constants13 : register(c13);
const float4 Constants14 : register(c14);

sampler SkyWall : register(s2);
sampler Trail : register(s3);

#define EYE        Constants0.xyz
#define TIME       Constants0.w
#define WIND_ANGLE Constants1.x
#define WIND       Constants1.z
#define FADE_START Constants1.w
#define LIGHT_SCALE Constants2.x
#define BRIGHTNESS Constants2.w
#define TRANSLUCENCY Constants3.x
#define DRYNESS    Constants3.y
#define FADE_END   Constants3.w
#define VIEW_FWD   Constants11.xyz
#define INV_SCREEN Constants12.xy
#define TRAIL_MIN  Constants13.xy
#define TRAIL_MAX  Constants13.zw
#define QUAD_UNITS Constants14.x

#define TRAIL_TEXEL 2.0
#define TRAIL_LEVEL 768.0
#define TRAIL_ATLAS 1540.0
#define TRAMPLE_H 64.0
#define TRAMPLE_LEAN 0.6

#ifndef DEPTH_ONLY
sampler DynamicLights : register(s0);
sampler ProjectedLights : register(s1);
#endif

struct PS_IN
{
	float2 uv     : TEXCOORD0;
	float4 color  : TEXCOORD1;
	float3 wpos   : TEXCOORD2;
	float4 blade0 : TEXCOORD3;
	float4 blade1 : TEXCOORD4;
	float4 blade2 : TEXCOORD5;
	float4 blade3 : TEXCOORD6;
	float4 blade4 : TEXCOORD7;
	float2 vpos   : VPOS;
};

float2 test(float4 b, float u, float v, float bend)
{
	float t = v / b.y;
	float centre = b.x + (b.z + bend) * v * v;
	float half = b.w * (1.0 - t * t * t);
	float inside = step(abs(u - centre), half) * step(t, 1.0);

	return float2(inside, inside * t);
}

float clearanceAt(float2 xy)
{
	float press = 0.0;
	[branch] if (all(xy >= TRAIL_MIN) && all(xy <= TRAIL_MAX))
	{
		float2 u = frac(float2(xy.x, -xy.y) / (TRAIL_TEXEL * TRAIL_LEVEL)) * TRAIL_LEVEL;
		press = tex2Dlod(Trail, float4((1.0 + u) / TRAIL_ATLAS, 0.0, 0.0)).g;
	}

	return (1.0 - press) * TRAMPLE_H;
}

float4 trample(float4 b, float clearance, float quadUnits)
{
	float k = saturate(clearance / max(b.y * quadUnits, 1e-3));
	b.y = max(b.y * k, 1e-3);
	b.z += (b.z >= 0.0 ? 1.0 : -1.0) * (1.0 - k) * TRAMPLE_LEAN;

	return b;
}

float4 main(PS_IN i) : COLOR
{
	float seed1 = i.color.a * 255.0;
	float heightIndex = floor(i.uv.x * 0.5 + 0.001);
	float u = i.uv.x - heightIndex * 2.0;
	float v = 1.0 - i.uv.y;
	float heightScale = 0.5 + heightIndex / 7.0 * 0.9;

	float dist = distance(i.wpos, EYE);
	float fade = smoothstep(FADE_END, FADE_START, dist);
	float dither = hash(floor(i.wpos.xy * 0.5) + seed1);
	clip(fade - dither);
	ClipSkyWall(SkyWall, i.vpos, INV_SCREEN, dot(i.wpos - EYE, VIEW_FWD));

	float2 windDir = float2(cos(WIND_ANGLE), sin(WIND_ANGLE));
	float gust = GrassGust(i.wpos.xy, windDir, TIME, seed1);
	float flutter = sin(TIME * 4.0 + seed1 * 0.41) * 0.04;
	float2 axis = ddx(i.wpos.xy) * ddx(i.uv.x) + ddy(i.wpos.xy) * ddy(i.uv.x);
	float facing = dot(axis, windDir) * rsqrt(max(dot(axis, axis), 1e-12));
	float bend = WIND * gust * facing * (0.6 + 0.4 * heightScale);

	float4 b0 = i.blade0, b1 = i.blade1, b2 = i.blade2, b3 = i.blade3, b4 = i.blade4;
	float clearance = clearanceAt(i.wpos.xy);
	float quadUnits = QUAD_UNITS * heightScale;
	[branch] if (clearance < quadUnits)
	{
		b0 = trample(b0, clearance, quadUnits);
		b1 = trample(b1, clearance, quadUnits);
		b2 = trample(b2, clearance, quadUnits);
		b3 = trample(b3, clearance, quadUnits);
		b4 = trample(b4, clearance, quadUnits);
	}

	float2 r = test(b0, u, v, bend + flutter);
	float2 q;
	q = test(b1, u, v, bend - flutter); r = max(r, q);
	q = test(b2, u, v, bend + flutter * 0.5); r = max(r, q);
	q = test(b3, u, v, bend - flutter * 0.5); r = max(r, q);
	q = test(b4, u, v, bend); r = max(r, q);
	clip(r.x - 0.5);
#ifdef DEPTH_ONLY
	float d = dot(i.wpos - EYE, Constants2.xyz) / DEPTH_SCALE;

	return float4(d, d, d, 1.0);
#else
	float tip = r.y;

	float dry = saturate(DRYNESS + (hash(float2(seed1, 9.2)) - 0.5) * 0.6);
	float3 rootGreen = unpackColor(Constants2.y);
	float3 tipGreen = unpackColor(Constants2.z);
	float3 tipDry = unpackColor(Constants3.z);
	float3 rootDry = tipDry * 0.4;
	float3 albedo = lerp(lerp(rootGreen, tipGreen, tip), lerp(rootDry, tipDry, tip), dry);

	float3 light = i.color.rgb * 2.0 * LIGHT_SCALE + unpackColor(Constants1.y) + DynamicLightAt(DynamicLights, i.wpos.xy, EYE.xy) + ProjectedLightAt(ProjectedLights, i.wpos.xy, EYE.xy);
	float3 col = albedo * light * (0.45 + 0.55 * tip) + albedo * light * TRANSLUCENCY * tip * tip;

	return float4(col * BRIGHTNESS, 1.0);
#endif
}
