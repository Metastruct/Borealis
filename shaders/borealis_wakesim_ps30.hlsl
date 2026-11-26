const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);

sampler State : register(s0);
sampler Force : register(s1);

#define SPEED      Constants2.x
#define DAMPING    Constants2.y
#define DEPTH      Constants2.z
#define FOAM_DECAY Constants2.w

#define LEVEL       512.0
#define STRIDE      514.0
#define ATLAS       1028.0
#define SPONGE      32.0
#define SPONGE_DAMP 0.85
#define FOAM_BIAS   0.0078125
#define FOAM_SPREAD 0.4

static float2 origin;

float4 At(sampler s, float2 l) {
	return tex2Dlod(s, float4((origin + l - floor(l / LEVEL) * LEVEL + 0.5) / ATLAS, 0.0, 0.0));
}

float4 main(float2 vpos : VPOS) : COLOR
{
	float2 px = floor(vpos);
	float2 q = floor(px / STRIDE);
	float k = q.x + 2.0 * q.y;
	origin = q * STRIDE + 1.0;
	float2 l = px - origin;
	l -= floor(l / LEVEL) * LEVEL;
	float2 win = k < 0.5 ? Constants0.xy : (k < 1.5 ? Constants0.zw : (k < 2.5 ? Constants1.xy : Constants1.zw));

	float2 dx = float2(1.0, 0.0);
	float2 dy = float2(0.0, 1.0);

	float4 s = At(State, l);
	float4 n = At(State, l + dx) + At(State, l - dx) + At(State, l + dy) + At(State, l - dy);

	float h = s.r + (s.r - s.g) * DAMPING + SPEED * exp2(-2.0 * k) * (n.r - 4.0 * s.r);

	float2 local = frac((l - win) / LEVEL) * LEVEL;
	float edge = min(min(local.x, local.y), min(LEVEL - 1.0 - local.x, LEVEL - 1.0 - local.y));
	float sponge = lerp(SPONGE_DAMP, 1.0, saturate(edge / SPONGE));
	h *= sponge;

	float2 f = At(Force, l).rg;
	float m = (f.x * 4.0 + At(Force, l + dx).r + At(Force, l - dx).r + At(Force, l + dy).r + At(Force, l - dy).r) / 8.0;
	float push = DEPTH * (m - s.b);
	float spread = lerp(s.a, n.a * 0.25, FOAM_SPREAD);
	float foam = max(max(spread - FOAM_BIAS, 0.0) * FOAM_DECAY * sponge, f.y);

	return float4(h + push, s.r * sponge + push, m, foam + FOAM_BIAS);
}
