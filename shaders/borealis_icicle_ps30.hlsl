#include "include/common.hlsl"
#include "include/skywall.hlsl"

const float4 Constants0 : register(c0);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);
const float4 Constants11 : register(c11);
const float4 Constants12 : register(c12);
const float4 Constants13 : register(c13);
const float4 Constants14 : register(c14);

sampler Probes : register(s0);
sampler SkyWall : register(s1);
sampler Flashlight : register(s2);

#define EYE         Constants0.xyz
#define SUN         Constants2.xyz
#define LIGHT_SCALE Constants2.w
#define FILL        Constants3.x
#define BRIGHTNESS  Constants3.y
#define FADE_START  Constants3.z
#define FADE_END    Constants3.w
#define FOG_COLOR   Constants11.xyz
#define FOG_START   Constants11.w
#define FOG_END     Constants12.x
#define FOG_MAX     Constants12.y
#define SKY_TINT    Constants13.xyz
#define INV_SCREEN  Constants14.xy
#define INV_FLASH   Constants14.zw

#define PROBE_SIZE float2(64.0, 128.0)
#define SNOW_ALBEDO float3(0.235, 0.24, 0.25)
#define ICE_TINT float3(0.75, 0.88, 0.95)
#define TIP_FROST 0.35
#define TIP_ALPHA 0.75
#define CLEAR_DIFFUSE 0.5
#define FILL_MIN 0.4
#define FILL_SKY 1.2
#define FORM 0.7
#define BACKFACE_EPS 0.05
#define MAX_SLOPE_GAIN 2.0
#define F0 0.04
#define REFLECT 0.3
#define SPEC_POWER 96.0
#define SPEC_GAIN 1.5
#define BACKLIGHT_POWER 6.0
#define BACKLIGHT_GAIN 0.4

struct PS_IN
{
	float2 uv    : TEXCOORD0;
	float4 color : TEXCOORD1;
	float3 wpos  : TEXCOORD2;
	float4 spos  : TEXCOORD3;
	float2 vpos  : VPOS;
};

float4 main(PS_IN i) : COLOR0
{
	float3 p = i.wpos;
	float dist = distance(p, EYE);
	float fade = smoothstep(FADE_END, FADE_START, dist);
	clip(fade - 0.001);
	ClipSkyWall(SkyWall, i.vpos, INV_SCREEN, i.spos.w);

	float slot = floor(i.uv.x + 0.5);
	float2 cell = float2(fmod(slot, PROBE_SIZE.x), floor(slot / PROBE_SIZE.x)) + 0.5;
	float4 probe = tex2Dlod(Probes, float4(cell / PROBE_SIZE, 0.0, 0.0));
	float3 baked = tex2Dlod(Probes, float4((cell + float2(0.0, PROBE_SIZE.x)) / PROBE_SIZE, 0.0, 0.0)).rgb;
	float open = probe.a;
	float3 n = normalize(i.color.rgb * 2.0 - 1.0);
	float3 v = normalize(p - EYE);
	clip(BACKFACE_EPS - dot(n, v));
	float t = i.uv.y;

	float share = length(SUN);
	float3 sunDir = SUN / max(share, 1e-4);
	float flatLight = share * saturate(sunDir.z) + (1.0 - share);
	float lambert = min((share * saturate(dot(n, sunDir)) + (1.0 - share) * (0.5 + 0.5 * n.z)) / max(flatLight, 1e-3), MAX_SLOPE_GAIN);
	float shade = lerp(1.0, lambert, FORM);
	float3 light = baked * 2.0 * LIGHT_SCALE + unpackColor(FILL) * (FILL_MIN + FILL_SKY * open) + probe.rgb * 2.0;

	float frost = lerp(1.0, TIP_FROST, t);
	float clearIce = 1.0 - frost;
	float3 albedo = SNOW_ALBEDO * lerp(ICE_TINT * CLEAR_DIFFUSE, 1.0, frost);

	float facing = saturate(-dot(n, v));
	float fresnel = (F0 + (1.0 - F0) * pow(1.0 - facing, 5.0)) * clearIce;
	float spec = pow(saturate(dot(n, normalize(sunDir - v))), SPEC_POWER) * share * SPEC_GAIN * clearIce;
	float back = pow(saturate(dot(v, sunDir)), BACKLIGHT_POWER) * share * BACKLIGHT_GAIN * clearIce;

	float3 flashlight = tex2Dlod(Flashlight, float4((i.vpos + 0.5) * INV_FLASH, 0.0, 0.0)).rgb * (albedo / SNOW_ALBEDO);
	float3 color = (albedo * shade + (spec + back) * SNOW_ALBEDO) * light * BRIGHTNESS + flashlight + SKY_TINT * fresnel * REFLECT * open;
	float alpha = saturate(lerp(1.0, TIP_ALPHA, t) + fresnel) * fade;

	float fog = saturate((i.spos.w - FOG_START) / max(FOG_END - FOG_START, 1.0)) * FOG_MAX;

	return float4(lerp(color, FOG_COLOR, fog), alpha);
}
