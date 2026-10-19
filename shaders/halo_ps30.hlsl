const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);

sampler Rows : register(s0);

#define TEXEL Constants0.xy
#define WIDTH Constants0.z

#define GROUP_SCALE 8.0
#define DIST_SCALE 16.0

struct PS_IN
{
	float2 uv    : TEXCOORD0;
	float4 color : TEXCOORD1;
	float2 vpos  : VPOS;
};

float2 groupParams(float id)
{
	float2 g = Constants1.xy;
	g = id > 1.5 ? Constants1.zw : g;
	g = id > 2.5 ? Constants2.xy : g;
	g = id > 3.5 ? Constants2.zw : g;
	g = id > 4.5 ? Constants3.xy : g;
	g = id > 5.5 ? Constants3.zw : g;

	return g;
}

float4 main(PS_IN i) : COLOR0
{
	float2 uv = (i.vpos + 0.5) * TEXEL;

	float best = 1e6;
	float id = 0.0;
	[loop] for (float y = -WIDTH; y <= WIDTH; y += 1.0)
	{
		float2 row = tex2Dlod(Rows, float4(uv + float2(0.0, y * TEXEL.y), 0.0, 0.0)).rg;
		float dx = floor(row.r * DIST_SCALE + 0.5);
		float d2 = dx * dx + y * y;
		if (row.r < 0.99 && d2 < best)
		{
			best = d2;
			id = floor(row.g * GROUP_SCALE + 0.5);
		}
	}
	clip(min(id, best) - 0.5);

	float2 g = groupParams(id);
	float3 color = float3(floor(g.x / 65536.0), fmod(floor(g.x / 256.0), 256.0), fmod(g.x, 256.0)) / 255.0;
	float width = fmod(g.y, 16.0);
	float additive = fmod(floor(g.y / 16.0), 2.0);
	float opacity = floor(g.y / 32.0) / 255.0;

	float a = saturate(width + 0.5 - sqrt(best)) * opacity;
	clip(a - 0.5 / 255.0);

	return float4(color * a, additive > 0.5 ? 1.0 / 255.0 : a);
}
