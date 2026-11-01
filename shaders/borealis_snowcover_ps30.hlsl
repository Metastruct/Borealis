#include "include/common.hlsl"

const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);
const float4 Constants11 : register(c11);
const float4 Constants12 : register(c12);
const float4 Constants13 : register(c13);

sampler Trail : register(s0);
sampler3D Noise : register(s1);
sampler DynamicLights : register(s2);

#include "include/dynamic_lights.hlsl"

#define EYE         Constants0.xyz
#define TIME        Constants0.w
#define WIN_MIN     Constants1.xy
#define WIN_MAX     Constants1.zw
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

#define SNOW_DEPTH 10.0
#define TRAIL_SPAN 2048.0
#define MIN_THICK 0.12
#define WALL_NZ 0.3
#define POM_STEPS 16
#define POM_REFINE 5
#define POM_MAX_DISTANCE 48.0
#define POM_MIN_SLOPE 0.12
#define TRAIL_PEAK_MIN 0.01
#define SOFT_A float2(1.8, 0.7)
#define SOFT_B float2(-0.7, 1.8)
#define GRAD_STEP 2.0
#define SHADOW_STEPS 6
#define SHADOW_MIN_SUN 0.2
#define SHADOW_BIAS 0.3
#define SHADOW_SOFT 2.0
#define BUMP_SCALE (1.0 / 48.0)
#define BUMP_STEP 6.0
#define BUMP 0.35
#define FRESH_ALBEDO float3(0.235, 0.24, 0.25)
#define PACKED_ALBEDO float3(0.165, 0.175, 0.195)
#define PACKED_GAIN 1.5
#define CAVITY 0.35
#define SSS 0.35
#define FLAKE_SCALE (1.0 / 160.0)
#define FLAKE_VAR 0.12
#define GLINT_RANGE 700.0
#define GLINT_SCALE (1.0 / 2.5)
#define GLINT_SHIFT 0.8
#define GLINT_THRESHOLD 0.8
#define GLINT_GAIN 1.5

struct PS_IN
{
	float2 uv    : TEXCOORD0;
	float4 color : TEXCOORD1;
	float3 wpos  : TEXCOORD2;
	float4 spos  : TEXCOORD3;
	float4 row0  : TEXCOORD4;
	float4 row1  : TEXCOORD5;
	float4 row2  : TEXCOORD6;
	float4 row3  : TEXCOORD7;
};

struct PS_OUT
{
	float4 color : COLOR0;
	float depth  : DEPTH0;
};

float trailAt(float2 xy)
{
	float2 inside = step(WIN_MIN, xy) * step(xy, WIN_MAX);

	return tex2Dlod(Trail, float4(frac(float2(xy.x, -xy.y) / TRAIL_SPAN), 0.0, 0.0)).r * inside.x * inside.y;
}

float softTrail(float2 xy)
{
	return (trailAt(xy + SOFT_A) + trailAt(xy - SOFT_A) + trailAt(xy + SOFT_B) + trailAt(xy - SOFT_B)) * 0.25;
}

float noiseAt(float2 xy)
{
	return tex3Dlod(Noise, float4(xy * BUMP_SCALE, 0.6, 0.0)).r;
}

