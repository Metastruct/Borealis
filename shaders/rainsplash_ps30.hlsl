const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);

#define EYE        Constants0.xyz
#define TIME       Constants0.w
#define INTENSITY  Constants1.x
#define FADE_START Constants1.y
#define FADE_END   Constants1.z
#define LIGHTDIR   Constants2.xyz

#define RIPPLES  4
#define WRAP     64.0
#define CYCLES   16.0
#define RADIUS   0.15
#define RING     0.2
#define AMP      0.011
#define TONE     3.2
#define DARK     0.12
#define EDGE     0.35
#define SPRAY    0.75
#define GLINT    190.0
#define GLINT_K  2.5
#define NSCALE   0.75
#define SLOPE_LO 0.78
#define SLOPE_HI 0.95

struct PS_IN
{
	float2 uv    : TEXCOORD0;
	float4 color : TEXCOORD1;
	float3 mpos  : TEXCOORD2;
};

float3 unpackColor(float v)
{
	float r = floor(v / 65536.0);
	v -= r * 65536.0;
	float g = floor(v / 256.0);
	float b = v - g * 256.0;

	return float3(r, g, b) / 255.0;
}

float hash1(float2 p)
{
	float3 q = frac(float3(p.x, p.y, p.x) * 0.1031);
	q += dot(q, q.yzx + 33.33);

	return frac((q.x + q.y) * q.z);
}

float2 spot(float seed, float id, float k)
{
	return 0.04 + 0.92 * float2(hash1(float2(seed, id + k * 3.1)), hash1(float2(id + k * 5.7, seed)));
}

float3 ripple(float2 uv, float seed, float k, float px)
{
	float rate = 1.0 + 0.25 * floor(hash1(float2(seed + 3.1, k)) * 3.999);
	float cyc = TIME * rate + frac(seed * 0.618 + k * 0.37);
	float id = fmod(floor(cyc), CYCLES);
	float t = frac(cyc);
	if (hash1(float2(id + 0.5, seed + k)) < 0.3)
	{
		return float3(0.0, 0.0, 0.0);
	}

	float radius = RADIUS * (0.4 + 1.1 * hash1(float2(seed + id, k)));
	float2 d = uv - spot(seed, id, k);
	float len = length(d);
	float r = len / radius;
	float w = max(RING * (0.75 + 0.5 * hash1(float2(k + 1.7, seed + id))), px / radius * 1.3);
	if (r > t + 4.0 * w)
	{
		return float3(0.0, 0.0, 0.0);
	}

	float life = (1.0 - t) * (1.0 - t) * (0.6 + 0.4 * hash1(float2(id * 7.0, seed - k)));
	float x = (r - t) / w;
	float y = (r - t * 0.55) / (w * 2.0);

	float slope = AMP * life * (-2.0 * x * exp(-x * x) + 0.9 * y * exp(-y * y)) / (w * radius);
	float pop = (1.0 - smoothstep(0.0, 0.14 + t * 0.6, r)) * (1.0 - smoothstep(0.0, 0.26, t)) * SPRAY;

	return float3(slope * d / max(len, 1e-5), pop);
}

float4 main(PS_IN i) : COLOR
{
	float seed = (i.color.r * 255.0 + i.color.g * 65280.0) * (97.0 / 65535.0);
	float px = max(length(ddx(i.uv)), length(ddy(i.uv)));
	float dist = distance(i.mpos, EYE);
	[branch] if (dist >= FADE_END)
	{
		return float4(0.0, 0.0, 0.0, 0.0);
	}

	float2 grad = float2(0.0, 0.0);
	float spray = 0.0;
	for (int k = 0; k < RIPPLES; k++)
	{
		float3 r = ripple(i.uv, seed, float(k), px);
		grad += r.xy;
		spray = max(spray, r.z);
	}

	[branch] if (spray <= 0.0 && grad.x == 0.0 && grad.y == 0.0)
	{
		return float4(0.0, 0.0, 0.0, 0.0);
	}

	float2 nxy = (i.color.ba * 2.0 - 1.0) * NSCALE;
	float3 N = float3(nxy, sqrt(max(1.0 - dot(nxy, nxy), 0.01)));
	float3 T = normalize(float3(1.0, 0.0, -N.x / N.z));
	float3 B = normalize(float3(0.0, 1.0, -N.y / N.z));
	float3 n = normalize(N - grad.x * T - grad.y * B);
	float3 v = normalize(EYE - i.mpos);

	float2 vt = float2(dot(v, T), dot(v, B));
	float vl = length(vt);
	float2 dirh = vl > 1e-4 ? vt / vl : float2(0.0, 1.0);
	float lean = -dot(grad, dirh) * saturate(vl * 1.8) * TONE;

	float edge = length(grad) * EDGE;
	float3 hv = normalize(v + LIGHTDIR);
	float glint = max(pow(saturate(dot(n, hv)), GLINT) - pow(saturate(dot(N, hv)), GLINT), 0.0) * GLINT_K;

	float3 sky = unpackColor(Constants2.w);
	float flat = smoothstep(SLOPE_LO, SLOPE_HI, N.z);
	float up = (max(lean, 0.0) + edge) * flat;
	float down = max(-lean, 0.0) * flat;
	spray *= 0.45 + 0.55 * flat;
	glint *= flat;
	float a = up + down + spray + glint;
	float3 col = (sky * up + sky * DARK * down + unpackColor(Constants1.w) * spray + unpackColor(Constants3.x) * glint) / max(a, 1e-4);

	float fade = 1.0 - smoothstep(FADE_START, FADE_END, dist);

	return float4(col, saturate(a) * INTENSITY * fade);
}
