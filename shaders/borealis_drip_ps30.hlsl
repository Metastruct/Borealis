#include "include/common.hlsl"
#include "include/dynamic_lights.hlsl"

const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);

sampler DynamicTex   : register(s0);
sampler ProjectedTex : register(s1);

#define EYE        Constants0.xyz
#define TIME       Constants0.w
#define ALPHA      Constants1.x
#define DRAIN      Constants1.y
#define WORLD_K    Constants1.z
#define DYN_K      Constants1.w

#define GRAVITY        600.0
#define PERIOD_MIN     0.015
#define PERIOD_LOG     5.7038
#define RELEASE_JITTER 0.7
#define DROP_W         0.3
#define STREAK_MIN     0.6
#define SHUTTER        0.02
#define SPLASH_LIFE    0.22
#define SPLASH_SPEED   35.0
#define SPLASH_UP      60.0
#define SPLASH_R       0.25
#define LIGHT_MAX      4.0
#define LIGHT_GROUND   128.0
#define FADE_START     560.0
#define FADE_END       760.0
#define NEAR           24.0

struct PS_IN
{
	float4 wpos  : TEXCOORD0;
	float4 drip  : TEXCOORD1;
	float3 light : TEXCOORD2;
};

float3 hash3(float2 p)
{
	float3 q = frac(float3(p.x, p.y, p.x) * float3(0.1031, 0.1030, 0.0973));
	q += dot(q, q.yxz + 33.33);

	return frac((q.xxy + q.yzz) * q.zyx);
}

float2 streak(float d, float lat, float px, float pv, float drop, float seed, float period, float fall)
{
	float3 h = hash3(float2(drop, seed));
	float age = TIME - (drop + RELEASE_JITTER * h.y) * period;
	float head = 0.5 * GRAVITY * age * age;
	float2 r = float2(0.0, 0.0);

	[branch] if (h.x < DRAIN && age > 0.0 && head < fall)
	{
		float size = 0.7 + 0.6 * h.z;
		float len = (STREAK_MIN + GRAVITY * age * SHUTTER) * size;
		float w = DROP_W * size;
		float wa = max(w, px);
		float la = max(len, pv);
		float q = (head - d) / la;
		float along = smoothstep(-wa / la, 0.0, q) * (1.0 - smoothstep(0.5, 1.0, q));
		float wq = wa * (1.0 - 0.5 * saturate(q));
		float x = abs(lat);
		float halo = 1.0 - smoothstep(wq * 0.3, wq, x);
		float core = 1.0 - smoothstep(0.0, wq * 0.5, x);

		r = float2(along * (w / wa) * (len / la) * (0.55 * halo + 0.45 * core), core * (1.0 - saturate(q * 3.0)));
	}

	return r;
}

float splashBits(float h, float lat, float px, float drop, float seed, float period, float landed)
{
	float3 hs = hash3(float2(drop, seed));
	float age = landed - (drop + RELEASE_JITTER * hs.y) * period;
	float c = 0.0;

	[branch] if (hs.x < DRAIN && age >= 0.0 && age < SPLASH_LIFE)
	{
		[unroll] for (int m = 0; m < 4; m++)
		{
			float3 hm = hash3(float2(drop * 4.0 + m, seed + 0.5));
			float x = (hm.x * 2.0 - 1.0) * SPLASH_SPEED * age;
			float y = (0.35 + 0.65 * hm.y) * SPLASH_UP * age - 0.5 * GRAVITY * age * age;
			float rad = SPLASH_R * (0.6 + 0.8 * hm.z);
			float ra = max(rad, px);
			float dd = length(float2(lat - x, h - y));
			c = max(c, (1.0 - smoothstep(ra * 0.4, ra, dd)) * (rad / ra) * (rad / ra) * step(0.0, y));
		}

		c *= 1.0 - age / SPLASH_LIFE;
	}

	return c;
}

float4 main(PS_IN i) : COLOR
{
	float3 p = i.wpos.xyz;
	float lat = i.wpos.w;
	float top = i.drip.x;
	float bottom = i.drip.y;
	float packed = i.drip.z;
	float fall = top - bottom;

	float seedRate = floor(packed / 8.0);
	float rateByte = floor(seedRate / 4096.0);
	float seed = seedRate - rateByte * 4096.0;
	float period = PERIOD_MIN * exp(rateByte / 255.0 * PERIOD_LOG);

	float d = max(top - p.z, 0.0);
	float px = fwidth(lat);
	float pv = fwidth(d);
	float2 a = float2(0.0, 0.0);

	[branch] if (i.drip.w > 0.5)
	{
		float landed = TIME - sqrt(2.0 * fall / GRAVITY);
		float n = floor(landed / period);
		float h = p.z - bottom;
		a.x = max(splashBits(h, lat, px, n, seed, period, landed), splashBits(h, lat, px, n - 1.0, seed, period, landed));
		a.y = 1.0;
	}
	else
	{
		float n = floor((TIME - sqrt(2.0 * d / GRAVITY)) / period);
		[unroll] for (int k = 0; k < 4; k++)
		{
			float2 s = streak(d, lat, px, pv, n - k, seed, period, fall);
			a = s.x > a.x ? s : a;
		}
	}

	if (a.x <= 0.0)
	{
		return float4(0.0, 0.0, 0.0, 0.0);
	}

	float dist = distance(p, EYE);
	float fade = (1.0 - smoothstep(FADE_START, FADE_END, dist)) * smoothstep(NEAR * 0.3, NEAR, dist);

	float hz = (p.z - bottom) / LIGHT_GROUND;
	float3 dyn = DynamicLightAt(DynamicTex, p.xy, EYE.xy) + ProjectedLightAt(ProjectedTex, p.xy, EYE.xy);
	float3 light = i.light * i.light * (LIGHT_MAX * WORLD_K) + dyn * (DYN_K / (1.0 + hz * hz));
	float3 base = lerp(unpackColor(Constants2.x), unpackColor(Constants2.y), saturate(a.y));

	return float4(sqrt(saturate(base * base + light)), a.x * fade * ALPHA);
}
