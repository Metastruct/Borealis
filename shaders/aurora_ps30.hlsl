const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);
sampler NoiseTex : register(s0);
#define NOISE_PERIOD 64.0

#define FWD        Constants0.xyz
#define TIME       Constants0.w
#define RIGHT_S    Constants1.xyz
#define HALF_H     Constants1.w
#define INTENSITY  Constants2.x
#define SCALE      Constants2.y
#define SCROLL     float2(Constants2.z, Constants3.w)
#define HUE        Constants2.w
#define HEIGHT     Constants3.x
#define WIDTH      Constants3.y
#define SHARPNESS  Constants3.z

#define STEPS 24
#define REF_STEPS 48.0
#define SPEED 0.06

struct PS_IN
{
	float2 uv : TEXCOORD0;
};

static const float2x2 M2 = float2x2(0.95534, -0.29552, 0.29552, 0.95534);

float vnoise(float2 p)
{
	return tex2Dlod(NoiseTex, float4(p / NOISE_PERIOD, 0.0, 0.0)).r;
}

float curtains(float2 p, float ds)
{
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

	float e = max(0.045 / SHARPNESS, ds * 2.5);
	float a = e / (abs(n - 0.40) + e);
	float b = e / (abs(n - 0.61) + e);
	float v = a * a + b * b * 0.8;

	float rays = vnoise(p * float2(7.0, 5.0) + wob * 2.0) * 0.75 + vnoise(p * 2.3 + 3.1 - wob) * 0.5;
	v *= 0.35 + rays * rays;

	return min(v * 0.5, 0.75);
}

float3 aurora(float3 rd, float2 fragCoord)
{
	float4 col = 0.0;
	float4 avgCol = 0.0;

	float2 jp = fragCoord * float2(2048.0, 1152.0);
	float jitter = frac(52.9829189 * frac(dot(jp, float2(0.06711056, 0.00583715))));

	float2 ap = rd.xy / (rd.z * 2.0 + 0.4) * HEIGHT * SCALE * 0.6875 + SCROLL * 0.5;
	float2 aw = float2(cos(TIME * SPEED * 2.0), sin(TIME * SPEED * 2.0)) * 0.6;
	float activity = vnoise(ap + aw) * 0.65 + vnoise(ap * 2.3 + 11.1 - aw) * 0.35;
	activity = 0.25 + 1.35 * smoothstep(0.25, 0.8, activity);

	for (int i = 0; i < STEPS; i++)
	{
		float fi = (float)i * (50.0 / STEPS);
		float fj = fi + jitter * (50.0 / STEPS);

		float h0 = HEIGHT + pow(fj, 1.4) * 0.002;
		float h1 = HEIGHT + pow(fj + 50.0 / STEPS, 1.4) * 0.002;
		float pt = h0 / (rd.z * 2.0 + 0.4);
		float3 bpos = pt * rd;

		float centre = sin(bpos.x * 1.3 + TIME * SPEED * 2.0) * 0.22 + sin(bpos.x * 0.45 - TIME * SPEED) * 0.30;
		float mask = 1.0 - smoothstep(WIDTH * 0.45, WIDTH, abs(bpos.y - centre));
		mask *= 1.0 - smoothstep(1.0, 1.7, length(bpos.xy));

		float rzt = 0.0;
		if (mask > 0.001)
		{
			float ds = length(bpos.xy) * SCALE * (h1 - h0) / h0;
			rzt = curtains(bpos.xy * SCALE, ds) * mask * activity;
		}

		float4 col2 = float4(0.0, 0.0, 0.0, rzt);
		col2.rgb = (sin(1.0 - float3(2.15, -0.5, 1.2) + fi * 0.043 + HUE) * 0.5 + 0.5) * rzt;
		avgCol = lerp(avgCol, col2, 0.5);
		col += avgCol * exp2(-fi * 0.065 - 2.5) * smoothstep(0.0, 5.0, fi);
	}

	return col.rgb * 1.8 * (REF_STEPS / STEPS);
}

float4 main(PS_IN i) : COLOR
{
	float2 ndc = float2(i.uv.x * 2.0 - 1.0, 1.0 - i.uv.y * 2.0);
	float3 up = normalize(cross(RIGHT_S, FWD)) * HALF_H;
	float3 dir = normalize(FWD + RIGHT_S * ndc.x + up * ndc.y);

	if (dir.z < -0.05)
	{
		return float4(0.0, 0.0, 0.0, 1.0);
	}

	float3 col = aurora(dir, i.uv) * INTENSITY;

	return float4(col, 1.0);
}
