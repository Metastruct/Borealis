const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);

sampler State : register(s0);
sampler Force : register(s1);

#define WIN        Constants0.xy
#define SPEED      Constants1.x
#define DAMPING    Constants1.y
#define DEPTH      Constants1.z
#define FOAM_DECAY Constants1.w

#define TEXELS      1024.0
#define SPONGE      48.0
#define SPONGE_DAMP 0.85
#define FOAM_BIAS   0.0078125
#define FOAM_SPREAD 0.4

float4 main(float2 vpos : VPOS) : COLOR
{
	float2 px = floor(vpos);
	float2 uv = (px + 0.5) / TEXELS;
	float d = 1.0 / TEXELS;
	float2 dx = float2(d, 0.0);
	float2 dy = float2(0.0, d);

	float4 s = tex2Dlod(State, float4(uv, 0.0, 0.0));
	float4 n = tex2Dlod(State, float4(frac(uv + dx), 0.0, 0.0))
		+ tex2Dlod(State, float4(frac(uv - dx), 0.0, 0.0))
		+ tex2Dlod(State, float4(frac(uv + dy), 0.0, 0.0))
		+ tex2Dlod(State, float4(frac(uv - dy), 0.0, 0.0));
	float sum = n.r;

	float h = s.r + (s.r - s.g) * DAMPING + SPEED * (sum - 4.0 * s.r);

	float2 local = frac((px - WIN) / TEXELS) * TEXELS;
	float edge = min(min(local.x, local.y), min(TEXELS - 1.0 - local.x, TEXELS - 1.0 - local.y));
	float sponge = lerp(SPONGE_DAMP, 1.0, saturate(edge / SPONGE));
	h *= sponge;

	float2 f = tex2Dlod(Force, float4(uv, 0.0, 0.0)).rg;
	float m = (f.x * 4.0
		+ tex2Dlod(Force, float4(frac(uv + dx), 0.0, 0.0)).r
		+ tex2Dlod(Force, float4(frac(uv - dx), 0.0, 0.0)).r
		+ tex2Dlod(Force, float4(frac(uv + dy), 0.0, 0.0)).r
		+ tex2Dlod(Force, float4(frac(uv - dy), 0.0, 0.0)).r) / 8.0;
	float push = DEPTH * (m - s.b);
	float spread = lerp(s.a, n.a * 0.25, FOAM_SPREAD);
	float foam = max(max(spread - FOAM_BIAS, 0.0) * FOAM_DECAY * sponge, f.y);

	return float4(h + push, s.r * sponge + push, m, foam + FOAM_BIAS);
}
