const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);

sampler3D Noise : register(s1);

#define CENTER    Constants0.xyz
#define AGE       Constants0.w
#define RADIUS    Constants1.x
#define INTENSITY Constants1.y
#define SEED      Constants1.z
#define RATE      Constants1.w

#define NOISE_SCALE (1.0 / 160.0)
#define BREAKUP 0.45
#define CORE_SIZE 0.03
#define CORE_COOL 0.7
#define CORE_FADE 1.6
#define RING_START 0.12
#define RING_SPEED 2.2
#define RING_WIDTH 0.06
#define RING_FADE 0.8
#define ECHO_DELAY 0.25
#define ECHO_REACH 0.6
#define ECHO_WIDTH 0.05
#define ECHO_FADE 0.7
#define ECHO_GAIN 0.6
#define EDGE 0.15
#define CORE_GAIN 2.0
#define COOL_COLOR float3(1.0, 0.35, 0.05)
#define HOT_COLOR float3(1.0, 0.85, 0.5)
#define RING_COLOR float3(1.0, 0.5, 0.1)

struct PS_IN
{
	float4 color : TEXCOORD0;
	float3 wpos  : TEXCOORD1;
	float4 spos  : TEXCOORD2;
};

float band(float r, float at, float width)
{
	float x = (r - at) / width;

	return exp(-x * x);
}

float4 main(PS_IN i) : COLOR0
{
	float r = length(i.wpos.xy - CENTER.xy) / RADIUS;
	float n = tex3D(Noise, float3(i.wpos.xy * NOISE_SCALE, SEED)).r;
	float rn = r * (1.0 - BREAKUP * 0.5 + BREAKUP * n);

	float heat = exp(-AGE / CORE_COOL);
	float core = exp(-rn * rn / CORE_SIZE) * (0.4 + 0.6 * heat) * exp(-AGE / CORE_FADE);
	float front = RING_START + (1.0 - RING_START) * (1.0 - exp(-AGE * RING_SPEED * RATE));
	float ring = band(rn, front, RING_WIDTH) * exp(-AGE / RING_FADE);
	float echoAge = max(AGE - ECHO_DELAY, 0.0);
	float echoFront = RING_START + ECHO_REACH * (1.0 - exp(-echoAge * RING_SPEED * RATE));
	float echo = step(ECHO_DELAY, AGE) * band(rn, echoFront, ECHO_WIDTH) * exp(-echoAge / ECHO_FADE) * ECHO_GAIN;
	float edge = saturate((1.0 - r) / EDGE);

	float3 color = (core * lerp(COOL_COLOR, HOT_COLOR, heat) * CORE_GAIN + (ring + echo) * RING_COLOR) * INTENSITY * edge;

	return float4(color, 1.0);
}
