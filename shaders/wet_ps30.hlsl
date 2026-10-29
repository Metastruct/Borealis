#include "include/common.hlsl"
#include "include/slices.hlsl"

const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);
const float4 Constants11 : register(c11);
const float4 Constants12 : register(c12);
const float4 Constants13 : register(c13);
const float4 Constants14 : register(c14);

sampler Frame : register(s0);
sampler Depth : register(s1);
sampler CoverTex : register(s2);
sampler3D Noise : register(s3);
sampler SkyLut : register(s4);
sampler FarGloss : register(s5);
sampler CoverSpans : register(s6);

#define EYE     Constants0.xyz
#define WET     Constants0.w
#define FWD     Constants1.xyz
#define TAN_H   Constants1.w
#define HORIZON Constants2.xyz
#define TAN_V   Constants2.w
#define ZENITH  Constants3.xyz
#define ZNEAR   Constants3.w
#define TIME       Constants11.x
#define RAIN       Constants11.y
#define LUT_WEIGHT Constants11.z
#define LUT_SCALE  Constants11.w
#define RIGHT   Constants12.xyz
#define PUDDLE_LEVEL Constants12.w
#define UP      cross(RIGHT, FWD)
#define SUN     Constants13.xyz
#define POOL    Constants13.w
#define FAR_CENTER Constants14.xy
#define FOG_BASE   Constants14.z
#define SPANS_ON   (Constants14.w > 0.0 ? 1.0 : 0.0)
#define ZFAR       abs(Constants14.w)

#define R_EARTH 6371.0
#define EYE_H 0.2
#define SKY_EXPOSURE 1.2

#include "include/sky_lut.hlsl"
#include "include/cover_spans.hlsl"
#include "include/fog_layer.hlsl"

#define COLUMN 24.0
#define COLUMNS 64.0
#define COVER_REACH 30.0
#define Z_MIN -16384.0
#define Z_RANGE 32768.0
#define COVER_SLACK 12.0
#define WATERLINE 2.0
#define SHALLOW 128.0
#define SOAK_DEPTH 48.0
#define SHORE_FADE 16.0
#define SHORE_PROBE 8.0
#define SWASH 4.0
#define SLOPE_SLACK 34.0
#define SLOPE_SLACK_MAX 64.0
#define UNTRACED_MIN 3.0
#define UNTRACED_MAX 8.0
#define GLOSS_FAR 0.7
#define FAR_COLUMN 128.0
#define FAR_COLUMNS 64.0
#define GLOSS_FADE 4.0
#define ABSORB_LEVEL 0.3
#define ABSORB_REFLECT 0.15
#define SPIKE_MIN 4.0
#define SPIKE_RATIO 0.01

#define DARKEN 0.35
#define SHEEN 0.3
#define F0 0.04
#define UP_MIN 0.2
#define UP_FULL 0.6
#define PATCH_SCALE (1.0 / 900.0)
#define PATCH_DRY 0.35
#define FADE_START 3500.0
#define FADE_END 6000.0

#define PUDDLE_FLAT 0.97
#define PUDDLE_EDGE 0.03
#define PUDDLE_DARK 0.4
#define PUDDLE_F0 0.15
#define PUDDLE_DETAIL 0.08
#define PUDDLE_DETAIL_SCALE (1.0 / 140.0)
#define PUDDLE_FADE_START 2000.0
#define PUDDLE_FADE_END 2500.0


#define FILM_START 0.3
#define FILM_FULL 0.8
#define FILM_F0 0.12
#define FILM_STREAK_MIN 0.4
#define FLOW_ACROSS_SCALE (1.0 / 300.0)
#define FLOW_ALONG_SCALE (1.0 / 3000.0)
#define FLOW_SPEED 60.0
#define FLOW_TILT 0.15

#include "include/rain_ripples.hlsl"
#include "include/ice.hlsl"

