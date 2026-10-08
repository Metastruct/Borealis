const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
sampler NoiseTex : register(s0);
#define NOISE_PERIOD 64.0

#define TIME    Constants0.x
#define SCALE   Constants0.y
#define SCROLL  Constants0.zw
#define WIDTH   Constants1.x
#define MAP_SIZE Constants1.y

#define EXTENT 1.7
#define SPEED 0.06

struct PS_IN
{
	float2 vpos : VPOS;
};

static const float2x2 M2 = float2x2(0.95534, -0.29552, 0.29552, 0.95534);

float vnoise(float2 p)
{
	return tex2Dlod(NoiseTex, float4(p / NOISE_PERIOD, 0.0, 0.0)).r;
}

float4 main(PS_IN i) : COLOR
{
	float2 b = ((i.vpos + 0.5) / MAP_SIZE * 2.0 - 1.0) * EXTENT;

	float centre = sin(b.x * 1.3 + TIME * SPEED * 2.0) * 0.22 + sin(b.x * 0.45 - TIME * SPEED) * 0.30;
	float mask = 1.0 - smoothstep(WIDTH * 0.45, WIDTH, abs(b.y - centre));
	mask *= 1.0 - smoothstep(1.0, EXTENT, length(b));

	float2 p = b * SCALE;
	p.y += sin(p.x * 0.8 + TIME * SPEED * 3.0) * 0.18;
	p.x += sin(p.y * 0.6 - TIME * SPEED * 2.0) * 0.12;
	p += SCROLL;

	float2 wob = float2(cos(TIME * SPEED), sin(TIME * SPEED)) * 0.9;
	p += (float2(vnoise(p * 0.37 + wob), vnoise(p * 0.31 + 19.7 - wob)) - 0.5) * 1.6;

	float2 q = p * 0.8;
	float n = vnoise(q + wob.yx) * 0.57;
	q = mul(q, M2) * 2.13 + 5.3;
	n += vnoise(q - wob) * 0.29;
	q = mul(q, M2) * 2.07 + 9.1;
	n += vnoise(q + wob) * 0.14;

	float rays = vnoise(p * float2(7.0, 5.0) + wob * 2.0) * 0.75 + vnoise(p * 2.3 + 3.1 - wob) * 0.5;

	return float4(n, 0.35 + rays * rays, mask, 1.0);
}
