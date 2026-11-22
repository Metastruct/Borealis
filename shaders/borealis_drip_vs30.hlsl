const float4 cEyePosWaterZ : register(c2);
const float4x4 cViewProj : register(c8);
const float3 cAmbientCube[6] : register(c21);

#define EYE        cEyePosWaterZ.xyz
#define PIXEL      cAmbientCube[0].x
#define SLANT      cAmbientCube[0].yz

#define GRAVITY    600.0
#define LAUNCH     30.0
#define STREAM_BYTE 64.0
#define PI         3.14159265
#define ROWS       8.0
#define HALF_W     0.5
#define MIN_PIXELS 1.5
#define SPLASH_W   7.0
#define SPLASH_H   5.0
#define SPLASH_RANGE 450.0
#define SPLASH_SINK 0.5
#define FADE_END   760.0

struct VS_INPUT
{
	float4 pos   : POSITION;
	float2 uv    : TEXCOORD0;
	float4 color : COLOR0;
};

struct VS_OUTPUT
{
	float4 projPos : POSITION;
	float4 wpos    : TEXCOORD0;
	float4 lane    : TEXCOORD1;
	float3 light   : TEXCOORD2;
};

VS_OUTPUT main(VS_INPUT i)
{
	VS_OUTPUT o = (VS_OUTPUT)0;
	o.projPos = float4(0.0, 0.0, -1.0, 1.0);

	float v = floor(i.color.a * 255.0 + 0.5);
	float top = i.pos.z;
	float bottom = i.uv.x;
	float code = i.uv.y;
	float dir = code - floor(code / 8.0) * 8.0;
	float rateByte = floor(code / 32768.0);
	float fall = top - bottom;

	float a = dir * PI * 0.25;
	float2 out2 = float2(cos(a), sin(a));
	float2 slant = SLANT;
	slant -= min(dot(slant, out2), 0.0) * out2;
	float launch = rateByte < STREAM_BYTE ? LAUNCH : 0.0;

	bool splash = v > 31.5;
	float corner = v - 32.0;
	float row = floor(v / 2.0);
	float side = splash ? (corner > 0.5 && corner < 2.5 ? 1.0 : -1.0) : (v - row * 2.0) * 2.0 - 1.0;
	float r = row / ROWS;
	float d = splash ? fall : fall * r * r;

	float2 xy = i.pos.xy + out2 * (launch * sqrt(2.0 * d / GRAVITY)) + slant * d;
	float3 rv = float3(xy, top - d) - EYE;
	if (length(rv.xy) > (splash ? SPLASH_RANGE : FADE_END + SPLASH_W))
	{
		return o;
	}

	float2 right = normalize(float2(-rv.y, rv.x) + float2(1e-4, 0.0));
	float halfW = max(splash ? SPLASH_W : HALF_W, PIXEL * length(rv) * MIN_PIXELS);
	float lat = side * halfW;
	float z = splash ? (corner > 1.5 ? bottom + SPLASH_H : bottom - SPLASH_SINK) : top - d;
	float3 world = float3(xy + right * lat, z);

	o.projPos = mul(float4(world, 1.0), cViewProj);
	o.wpos = float4(world, lat);
	o.lane = float4(top, bottom, code, splash ? 1.0 : 0.0);
	o.light = i.color.rgb;

	return o;
}