PS_OUT main(PS_IN i)
{
	float3 p = i.wpos;
	float3 n = float3(i.uv, sqrt(saturate(1.0 - dot(i.uv, i.uv))));
	float a = i.color.a;
	float dist = distance(p, EYE);
	clip(smoothstep(FADE_END, FADE_START, dist) - hash(floor(p.xy * 0.25)));

	float3 v = normalize(p - EYE);
	float3 q = p;
	float3 nrm = n;
	float carve = 0.0;
	float sunShadow = 0.0;

	float share = length(SUN);
	float3 sunDir = SUN / max(share, 1e-4);

	[branch] if (n.z < WALL_NZ)
	{
		clip(1.0 - trailAt(p.xy) - a);
	}
	else
	{
		clip(a - MIN_THICK);
		float thick = a * SNOW_DEPTH;
		float descent = -dot(v, n);
		float rayLength = min(thick / max(descent, POM_MIN_SLOPE), POM_MAX_DISTANCE);
		float3 dir = v * rayLength;
		float trailPeak = max(trailAt(p.xy), max(trailAt(p.xy + dir.xy * 0.5), trailAt(p.xy + dir.xy)));
		[branch] if (trailPeak > TRAIL_PEAK_MIN)
		{
			float rayDepth = rayLength * max(descent, 0.0);
			float s = 1.0;
			float sPrev = 0.0;
			[loop] for (int k = 0; k <= POM_STEPS; k++)
			{
				float t = (float)k / POM_STEPS;
				if (t * rayDepth >= thick * trailAt(p.xy + dir.xy * t))
				{
					s = t;
					break;
				}
				sPrev = t;
			}

			[loop] for (int r = 0; r < POM_REFINE; r++)
			{
				float m = (sPrev + s) * 0.5;
				if (m * rayDepth >= thick * trailAt(p.xy + dir.xy * m))
				{
					s = m;
				}
				else
				{
					sPrev = m;
				}
			}

			q = p + dir * s;
			carve = trailAt(q.xy);
			float2 e = float2(GRAD_STEP, 0.0);
			float2 g = float2(softTrail(q.xy + e.xy) - softTrail(q.xy - e.xy), softTrail(q.xy + e.yx) - softTrail(q.xy - e.yx));
			nrm = normalize(n + float3(g * (thick / (2.0 * GRAD_STEP)), 0.0));

			float hitDepth = s * rayDepth;
			float rise = dot(sunDir, n);
			[branch] if (hitDepth > SHADOW_BIAS && rise > 0.0)
			{
				float stride = hitDepth / max(rise, SHADOW_MIN_SUN) / SHADOW_STEPS;
				[loop] for (int k = 1; k <= SHADOW_STEPS; k++)
				{
					float3 sp = q + sunDir * (stride * k);
					float depthHere = hitDepth - rise * stride * k;
					sunShadow = max(sunShadow, saturate((depthHere - thick * trailAt(sp.xy) - SHADOW_BIAS) / SHADOW_SOFT));
				}
			}
		}

		float2 b = float2(BUMP_STEP, 0.0);
		float2 bump = float2(noiseAt(q.xy + b.xy) - noiseAt(q.xy - b.xy), noiseAt(q.xy + b.yx) - noiseAt(q.xy - b.yx));
		nrm = normalize(nrm - float3(bump * BUMP * (1.0 - carve), 0.0));
	}

	float3 albedo = lerp(FRESH_ALBEDO, PACKED_ALBEDO, saturate(carve * PACKED_GAIN));
	float flake = tex3Dlod(Noise, float4(q.xy * FLAKE_SCALE, 0.3, 0.0)).r;
	albedo *= 1.0 + (flake - 0.5) * FLAKE_VAR;

	float flatLight = share * saturate(sunDir.z) + (1.0 - share);
	float slopeLight = share * saturate(dot(nrm, sunDir)) * (1.0 - sunShadow) + (1.0 - share) * (0.5 + 0.5 * nrm.z);
	float3 light = (i.color.rgb * 2.0 * LIGHT_SCALE + unpackColor(FILL)) * (slopeLight / max(flatLight, 1e-3)) + DynamicLightAt(DynamicLights, q.xy, EYE.xy);

	float3 color = albedo * light * (1.0 - CAVITY * carve) * BRIGHTNESS;
	color += SKY_TINT * SSS * carve * saturate(1.0 - nrm.z);

	[branch] if (dist < GLINT_RANGE)
	{
		float sparkle = tex3Dlod(Noise, float4(q * GLINT_SCALE + v * GLINT_SHIFT, 0.0)).r;
		float glint = pow(saturate((sparkle - GLINT_THRESHOLD) / (1.0 - GLINT_THRESHOLD)), 4.0) * share * saturate(dot(nrm, sunDir)) * (1.0 - dist / GLINT_RANGE);
		color += light * glint * GLINT_GAIN * BRIGHTNESS;
	}

	float4 clipPos = q.x * i.row0 + q.y * i.row1 + q.z * i.row2 + i.row3;
	float fog = saturate((clipPos.w - FOG_START) / max(FOG_END - FOG_START, 1.0)) * FOG_MAX;

	PS_OUT o;
	o.color = float4(lerp(color, FOG_COLOR, fog), 1.0);
	o.depth = clipPos.z / clipPos.w;

	return o;
}
