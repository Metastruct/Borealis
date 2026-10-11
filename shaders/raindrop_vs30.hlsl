const float4 cEyePosWaterZ : register(c2);
const float4x4 cViewProj : register(c8);
const float3 cAmbientCube[6] : register(c21);
const float4 cModel0[3] : register(c58);

#define EYE      cEyePosWaterZ.xyz
#define TIME     cAmbientCube[0].x
#define PAIRS    cAmbientCube[0].y
#define WEIGHT   cAmbientCube[0].z
#define SCREEN_X cAmbientCube[1]
#define SCREEN_Y cAmbientCube[2]
#define VIEW_FWD cAmbientCube[3]

#define TILE     256.0
#define WINDOW   11.0
#define HALF_H   560.0
#define HALF_W   2.6
#define SPREAD   24.0
#define WIND     cAmbientCube[4].xy
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
#define WRAP     20.0
#define FADE_END 760.0
#define Z_FADE_END 400.0
#define MARGIN   1.3
#define PI       3.14159265

struct VS_INPUT
{
	float4 pos : POSITION;
};

struct VS_OUTPUT
{
	float4 projPos : POSITION;
	float2 uv      : TEXCOORD0;
	float4 strip   : TEXCOORD1;
	float3 wpos    : TEXCOORD2;
	float4 owner   : TEXCOORD3;
};

float3 hash33(float3 p)
{
	p = frac(p * float3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);

	return frac((p.xxy + p.yxx) * p.zyx);
}

float3 hash3(float2 p)
{
	float3 q = frac(float3(p.x, p.y, p.x) * float3(0.1031, 0.1030, 0.0973));
	q += dot(q, q.yxz + 33.33);

	return frac((q.xxy + q.yzz) * q.zyx);
}

float2 footprint(float3 rv, float zv, float3 n, float3 e, float3 uAx)
{
	float rn = dot(rv, n);
	rn = (rn < 0.0 ? -1.0 : 1.0) * max(abs(rn), 0.002 * length(rv));
	float k = dot(e, n) / rn;

	return zv * abs(float2(dot(e, uAx) - dot(rv, uAx) * k, e.z - rv.z * k));
}

