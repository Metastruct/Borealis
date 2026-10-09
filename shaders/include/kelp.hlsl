const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);

#define EYE          Constants0.xyz
#define FADE_START   Constants1.w
#define LIGHT_SCALE  Constants2.x
#define BRIGHTNESS   Constants2.w
#define TRANSLUCENCY Constants3.x
#define FADE_END     Constants3.w

struct PS_IN
{
	float3 uv    : TEXCOORD0;
	float4 color : TEXCOORD1;
	float3 wpos  : TEXCOORD2;
};

float3 unpackColor(float v)
{
	float r = floor(v / 65536.0);
	v -= r * 65536.0;
	float g = floor(v / 256.0);
	float b = v - g * 256.0;

	return float3(r, g, b) / 255.0;
}

float hash(float2 p)
{
	return frac(dot(p, float2(0.3183, 0.3679)) * 17.31 + p.x * p.y * 0.0117);
}

float4 main(PS_IN i) : COLOR
{
	float seed = i.color.a * 255.0;
	float dist = distance(i.wpos, EYE);
	float fade = smoothstep(FADE_END, FADE_START, dist);
	clip(fade - hash(floor(i.wpos.xy * 0.5 + i.wpos.z * 0.37) + seed));

	float u = i.uv.x;
	float v = i.uv.y;
	float variant = i.uv.z;
	float leaf = min(variant, 1.0);
	float h1 = frac(variant * 0.6180339);
	float h2 = frac(variant * 0.3819660 + 0.5);
	float h3 = frac(variant * 0.7548777 + 0.25);
	float centre = 0.5 + (h1 - 0.5) * 0.5 * v * v;
	float x = leaf > 0.5 ? abs(u - centre) * 2.0 : abs(u - 0.5) * 2.0;
	float widest = lerp(0.25, 0.55, h2);
	float body = smoothstep(0.0, widest, v) * (1.0 - pow(saturate((v - widest) / (1.0 - widest)), lerp(1.5, 3.0, h3)));
	float ruffle = sin(v * lerp(12.0, 24.0, h3) + variant * 1.3);
	float halfWidth = body * 0.7 * (0.92 + 0.08 * ruffle);
	clip(leaf > 0.5 ? halfWidth - x : 1.0);
#ifdef DEPTH_ONLY
	float d = dot(i.wpos - EYE, Constants2.xyz) / 4000.0;

	return float4(d, d, d, 1.0);
#else
	float3 baseColor = unpackColor(Constants2.y);
	float3 tipColor = unpackColor(Constants2.z);
	float3 blade = lerp(baseColor, tipColor, v * lerp(0.6, 1.0, h2)) * lerp(0.8, 1.15, h1) * (0.9 + 0.1 * ruffle) * (1.0 - 0.25 * x * x);
	float3 stipe = baseColor * 0.7 * (0.75 + 0.25 * sqrt(saturate(1.0 - x * x)));
	float3 albedo = leaf > 0.5 ? blade : stipe;
	float3 light = i.color.rgb * 2.0 * LIGHT_SCALE + unpackColor(Constants1.y);
	float3 col = albedo * light * (0.55 + TRANSLUCENCY * leaf);

	return float4(col * BRIGHTNESS, 1.0);
#endif
}