#define FROZEN (RAIN < 0.0)
#define FROST_GLOSS_MIN 0.4
#define FROST_GLOSS_FULL 0.6
#define FROST_PATCH_TILE 500.0
#define FROST_PATCH_MIN 0.35
#define FROST_GRAIN_TILE 60.0
#define FROST_WARP_TILE 120.0
#define FROST_WARP 6.0
#define FROST_CRYSTAL_SIZE 10.0
#define FROST_CRYSTAL_SMALL 4.0
#define FROST_FEATHER float2(7.0, 0.7)
#define FROST_REACH 0.85
#define FROST_DETAIL_START 250.0
#define FROST_DETAIL_END 900.0
#define FROST_BASE 0.45
#define FROST_CRYSTAL 0.95
#define FROST_LUMA float3(0.2126, 0.7152, 0.0722)
#define FROST_WHITE float3(0.95, 0.98, 1.04)
#define FROST_GAIN 2.2
#define FROST_LIFT 0.04
#define FROST_SPARKLE_CELL 1.0
#define FROST_SPARKLE_SIZE 0.14
#define FROST_SPARKLE_RATE 0.9
#define FROST_SPARKLE_RANGE 300.0
#define FROST_SPARKLE_TILT 0.9
#define FROST_SPARKLE_POWER 48.0
#define FROST_SPARKLE_GAIN 4.0

float FrostFeathers(sampler3D noise, float2 p, float size)
{
	float4 c = IceCell(p, size);
	float2 h = IceHash2(c.zw + 0.5);
	float angle = h.x * 6.2831853;
	float2 axis = float2(cos(angle), sin(angle));
	float2 local = float2(dot(p, axis), dot(p, float2(-axis.y, axis.x)));
	float feather = tex3Dlod(noise, float4(local / (FROST_FEATHER * size / FROST_CRYSTAL_SIZE), h.y, 0.0)).r;
	float reach = 1.0 - saturate(length(c.xy) / (size * FROST_REACH));

	return smoothstep(0.45, 0.75, feather) * reach;
}

#define SSR_STEPS 32
#define SSR_REFINE 5
#define SSR_START 8.0
#define SSR_MAX 6000.0
#define SSR_MIN_THICKNESS 40.0
#define SSR_THICKNESS_RATIO 0.03
#define SSR_HIT_SLACK 8.0
#define SSR_HIT_RATIO 0.005
#define FOG_DENSITY_MAX 0.001
#define FOG_FALLOFF_MAX 1000.0
#define FOG_RANGE 5000.0
#define FOG_AMBIENT 0.6

#define DEPTH_BIAS 0.002
#define EDGE_SLOPE 0.08

struct PS_IN
{
	float4 color : TEXCOORD0;
	float3 wpos  : TEXCOORD1;
	float4 spos  : TEXCOORD2;
};

struct PS_OUT
{
	float4 color : COLOR0;
	float depth  : DEPTH0;
};

PS_OUT output(float3 color, float depth)
{
	PS_OUT o;
	o.color = float4(color, 1.0);
	o.depth = depth;

	return o;
}

float3 decodeColumn(float4 c)
{
	float cut = (c.r * 65280.0 + c.g * 255.0) / 65535.0 * Z_RANGE + Z_MIN;
	float offset = c.a * 255.0;

	return float3(cut, c.b, offset < 254.5 ? cut - offset / 254.0 * SHORE_PROBE : Z_MIN);
}

float3 coverAt(float2 col)
{
	return decodeColumn(tex2Dlod(CoverTex, float4(frac(col / COLUMNS) + 0.5 / COLUMNS, 0.0, 0.0)));
}

float3 farAt(float2 col)
{
	return decodeColumn(tex2Dlod(FarGloss, float4((col + 0.5) / FAR_COLUMNS, 0.0, 0.0)));
}

