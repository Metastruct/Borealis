const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);

sampler CoverTex : register(s0);

#define EYE        Constants0.xyz
#define TIME       Constants0.w
#define INTENSITY  Constants1.x
#define FADE_START Constants1.y
#define FADE_END   Constants1.z

#define PERIOD   80.0
#define SLOTS    16.0
#define SPEED    8.0
#define SEG      0.3
#define WIDTH    0.051
#define SKIP     0.36
#define JITTER   0.84
#define GUST     0.18
#define GUST_N   4.0
#define GUST_K   0.0011
#define NEAR     90.0
#define Z_FADE_START 240.0
#define Z_FADE_END   400.0
#define WRAP     20.0
#define COLUMN   24.0
#define COLUMNS  64.0
#define Z_MIN    -16384.0
#define Z_RANGE  32768.0
#define PI       3.14159265

struct PS_IN
{
	float2 uv    : TEXCOORD0;
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

float3 hash3(float2 p)
{
	float3 q = frac(float3(p.x, p.y, p.x) * float3(0.1031, 0.1030, 0.0973));
	q += dot(q, q.yxz + 33.33);

	return frac((q.xxy + q.yzz) * q.zyx);
}

float2 drop(float f, float u, float lane, float salt, float seg, float width, float px, float pv)
{
	float slot = floor(f);
	float3 h = hash3(float2(frac(slot / SLOTS) * SLOTS, salt));
	if (h.x < SKIP)
	{
		return float2(0.0, 0.0);
	}

	float len = seg * (0.25 + 1.3 * h.y);
	float la = max(len, pv);

	float off = frac(h.y * 11.3 + h.z * 4.7) * max(1.0 - la, 0.0);
	float q = (f - slot - off) / la;
	if (q < 0.0 || q > 1.0)
	{
		return float2(0.0, 0.0);
	}

	float along = smoothstep(0.0, 1.0, q) * (1.0 - smoothstep(0.95, 1.0, q)) * (len / la);
	along *= along;

	float w = width * (0.35 + 0.65 * q) * (0.7 + 0.6 * h.z);
	float wa = max(w, px);
	float d = abs(u - lane - (frac(h.x * 21.7 + h.z * 9.3) - 0.5) * JITTER);
	float halo = 1.0 - smoothstep(wa * 0.2, wa, d);
	float core = 1.0 - smoothstep(0.0, wa * 0.5, d);

	return float2(along * (w / wa) * (0.55 * halo + 0.45 * core), (0.25 * halo + 0.75 * core) * smoothstep(0.4, 1.0, q));
}

float4 main(PS_IN i) : COLOR
{
	float2 col = floor(i.wpos.xy / COLUMN);
	float2 cuv = frac(col / COLUMNS) + 0.5 / COLUMNS;
	float2 c = tex2D(CoverTex, cuv).rg;
	float cut = (c.r * 65280.0 + c.g * 255.0) / 65535.0 * Z_RANGE + Z_MIN;
	if (i.wpos.z < cut)
	{
		return float4(0.0, 0.0, 0.0, 0.0);
	}

	float px = fwidth(i.uv.x);
	float pv = fwidth(-i.wpos.z / PERIOD);
	float phase = i.color.r;
	float bright = i.color.b;
	float sp = 0.1 * floor(i.color.g * 4.0 + 0.5);
	float size = 0.75 + 0.5 * frac(phase * 13.7 + bright * 5.1);

	float gw = 2.0 * PI * GUST_N / WRAP;
	float t = TIME + GUST / gw * sin(gw * TIME + (i.wpos.x + i.wpos.y * 0.7) * GUST_K);
	float f = -i.wpos.z / PERIOD + phase * SLOTS;
	float salt = frac(phase * 13.1 + bright * 7.9);

	float2 a = drop(f - t * SPEED * (0.8 + sp), i.uv.x, 0.5, salt, SEG, WIDTH * size, px, pv);
	float2 b = drop(f - t * SPEED * (0.9 + sp) + 0.37, i.uv.x, 0.5, salt + 0.41, SEG * 0.8, WIDTH * 0.8 * size, px, pv);
	float2 d = drop(f - t * SPEED * (0.7 + sp) + 0.71, i.uv.x, 0.5, salt + 0.83, SEG * 0.65, WIDTH * 0.7 * size, px, pv);
	a = a.x > b.x ? a : b;
	a = a.x > d.x ? a : d;

	float dist = distance(i.wpos, EYE);
	float fade = (1.0 - smoothstep(FADE_START, FADE_END, dist)) * smoothstep(NEAR * 0.3, NEAR, dist);
	fade *= 1.0 - smoothstep(Z_FADE_START, Z_FADE_END, abs(i.wpos.z - EYE.z));

	float3 body = unpackColor(Constants1.w);
	float3 head = unpackColor(Constants2.x);

	return float4(lerp(body, head, saturate(a.y)), a.x * fade * INTENSITY * (0.45 + 0.55 * bright) / max(i.color.a, 0.02));
}
