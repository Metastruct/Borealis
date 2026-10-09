const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);

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
};

float2 test(float4 b, float u, float v, float bend)
{
	float t = v / b.y;
	float centre = b.x + (b.z + bend) * v * v;
	float half = b.w * (1.0 - t * t * t);
	float inside = step(abs(u - centre), half) * step(t, 1.0);

	return float2(inside, inside * t);
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

	float2 windDir = float2(cos(WIND_ANGLE), sin(WIND_ANGLE));
	float along = dot(i.wpos.xy, windDir);
	float gust = sin(TIME * 1.2 - along * 0.006) * 0.55
	           + sin(TIME * 0.45 - along * 0.0015 + 1.7) * 0.35
	           + sin(TIME * 3.1 - along * 0.02 + seed1 * 0.7) * 0.15 + 0.35;
	float flutter = sin(TIME * 4.0 + seed1 * 0.41) * 0.04;
	float bend = WIND * gust * (0.6 + 0.4 * heightScale);

	float2 r = test(i.blade0, u, v, bend + flutter);
	float2 q;
	q = test(i.blade1, u, v, bend - flutter); r = max(r, q);
	q = test(i.blade2, u, v, bend + flutter * 0.5); r = max(r, q);
	q = test(i.blade3, u, v, bend - flutter * 0.5); r = max(r, q);
	q = test(i.blade4, u, v, bend); r = max(r, q);
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

	float3 light = i.color.rgb * 2.0 * LIGHT_SCALE + unpackColor(Constants1.y);
	float3 col = albedo * light * (0.45 + 0.55 * tip) + albedo * light * TRANSLUCENCY * tip * tip;

	return float4(col * BRIGHTNESS, 1.0);
#endif
}