float4 exposure(float3 p, float3 n, float2 eyeCol)
{
	float2 g = p.xy / COLUMN - 0.5;
	float2 col = floor(g);
	float2 f = g - col;
	float open = 1.0;
	float reach = COVER_REACH - 1.0 - max(abs(col.x - eyeCol.x), abs(col.y - eyeCol.y));
	float far = 0.0;
	float level = Z_MIN;
	[branch] if (reach < GLOSS_FADE)
	{
		float2 off = abs(p.xy - FAR_CENTER) / FAR_COLUMN;
		float window = saturate(FAR_COLUMNS * 0.5 - 1.0 - max(off.x, off.y));
		float2 fg = p.xy / FAR_COLUMN - 0.5;
		float2 fcol = floor(fg);
		float2 ff = fg - fcol;
		float3 f00 = farAt(fcol);
		float3 f10 = farAt(fcol + float2(1.0, 0.0));
		float3 f01 = farAt(fcol + float2(0.0, 1.0));
		float3 f11 = farAt(fcol + float2(1.0, 1.0));
		far = lerp(GLOSS_FAR, lerp(lerp(f00.y, f10.y, ff.x), lerp(f01.y, f11.y, ff.x), ff.y), window);
		level = window > 0.0 ? max(max(f00.z, f10.z), max(f01.z, f11.z)) : Z_MIN;
	}

	float gloss = far;
	[branch] if (reach > 0.0)
	{
		float z = p.z + COVER_SLACK + min(SLOPE_SLACK * length(n.xy) / max(n.z, 0.01), SLOPE_SLACK_MAX);
		float3 c00 = coverAt(col);
		float3 c10 = coverAt(col + float2(1.0, 0.0));
		float3 c01 = coverAt(col + float2(0.0, 1.0));
		float3 c11 = coverAt(col + float2(1.0, 1.0));
		open = lerp(lerp(step(c00.x, z), step(c10.x, z), f.x), lerp(step(c01.x, z), step(c11.x, z), f.x), f.y);
		open *= 1.0 - smoothstep(UNTRACED_MIN, UNTRACED_MAX, p.z - max(max(c00.x, c10.x), max(c01.x, c11.x)));
		level = max(level, max(max(c00.z, c10.z), max(c01.z, c11.z)));
		gloss = lerp(far, lerp(lerp(c00.y, c10.y, f.x), lerp(c01.y, c11.y, f.x), f.y), saturate(reach / GLOSS_FADE));
	}
	else if (SPANS_ON > 0.5)
	{
		open = CoverSpansOpen(CoverSpans, p, COVER_SLACK + min(SLOPE_SLACK * length(n.xy) / max(n.z, 0.01), SLOPE_SLACK_MAX));
	}

	float below = level - p.z;
	float under = step(-WATERLINE, below) * step(below, SHALLOW);
	gloss = lerp(gloss, 1.0, step(below, SHALLOW) * smoothstep(-SWASH, 0.0, below));

	return float4(open * (1.0 - under), gloss, under * (1.0 - smoothstep(0.0, SOAK_DEPTH, below)), under * (1.0 - smoothstep(0.0, SHORE_FADE, below)));
}

float3 viewRay(float2 uv)
{
	float2 ndc = (uv - 0.5) * float2(2.0, -2.0);

	return FWD + RIGHT * (ndc.x * TAN_H) + UP * (ndc.y * TAN_V);
}

float3 neighbour(float2 uv)
{
	float raw = tex2Dlod(Depth, float4(uv, 0.0, 0.0)).r;
	float d = IsSkyDepth(raw) ? FADE_END * 4.0 : raw * DEPTH_SCALE;

	return viewRay(uv) * d;
}

float3 nearer(float3 p, float3 a, float3 b)
{
	return abs(dot(a - p, FWD)) < abs(dot(p - b, FWD)) ? a - p : p - b;
}

float3 project(float3 p)
{
	float3 v = p - EYE;
	float z = dot(v, FWD);
	float2 ndc = float2(dot(v, RIGHT) / (z * TAN_H), dot(v, UP) / (z * TAN_V));

	return float3(ndc * float2(0.5, -0.5) + 0.5, z);
}

bool onScreen(float2 uv)
{
	return uv.x >= 0.0 && uv.y >= 0.0 && uv.x <= 1.0 && uv.y <= 1.0;
}

float3 skyColor(float3 dir)
{
	float3 gradient = lerp(HORIZON, ZENITH, saturate(dir.z));
	float3 above = normalize(float3(dir.xy, max(dir.z, 1e-3)));
	float3 sky = 1.0 - exp(-max(tex2Dlod(SkyLut, float4(lutUV(above), 0.0, 0.0)).rgb, 0.0) * SKY_EXPOSURE);

	return lerp(gradient, sky * LUT_SCALE, LUT_WEIGHT);
}

