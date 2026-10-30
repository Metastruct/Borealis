#include "include/common.hlsl"

const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);

sampler CoverTex : register(s0);

#define EYE        Constants0.xyz
#define INTENSITY  Constants1.x
#define FADE_START Constants1.y
#define FADE_END   Constants1.z

#define NEAR         20.0
#define Z_FADE_START 240.0
#define Z_FADE_END   400.0
#define COLUMN       24.0
#define COLUMNS      64.0
#define Z_MIN        -16384.0
#define Z_RANGE      32768.0

struct PS_IN
{
	float2 uv     : TEXCOORD0;
	float3 centre : TEXCOORD1;
	float2 info   : TEXCOORD2;
};

float4 main(PS_IN i) : COLOR
{
	float2 col = floor(i.centre.xy / COLUMN);
	float2 cuv = frac(col / COLUMNS) + 0.5 / COLUMNS;
	float2 c = tex2D(CoverTex, cuv).rg;
	float coverZ = (c.r * 65280.0 + c.g * 255.0) / 65535.0 * Z_RANGE + Z_MIN;

	float r = length(i.uv);
	float disc = 1.0 - smoothstep(0.3, 1.0, r);

	float dist = distance(i.centre, EYE);
	float fade = (1.0 - smoothstep(FADE_START, FADE_END, dist)) * smoothstep(NEAR * 0.3, NEAR, dist);
	fade *= 1.0 - smoothstep(Z_FADE_START, Z_FADE_END, abs(i.centre.z - EYE.z));

	float a = i.centre.z >= coverZ - 1.0 ? disc * fade * i.info.x * i.info.y * INTENSITY : 0.0;

	return float4(unpackColor(Constants1.w), a);
}
