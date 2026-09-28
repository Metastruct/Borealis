const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);
sampler NoiseTex : register(s0);

#define FWD        Constants0.xyz
#define BRIGHTNESS Constants0.w
#define RIGHT_S    Constants1.xyz
#define HALF_H     Constants1.w
#define LIGHT_XY   Constants2.xy
#define DECK_H     Constants2.z
#define COVERAGE   Constants2.w
#define OFFSET     Constants3.xy
#define NOISE_PERIOD 64.0

#define CURVE 0.12

#define S_LO 20000.0
#define S_HI 10000.0

#define DECK_SEP 4200.0

#define FADE_H 3000.0

#define SLAB 6000.0
#define STEPS 5
#define STEP_A 0.45
#define EDGE 0.55
#define SHEAR float2(0.05, 0.02)

#define DETAIL_PAR 0.35
#define SAMPLE_FADE 1200.0
#define SHADOW 1.2

struct PS_IN
{
	float2 uv : TEXCOORD0;
};

float3 unpackColor(float v)
{
	float r = floor(v / 65536.0);
	v -= r * 65536.0;
	float g = floor(v / 256.0);
	float b = v - g * 256.0;

	return float3(r, g, b) / 255.0;
}

float vnoise(float2 p)
{
	return tex2D(NoiseTex, p / NOISE_PERIOD).r;
}

float fbm(float2 p)
{
	float v = vnoise(p) * 0.5;
	v += vnoise(p * 2.0 + 17.3) * 0.25;
	v += vnoise(p * 4.0 + 31.1) * 0.125;
	v += vnoise(p * 8.0 + 5.7) * 0.0625;

	return v / 0.9375;
}

float3 deck(float3 dir, float h, float s, float2 stretch)
{
	float dz = dir.z * sign(h);
	float2 p = dir.xy * (abs(h) / ((max(dz, 0.0) + CURVE) * s)) * stretch;
	float vis = smoothstep(0.02, 0.22, dz) * smoothstep(0.0, FADE_H, abs(h));

	return float3(p, vis);
}

float4 volumeDeck(float3 dir, float h, float s, float2 offset, float threshold, float3 light, float3 ambient)
{
	float hm = h + SLAB * 0.5;
	float2 mid = dir.xy * (abs(hm) / ((max(dir.z * sign(hm), 0.0) + CURVE) * s)) + offset + SHEAR * 0.5;
	float nLow = vnoise(mid) * 0.5 + vnoise(mid * 2.0 + 17.3) * 0.25;
	float nMid = (nLow + vnoise(mid * 4.0 + 31.1) * 0.125 + vnoise(mid * 8.0 + 5.7) * 0.0625) / 0.9375;
	float lit = saturate(0.45 + (nMid - fbm(mid + LIGHT_XY * 0.18)) * 7.0);

	float3 col = 0.0;
	float alpha = 0.0;
	float above = 0.0;

	for (int i = 0; i < STEPS; i++)
	{
		float t = 1.0 - ((float)i + 0.5) / STEPS;
		float hs = h + SLAB * t;
		float dz = dir.z * sign(hs);
		float2 p = dir.xy * (abs(hs) / ((max(dz, 0.0) + CURVE) * s)) + offset + SHEAR * t;
		float2 pd = lerp(mid, p, DETAIL_PAR);
		float n = (nLow + vnoise(pd * 4.0 + 31.1) * 0.125 + vnoise(pd * 8.0 + 5.7) * 0.0625) / 0.9375;

		float edge = 2.0 * t - 1.0;
		float dens = smoothstep(threshold, threshold + 0.28, n) * (1.0 - EDGE * edge * edge);
		float vis = smoothstep(0.02, 0.22, dz) * smoothstep(0.0, SAMPLE_FADE, abs(hs));

		float3 c = ambient * lerp(1.0, 0.55, dens) + light * lit * exp(-SHADOW * above) * 0.85;
		above += dens / STEPS;

		float a = saturate(dens * STEP_A) * vis;
		col = lerp(col, c, a);
		alpha = a + alpha * (1.0 - a);
	}

	return float4(col, alpha);
}

float4 cloudLayer(float2 p, float threshold, float softness, float3 light, float3 ambient, float lightK)
{
	float n = fbm(p);
	float dens = smoothstep(threshold, threshold + softness, n);

	float n2 = fbm(p + LIGHT_XY * lightK);
	float lit = saturate(0.45 + (n - n2) * 7.0);

	float3 col = ambient * lerp(1.0, 0.55, dens) + light * lit * 0.85;

	return float4(col, dens);
}

float4 main(PS_IN i) : COLOR
{
	float2 ndc = float2(i.uv.x * 2.0 - 1.0, 1.0 - i.uv.y * 2.0);
	float3 up = normalize(cross(RIGHT_S, FWD)) * HALF_H;
	float3 dir = normalize(FWD + RIGHT_S * ndc.x + up * ndc.y);

	float3 light = unpackColor(Constants3.z);
	float3 ambient = unpackColor(Constants3.w);

	float threshold = lerp(0.72, 0.36, COVERAGE);
	float hHi = DECK_H + DECK_SEP;

	float4 lo = volumeDeck(dir, DECK_H, S_LO, OFFSET, threshold, light, ambient);

	float3 pHi = deck(dir, hHi, S_HI, float2(1.0, 1.0 / 3.0));
	float4 hi = cloudLayer(pHi.xy + OFFSET * 2.0, threshold + 0.08, 0.2, light, ambient, 0.12);
	hi.a *= pHi.z * 0.55;

	float loNear = step(abs(DECK_H), abs(hHi));
	float4 near = lerp(hi, lo, loNear);
	float4 far = lerp(lo, hi, loNear);

	float3 col = lerp(far.rgb, near.rgb, near.a);
	float alpha = near.a + far.a * (1.0 - near.a);

	return float4(col * BRIGHTNESS, alpha);
}