float4 puddleReflection(float3 p, float3 dir, float3 fallback, float2 halfTexel, float samples, float3 fog, float3 fogLight, float jitter)
{
	float stepFactor = pow(SSR_MAX / SSR_START, 1.0 / (SSR_STEPS - 1));
	float t = SSR_START * pow(stepFactor, jitter);
	float tPrev = 0.0;

	[loop]
	for (int s = 0; s < SSR_STEPS; s++)
	{
		float3 q = project(p + dir * t);
		if (q.z <= 0.0 || !onScreen(q.xy))
		{
			break;
		}

		float raw = tex2Dlod(Depth, float4(q.xy + halfTexel, 0.0, 0.0)).r;
		float sceneZ = raw * DEPTH_SCALE;
		if (!IsSkyDepth(raw) && sceneZ < q.z && q.z - sceneZ < max(t - tPrev, max(SSR_MIN_THICKNESS, sceneZ * SSR_THICKNESS_RATIO)))
		{
			float tNear = tPrev;
			float tFar = t;
			float farBehind = q.z - sceneZ;
			float farZ = sceneZ;
			for (int r = 0; r < SSR_REFINE; r++)
			{
				float tMid = (tNear + tFar) * 0.5;
				float3 m = project(p + dir * tMid);
				float mRaw = tex2Dlod(Depth, float4(m.xy + halfTexel, 0.0, 0.0)).r;
				float mZ = mRaw * DEPTH_SCALE;
				if (!IsSkyDepth(mRaw) && mZ < m.z)
				{
					tFar = tMid;
					farBehind = m.z - mZ;
					farZ = mZ;
				}
				else
				{
					tNear = tMid;
				}
			}

			if (farBehind < max(SSR_HIT_SLACK, max((tFar - tNear) * 2.0, farZ * SSR_HIT_RATIO)))
			{
				float2 hitUV = project(p + dir * tFar).xy;
				float4 hitFrame = tex2Dlod(Frame, float4(hitUV + halfTexel, 0.0, 0.0));
				if (abs(SliceDepth(farZ, hitFrame.a * 255.0, samples) - farZ) <= farZ * SSR_THICKNESS_RATIO)
				{
					float edge = saturate(min(hitUV.x, 1.0 - hitUV.x) / 0.1) * saturate(min(hitUV.y, 1.0 - hitUV.y) / 0.1);
					float3 seen = lerp(fogLight, hitFrame.rgb, exp(-FogLayerDepth(fog.x, fog.y, fog.z, p.z, p.z + dir.z * tFar, tFar)));

					return float4(lerp(fallback, seen, edge), edge);
				}
			}
		}

		tPrev = t;
		t *= stepFactor;
	}

	return float4(fallback, 0.0);
}

