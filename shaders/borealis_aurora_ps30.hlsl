const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);
sampler NoiseTex : register(s0);
sampler CurtainMap : register(s1);
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
#define SHARPNESS  Constants3.z

#define STEPS 24
#define REF_STEPS 48.0
#define SPEED 0.06

struct PS_IN
{
	float2 uv : TEXCOORD0;
};

float vnoise(float2 p)
{
	return tex2Dlod(NoiseTex, float4(p / NOISE_PERIOD, 0.0, 0.0)).r;
}

#define STEP (50.0 / STEPS)
#define RADIUS_END 1.7

static const float HUE_STEP = STEP * 0.043;
static const float TAIL_Q = 0.5 * exp2(-STEP * 0.065);

float3 aurora(float3 rd, float2 fragCoord)
{
	float invDen = 1.0 / (rd.z * 2.0 + 0.4);
	if (HEIGHT * invDen * length(rd.xy) >= RADIUS_END)
	{
		return 0.0;
	}

	float3 col = 0.0;
	float3 avgCol = 0.0;

	float2 jp = fragCoord * float2(2048.0, 1152.0);
	float jitter = frac(52.9829189 * frac(dot(jp, float2(0.06711056, 0.00583715))));

	float2 ap = rd.xy * invDen * HEIGHT * SCALE * 0.6875 + SCROLL * 0.5;
	float2 aw = float2(cos(TIME * SPEED * 2.0), sin(TIME * SPEED * 2.0)) * 0.6;
	float activity = vnoise(ap + aw) * 0.65 + vnoise(ap * 2.3 + 11.1 - aw) * 0.35;
	activity = 0.25 + 1.35 * smoothstep(0.25, 0.8, activity);

	float3 hueS, hueC;
	sincos(1.0 - float3(2.15, -0.5, 1.2) + HUE, hueS, hueC);
	float stepS, stepC;
	sincos(HUE_STEP, stepS, stepC);

	float edge = 0.045 / SHARPNESS;
	float h1 = HEIGHT + pow(jitter * STEP, 1.4) * 0.002;

	[loop]
	for (float i = 0.0; i < STEPS; i += 1.0)
	{
		float fi = i * STEP;
		float fj = fi + jitter * STEP;

		float h0 = h1;
		float2 bpos = h0 * invDen * rd.xy;
		float radius = length(bpos);

		if (radius >= RADIUS_END && i >= 3.0)
		{
			col += avgCol * (0.5 * exp2(-fi * 0.065 - 2.5) * (1.0 - exp2((STEPS - i) * log2(TAIL_Q))) / (1.0 - TAIL_Q));
			break;
		}

		h1 = HEIGHT + pow(fj + STEP, 1.4) * 0.002;

		float3 m = tex2Dlod(CurtainMap, float4(bpos * (0.5 / RADIUS_END) + 0.5, 0.0, 0.0)).rgb;
		float e = max(edge, radius * SCALE * (h1 - h0) / h0 * 2.5);
		float a = e / (abs(m.x - 0.40) + e);
		float b = e / (abs(m.x - 0.61) + e);
		float rzt = min((a * a + b * b * 0.8) * m.y * 0.5, 0.75) * m.z * activity;

		avgCol = lerp(avgCol, (hueS * 0.5 + 0.5) * rzt, 0.5);
		col += avgCol * exp2(-fi * 0.065 - 2.5) * smoothstep(0.0, 5.0, fi);

		float3 s = hueS * stepC + hueC * stepS;
		hueC = hueC * stepC - hueS * stepS;
		hueS = s;
	}

	return col * 1.8 * (REF_STEPS / STEPS);
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
