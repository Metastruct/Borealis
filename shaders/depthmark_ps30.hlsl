const float4 Constants0 : register(c0);

sampler Codes : register(s0);
sampler Depth : register(s1);
sampler Frame : register(s2);

#define ZNEAR Constants0.x
#define ZFAR  Constants0.y
#define BIAS  Constants0.z

#define DEPTH_SCALE 4000.0
#define SKY_EPS 0.0005
#define SLICES 32.0
#define SLICE_NEAR 16.0
#define SLICE_RATIO 1.2219785
#define SLICE_SLACK 1.02
#define SLICE_EXACT 64.0
#define CHANGE_EPS (0.5 / 255.0)
#define SLOPE_K 1.0
#define EDGE_SLOPE 0.08

struct PS_IN
{
	float4 color : TEXCOORD0;
	float3 wpos  : TEXCOORD1;
	float4 spos  : TEXCOORD2;
};

struct PS_OUT
{
	float4 color : COLOR0;
	float depth  : DEPTH0;
};

float surfaceDepth(float raw, float2 uv)
{
	float d = (raw <= 0.0 || abs(raw - 1.0) < SKY_EPS) ? ZFAR : raw * DEPTH_SCALE;

	float code = tex2D(Codes, uv).a * 255.0;
	if (code > SLICE_EXACT - 0.5)
	{
		return min(d, SLICE_NEAR * pow(SLICE_RATIO, code - SLICE_EXACT - 0.5));
	}

	float ks = floor(code + 0.5) - 1.0;
	if (ks < 0.0)
	{
		return d > SLICE_NEAR ? ZNEAR : d;
	}
	float sliceFar = SLICE_NEAR * pow(SLICE_RATIO, ks + 1.0);
	if (ks < SLICES - 1.0 && d > sliceFar * SLICE_SLACK)
	{
		return sliceFar;
	}

	return d;
}

PS_OUT main(PS_IN i)
{
	float2 uv = i.spos.xy / i.spos.w * float2(0.5, -0.5) + 0.5;
	uv += float2(abs(ddx(uv).x), abs(ddy(uv).y)) * 0.5;

	float raw = tex2D(Depth, uv).r;
	float slope = (abs(ddx(raw)) + abs(ddy(raw))) / max(raw, 1e-4);
	float bias = BIAS + (slope < EDGE_SLOPE ? SLOPE_K * slope : 0.0);
	float d = surfaceDepth(raw, uv);

	float3 change = abs(tex2D(Frame, uv).rgb - tex2D(Codes, uv).rgb);
	clip(max(change.r, max(change.g, change.b)) - CHANGE_EPS);

	PS_OUT o;
	o.color = float4(0.0, 0.0, 0.0, 1.0);
	o.depth = d >= ZFAR ? 1.0 : saturate(ZFAR / (ZFAR - ZNEAR) * (1.0 - ZNEAR / (d * (1.0 - bias))));

	return o;
}