VS_OUTPUT main(VS_INPUT i)
{
	VS_OUTPUT o = (VS_OUTPUT)0;
	o.projPos = float4(0.0, 0.0, -1.0, 1.0);

	float p = i.pos.x;
	float code = i.pos.y;
	float corner = i.pos.z;
	float per = 3.0 * WINDOW;
	float k = floor(code / per + 0.01);
	float jr = code - k * per;
	float j = floor(jr / WINDOW + 0.01);
	float r = jr - j * WINDOW;

	if (p >= PAIRS)
	{
		return o;
	}

	float3 origin = float3(cModel0[0].w, cModel0[1].w, cModel0[2].w);
	float2 tileId = floor(origin.xy / TILE + 0.5);
	float seed = p * 8.0;
	float3 rA = hash33(float3(tileId, seed));
	float3 rB = hash33(float3(tileId, seed + 1.0));
	float3 rC = hash33(float3(tileId, seed + 2.0));
	float3 rK = hash33(float3(tileId, seed + 3.0 + k));

	float lean = 0.65 + rB.y * 0.8;
	float swing = (rB.z - 0.5) * 0.5;
	float2 w = float2(WIND.x * lean - WIND.y * swing, WIND.y * lean + WIND.x * swing) * HALF_H;
	float a = rC.x * PI + k * PI * 0.5;
	float2 base = origin.xy + rA.xy * TILE + (float2(rA.z, rB.x) - 0.5) * SPREAD * k;
	float2 dxy = float2(cos(a), sin(a)) * HALF_W;
	float fz = origin.z;

	if (length(base - EYE.xy) > FADE_END + 180.0)
	{
		return o;
	}

	float phaseB = floor(rK.x * 255.0);
	float speedS = floor(rK.y * 4.0 + 0.5);
	float brightB = floor(rK.z * 255.0);
	float phase = phaseB / 255.0;
	float bright = brightB / 255.0;
	float sp = 0.1 * speedS;
	float size = 0.75 + 0.5 * frac(phase * 13.7 + bright * 5.1);
	float salt = frac(phase * 13.1 + bright * 7.9);

	float sj = (j < 0.5 ? 0.8 : (j < 1.5 ? 0.9 : 0.7)) + sp;
	float oj = j < 0.5 ? 0.0 : (j < 1.5 ? 0.37 : 0.71);
	float lj = j < 0.5 ? 1.0 : (j < 1.5 ? 0.8 : 0.65);
	float wj = j < 0.5 ? 1.0 : (j < 1.5 ? 0.8 : 0.7);
	float saltj = salt + (j < 0.5 ? 0.0 : (j < 1.5 ? 0.41 : 0.83));

	float gw = 2.0 * PI * GUST_N / WRAP;
	float t = TIME + GUST / gw * sin(gw * TIME + (base.x + base.y * 0.7) * GUST_K);
	float C = phase * SLOTS - t * SPEED * sj + oj;

	float zTop = EYE.z + Z_FADE_END;
	float zBot = EYE.z - Z_FADE_END;
	float n = floor(C - zTop / PERIOD) + r;
	float m = frac(n / SLOTS) * SLOTS;

	float3 h = hash3(float2(m, saltj));
	if (h.x < SKIP)
	{
		return o;
	}

	float len = SEG * lj * (0.25 + 1.3 * h.y);
	float offC = frac(h.y * 11.3 + h.z * 4.7);
	float uc = 0.5 + (frac(h.x * 21.7 + h.z * 9.3) - 0.5) * JITTER;
	float wmax = WIDTH * wj * size * (0.7 + 0.6 * h.z);

	float st = PERIOD * (C - n);
	float zc = st - PERIOD * 0.5;
	float3 P = float3(base + (2.0 * uc - 1.0) * dxy + w * (zc - fz) / HALF_H, zc);
	float3 rv = P - EYE;
	if (length(rv) > FADE_END + PERIOD)
	{
		return o;
	}

	float3 uAx = float3(dxy / HALF_W, 0.0);
	float3 along = normalize(float3(w, HALF_H));
	float3 nrm = normalize(cross(uAx, along));
	float zv = max(dot(rv, VIEW_FWD), 1.0);
	float2 fx = footprint(rv, zv, nrm, SCREEN_X, uAx);
	float2 fy = footprint(rv, zv, nrm, SCREEN_Y, uAx);
	float px = (fx.x + fy.x) / (2.0 * HALF_W) * MARGIN;
	float pv = (fx.y + fy.y) / PERIOD * MARGIN;

	float W = max(wmax, px) * 1.05 + 0.002;
	float L = max(len, pv);
	float lo = offC * max(1.0 - L, 0.0) - 0.02;
	float hi = min(lo + 0.02 + L, 1.0) + 0.02;

	float z0 = max(st - PERIOD * hi, zBot);
	float z1 = min(st - PERIOD * lo, zTop);
	if (z0 >= z1)
	{
		return o;
	}

	float u0 = max(uc - W, 0.0);
	float u1 = min(uc + W, 1.0);
	float u = (corner < 0.5 || corner > 2.5) ? u0 : u1;
	float z = corner < 1.5 ? z1 : z0;
	float3 world = float3(base + (2.0 * u - 1.0) * dxy + w * (z - fz) / HALF_H, z);

	o.projPos = mul(float4(world, 1.0), cViewProj);
	o.uv = float2(u, 0.0);
	o.strip = float4(phaseB, speedS, brightB, WEIGHT);
	o.wpos = world;
	o.owner = float4(j, m, zBot, zTop);

	return o;
}
