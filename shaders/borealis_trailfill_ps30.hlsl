const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);

sampler Source : register(s0);

#define MODE Constants2.x

#define LEVEL 768.0
#define STRIDE 770.0
#define ATLAS 1540.0

float4 main(float2 vpos : VPOS) : COLOR
{
	float2 px = floor(vpos);
	[branch] if (MODE < 0.5)
	{
		return float4(tex2Dlod(Source, float4((px + 0.5) / ATLAS, 0.0, 0.0)).rgb, 1.0);
	}

	float2 q = floor(px / STRIDE);
	float k = q.x + 2.0 * q.y;
	float2 l = px - (q * STRIDE + 1.0);
	l -= floor(l / LEVEL) * LEVEL;
	float2 win = k < 0.5 ? Constants0.xy : (k < 1.5 ? Constants0.zw : (k < 2.5 ? Constants1.xy : Constants1.zw));
	float2 texel = win + frac((l - win) / LEVEL) * LEVEL;

	float parent = k + 1.0;
	float2 parentOrigin = float2(fmod(parent, 2.0), floor(parent * 0.5)) * STRIDE + 1.0;
	float2 u = (texel + 0.5) * 0.5;
	float r = tex2Dlod(Source, float4((parentOrigin + frac(u / LEVEL) * LEVEL) / ATLAS, 0.0, 0.0)).r;

	return float4(r, 0.0, 0.0, 1.0);
}