PS_OUT main(PS_IN i)
{
	float2 uv = i.spos.xy / i.spos.w * float2(0.5, -0.5) + 0.5;
	float2 sx = float2(ddx(uv).x, 0.0);
	float2 sy = float2(0.0, ddy(uv).y);
	float2 halfTexel = float2(abs(sx.x), abs(sy.y)) * 0.5;
	uv += halfTexel;

	float4 frame = tex2D(Frame, uv);
	float raw = tex2D(Depth, uv).r;
	float d = IsSkyDepth(raw) ? FADE_END * 4.0 : raw * DEPTH_SCALE;
	float slope = (abs(ddx(raw)) + abs(ddy(raw))) / max(raw, 1e-4);
	float bias = DEPTH_BIAS + (slope < EDGE_SLOPE ? slope : 0.0);
	float depth = IsSkyDepth(raw) ? 1.0 : saturate(ZFAR / (ZFAR - ZNEAR) * (1.0 - ZNEAR / (d * (1.0 - bias))));
	float samples = max(floor(i.color.b * 255.0 + 0.5), 1.0);
	d = SliceDepth(d, frame.a * 255.0, samples);

	float3 view = viewRay(uv);
	float3 ray = normalize(view);
	float t = d * length(view);
	float3 rel = view * d;
	float3 p = EYE + rel;
	float3 ax = neighbour(uv + sx);
	float3 bx = neighbour(uv - sx);
	float3 ay = neighbour(uv + sy);
	float3 by = neighbour(uv - sy);
	float spike = max(SPIKE_MIN, d * SPIKE_RATIO);
	[branch] if (min(dot(ax - rel, FWD), dot(bx - rel, FWD)) > spike || min(dot(ay - rel, FWD), dot(by - rel, FWD)) > spike)
	{
		return output(frame.rgb, depth);
	}

	float3 n = normalize(cross(nearer(rel, ax, bx), nearer(rel, ay, by)));
	n = dot(n, ray) > 0.0 ? -n : n;

	float upward = smoothstep(UP_MIN, UP_FULL, n.z) * saturate(remap(t, FADE_END, FADE_START, 0.0, 1.0));
	[branch] if (max(WET, POOL) * upward <= 0.001)
	{
		return output(frame.rgb, depth);
	}

	float4 cover = exposure(p, n, floor(EYE.xy / COLUMN));
	float gloss = cover.y;
	float rainWet = FROZEN ? 0.0 : WET;
	float wet = rainWet * upward * cover.x;
	float patch = tex3Dlod(Noise, float4(p.xy * PATCH_SCALE, 0.5, 0.0)).r;
	float patchWet = lerp(1.0 - PATCH_DRY, 1.0, smoothstep(0.3, 0.7, patch));
	float damp = wet * patchWet;
	float soaked = max(damp, rainWet * upward * cover.z * patchWet);
	float shore = max(damp, rainWet * upward * cover.w * patchWet);

	float film = shore * gloss * smoothstep(FILM_START, FILM_FULL, rainWet) * saturate(remap(t, PUDDLE_FADE_END, PUDDLE_FADE_START, 0.0, 1.0));

	float share = length(SUN);
	float3 sunDir = SUN / max(share, 1e-4);
	float flatLight = share * sunDir.z + (1.0 - share);
	float slopeLight = share * saturate(dot(n, sunDir)) + (1.0 - share) * (1.0 + n.z) * 0.5;
	float3 lit = frame.rgb * lerp(1.0, saturate(flatLight / max(slopeLight, 1e-3)), soaked);

	float3 r = reflect(ray, n);
	float3 sky = lerp(HORIZON, ZENITH, saturate(r.z));
	float fresnel = F0 + (1.0 - F0) * pow(1.0 - saturate(dot(-ray, n)), 5.0);
	float3 color = lerp(lit * lerp(1.0, DARKEN, soaked), sky, fresnel * SHEEN * shore * gloss * (1.0 - film));

	float threshold = PUDDLE_LEVEL + (1.0 - gloss) * ABSORB_LEVEL;
	float level = patch;
	[branch] if (abs(patch - threshold) < PUDDLE_DETAIL)
	{
		level += (tex3Dlod(Noise, float4(p.xy * PUDDLE_DETAIL_SCALE, 0.25, 0.0)).r - 0.5) * PUDDLE_DETAIL;
	}

	float puddle = smoothstep(threshold, threshold + PUDDLE_EDGE, level)
		* upward * cover.x * (FROZEN ? 0.0 : 1.0)
		* saturate(remap(t, PUDDLE_FADE_END, PUDDLE_FADE_START, 0.0, 1.0));

	[branch] if (puddle > 0.01 || film > 0.01)
	{
		float near = RainNear(t);
		float heavy = RainHeavy(RAIN);
		float2 slope = float2(0.0, 0.0);
		[branch] if (puddle > 0.01)
		{
			slope = RainRipples(p.xy, RAIN, TIME) * near * puddle;
		}

		float flat = smoothstep(PUDDLE_FLAT, 1.0, n.z);
		float2 downhill = -n.xy / max(length(n.xy), 1e-3);
		float2 across = float2(-downhill.y, downhill.x);
		float streak = tex3Dlod(Noise, float4(dot(p.xy, across) * FLOW_ACROSS_SCALE, (p.z + TIME * FLOW_SPEED) * FLOW_ALONG_SCALE, 0.75, 0.0)).r;
		float3 sheetBase = normalize(lerp(n, float3(0.0, 0.0, 1.0), flat));
		float3 flow = normalize(sheetBase + float3(across * (streak - 0.5) * FLOW_TILT * (1.0 - flat), 0.0));
		float3 still = normalize(float3(-slope, 1.0));
		float3 base = normalize(lerp(sheetBase, float3(0.0, 0.0, 1.0), puddle));
		float3 surface = normalize(lerp(flow, still, puddle));
		float3 dir = reflect(ray, surface);
		dir.z = lerp(dir.z, abs(dir.z), max(flat, puddle));
		float3 fog = float3(i.color.r * FOG_DENSITY_MAX, FOG_BASE, i.color.g * FOG_FALLOFF_MAX);
		float3 fogLight = HORIZON * FOG_AMBIENT;
		float3 fallback = lerp(fogLight, skyColor(dir), exp(-FogLayerDepth(fog.x, fog.y, fog.z, p.z, p.z + dir.z * FOG_RANGE, FOG_RANGE)));
		float jitter = frac(52.9829189 * frac(dot(floor(uv / (2.0 * halfTexel)), float2(0.06711056, 0.00583715))));
		float4 reflection = puddleReflection(p + base, dir, fallback, halfTexel, samples, fog, fogLight, jitter);
		float3 mirror = reflection.rgb;
		float troubled = 1.0 - heavy * (1.0 - near) * RAIN_HEAVY_FAR_BLUR * reflection.a;
		float facing = pow(1.0 - saturate(dot(-ray, surface)), 5.0);
		float sheet = film * (1.0 - puddle) * lerp(1.0, lerp(FILM_STREAK_MIN, 1.0, streak), 1.0 - flat);
		color = lerp(color, mirror, (FILM_F0 + (1.0 - FILM_F0) * facing) * sheet * troubled);
		float3 pool = lerp(lit * PUDDLE_DARK, mirror, (PUDDLE_F0 + (1.0 - PUDDLE_F0) * facing) * lerp(ABSORB_REFLECT, 1.0, gloss) * troubled);
		color = lerp(color, pool, puddle);
	}

	[branch] if (FROZEN)
	{
		float gate = smoothstep(FROST_GLOSS_MIN, FROST_GLOSS_FULL, gloss);
		float density = lerp(FROST_PATCH_MIN, 1.0, smoothstep(0.35, 0.65, IceNoise(Noise, p.xy, FROST_PATCH_TILE, 0.33)));
		float amount = WET * upward * cover.x * gate * density;
		float detail = saturate(remap(t, FROST_DETAIL_END, FROST_DETAIL_START, 0.0, 1.0));
		float crystal = 0.0;
		[branch] if (amount > 0.001 && detail > 0.0)
		{
			float2 warp = float2(IceNoise(Noise, p.xy, FROST_WARP_TILE, 0.15), IceNoise(Noise, p.xy, FROST_WARP_TILE, 0.85)) - 0.5;
			float2 q = p.xy + warp * FROST_WARP;
			crystal = max(FrostFeathers(Noise, q, FROST_CRYSTAL_SIZE), FrostFeathers(Noise, q + 17.0, FROST_CRYSTAL_SMALL) * 0.7) * detail;
		}

		float grain = IceNoise(Noise, p.xy, FROST_GRAIN_TILE, 0.47);
		float3 white = FROST_WHITE * saturate(dot(lit, FROST_LUMA) * FROST_GAIN + FROST_LIFT);
		color = lerp(color, white, saturate(amount * lerp(FROST_BASE, FROST_CRYSTAL, crystal) * (0.75 + 0.5 * (grain - 0.5))));

		float2 sp = p.xy / FROST_SPARKLE_CELL;
		float2 cell = floor(sp);
		[branch] if (amount > 0.001 && t < FROST_SPARKLE_RANGE && hash(cell) > FROST_SPARKLE_RATE)
		{
			float dotMask = 1.0 - smoothstep(FROST_SPARKLE_SIZE * 0.5, FROST_SPARKLE_SIZE, length(sp - cell - IceHash2(cell)));
			float3 tilt = float3(hash(cell + 1.7), hash(cell + 3.1), hash(cell + 5.3)) - 0.5;
			float3 facet = normalize(n + tilt * FROST_SPARKLE_TILT);
			float glint = pow(saturate(dot(reflect(ray, facet), sunDir)), FROST_SPARKLE_POWER) * share;
			color += white * glint * dotMask * FROST_SPARKLE_GAIN * amount * (1.0 - t / FROST_SPARKLE_RANGE);
		}
	}

	return output(color, depth);
}
