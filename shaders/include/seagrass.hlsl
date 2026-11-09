const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);
const float4 Constants11 : register(c11);
const float4 Constants12 : register(c12);

sampler NormalMap : register(s0);
sampler SkyWall : register(s2);

#define EYE         Constants0.xyz
#define TIME        Constants0.w
#define SURFACE_Z   Constants1.x
#define SWAY        Constants1.z
#define FADE_START  Constants1.w
#define LIGHT_SCALE Constants2.x
#define BRIGHTNESS  Constants2.w
#define SUN         Constants3.xyz
#define FADE_END    Constants3.w
#define VIEW_FWD    Constants11.xyz
#define INV_SCREEN  Constants12.xy

#define SURGE_PERIOD   7.0
#define SURGE_LENGTH   0.004
#define LEAN           0.4
#define WAVE_AMPLITUDE 0.12
#define WAVE_CYCLES    1.3
#define WAVE_SPEED     1.7
#define TRANSLUCENCY   0.5
#define BLADE_CAUSTICS 0.8

struct PS_IN
{
	float2 uv     : TEXCOORD0;
	float4 color  : TEXCOORD1;
	float3 wpos   : TEXCOORD2;
	float4 blade0 : TEXCOORD3;
	float4 blade1 : TEXCOORD4;
	float4 blade2 : TEXCOORD5;
	float4 blade3 : TEXCOORD6;
	float4 blade4 : TEXCOORD7;
	float2 vpos   : VPOS;
};

float2 ribbon(float4 b, float u, float v, float sway, float phase)
{
	float h1 = frac(b.x * 91.7 + b.w * 313.1);
	float h2 = frac(b.y * 57.3 + b.x * 17.9);
	float h3 = frac(b.z * 43.1 + b.w * 271.3);
	float t = v / b.y;
	float t2 = t * t;
	float cycles = WAVE_CYCLES * (0.6 + 0.9 * h1);
	float speed = WAVE_SPEED * (0.6 + 0.8 * h2);
	float amplitude = WAVE_AMPLITUDE * (0.4 + 1.2 * h3);
	float wave = amplitude * t * (sin(t * cycles * 6.2832 - TIME * speed + phase + h1 * 6.2832)
		+ 0.4 * sin(t * cycles * 14.45 - TIME * speed * 0.6 + h3 * 6.2832));
	float centre = b.x + (b.z * LEAN + sway * (0.6 + 0.8 * h2)) * v * v + wave;
	float halfWidth = b.w * (1.0 - t2 * t2 * t2);
	float inside = step(abs(u - centre), halfWidth) * step(t, 1.0);

	return float2(inside, inside * t);
}

float4 main(PS_IN i) : COLOR
{
	float seed1 = i.color.a * 255.0;
	float heightIndex = floor(i.uv.x * 0.5 + 0.001);
	float u = i.uv.x - heightIndex * 2.0;
	float v = 1.0 - i.uv.y;

	float dist = distance(i.wpos, EYE);
	float fade = smoothstep(FADE_END, FADE_START, dist);
	float dither = hash(floor(i.wpos.xy * 0.5) + seed1);
	clip(fade - dither);
	ClipSkyWall(SkyWall, i.vpos, INV_SCREEN, dot(i.wpos - EYE, VIEW_FWD));

	float sway = SWAY * sin(TIME * (6.2832 / SURGE_PERIOD) - dot(i.wpos.xy, float2(0.8, 0.6)) * SURGE_LENGTH + seed1 * 0.005);
	float phase = seed1 * 0.37;
	float2 r = ribbon(i.blade0, u, v, sway, phase);
	r = max(r, ribbon(i.blade1, u, v, sway, phase + 1.7));
	r = max(r, ribbon(i.blade2, u, v, sway, phase + 3.1));
	r = max(r, ribbon(i.blade3, u, v, sway, phase + 4.6));
	r = max(r, ribbon(i.blade4, u, v, sway, phase + 5.9));
	clip(r.x - 0.5);
#ifdef DEPTH_ONLY
	float d = dot(i.wpos - EYE, Constants2.xyz) / DEPTH_SCALE;

	return float4(d, d, d, 1.0);
#else
	float tip = r.y;
	float3 albedo = lerp(unpackColor(Constants2.y), unpackColor(Constants2.z), tip);
	float3 light = i.color.rgb * 2.0 * LIGHT_SCALE + unpackColor(Constants1.y);
	float3 col = albedo * light * (0.45 + 0.55 * tip) + albedo * light * TRANSLUCENCY * tip * tip;

	float sunUp = length(SUN);
	float3 sunDir = SUN / max(sunUp, 0.0001);
	float depthBelow = max(SURFACE_Z - i.wpos.z, 0.0);
	float3 facing = normalize(cross(ddx(i.wpos), ddy(i.wpos)));
	facing *= sign(dot(facing, EYE - i.wpos));
	float causticFade = sunUp * saturate(sunDir.z * 10.0) * (1.0 - saturate(dot(facing, sunDir)))
		* saturate(1.0 - depthBelow / CAUSTIC_MAX_DEPTH)
		* saturate(1.0 - length(fwidth(i.wpos.xy)) / CAUSTIC_PIXEL_FADE)
		* step(i.wpos.z, SURFACE_Z);
	float2 entry = SunEntryPoint(float3(i.wpos.xy, min(i.wpos.z, SURFACE_Z)), SURFACE_Z, -sunDir);
	float caustic = WaveCaustic(NormalMap, entry, TIME, depthBelow);
	col *= 1.0 + CAUSTIC_STRENGTH * BLADE_CAUSTICS * (caustic - 1.0) * causticFade;

	return float4(col * BRIGHTNESS, 1.0);
#endif
}
