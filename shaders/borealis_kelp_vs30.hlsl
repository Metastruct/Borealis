const float4x4 cModelViewProj : register(c4);
const float3 cAmbientCube[6] : register(c21);

#define TIME    cAmbientCube[0].x
#define CURRENT cAmbientCube[0].yz
#define SWAY    cAmbientCube[1].x
#define FLUTTER cAmbientCube[1].y

#define SWAY_SPEED    0.55
#define SWAY_LENGTH   0.0025
#define DRIFT_SPEED   0.21
#define CROSS_SPEED   0.37
#define FLUTTER_SPEED 2.3

struct VS_INPUT
{
	float4 pos   : POSITION;
	float2 uv    : TEXCOORD0;
	float4 color : COLOR0;
};

struct VS_OUTPUT
{
	float4 projPos : POSITION;
	float3 uv      : TEXCOORD0;
	float4 color   : TEXCOORD1;
	float3 wpos    : TEXCOORD2;
};

VS_OUTPUT main(VS_INPUT i)
{
	float kind = floor(i.uv.x * 0.5);
	float u = i.uv.x - kind * 2.0;
	float h = floor(i.uv.y * 0.5);
	float v = i.uv.y - h * 2.0;
	float phase = i.color.a * 6.2832;

	float2 side = float2(-CURRENT.y, CURRENT.x);
	float heightFrac = h * 0.001;
	float bend = heightFrac * sqrt(heightFrac);
	float along = SWAY * bend * (sin(TIME * SWAY_SPEED - h * SWAY_LENGTH + phase) + 0.6 * sin(TIME * DRIFT_SPEED + phase * 1.7));
	float across = SWAY * 0.4 * bend * sin(TIME * CROSS_SPEED + phase * 2.3 - h * SWAY_LENGTH);
	float flutter = min(kind, 1.0) * v * FLUTTER * sin(TIME * FLUTTER_SPEED + phase * 5.0 + kind * 0.37 + h * 0.05);

	float3 pos = i.pos.xyz;
	pos.xy += CURRENT * along + side * (across + flutter);
	pos.z += flutter * 0.4;

	VS_OUTPUT o;
	o.projPos = mul(float4(pos, 1.0), cModelViewProj);
	o.uv = float3(u, v, kind);
	o.color = i.color;
	o.wpos = pos;

	return o;
}
