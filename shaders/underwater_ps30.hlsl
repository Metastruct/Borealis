const float4 Constants0 : register(c0);
const float4 Constants1 : register(c1);
const float4 Constants2 : register(c2);
const float4 Constants3 : register(c3);

sampler Frame : register(s0);
sampler Depth : register(s1);
sampler NormalMap : register(s2);
sampler3D Noise : register(s3);

#include "include/water_waves.hlsl"
#include "include/slices.hlsl"
#include "include/water_optics.hlsl"

#define EYE_POS      Constants0.xyz
#define SURFACE_Z    Constants0.w
#define EYE_FORWARD  Constants1.xyz
#define TIME         Constants1.w
#define ZENITH_COLOR Constants2.xyz
#define MURK         Constants2.w
#define SUN_DIR      Constants3.xyz
#define SUNLIT       Constants3.w

#define SKY_DEPTH_TOLERANCE 2.0
#define FAR 100000.0


#define SHAFT_STEPS       12
#define SHAFT_RANGE       800.0
#define SHAFT_BRIGHTNESS  0.12
#define SHAFT_CONTRAST    2.5
#define SHAFT_G           0.35
#define SHAFT_FOCUS_DEPTH 300.0
#define SHAFT_LOD         3.0
#define SHAFT_EPSILON     16.0
#define SHAFT_SWELL       2.0
static const float3 SUN_TINT = float3(1.0, 0.95, 0.85);


#define WATERLINE_WIDTH 0.1
#define WATERLINE_SHADE 0.35

struct PS_IN
{
	float2 uv    : TEXCOORD0;
	float4 color : TEXCOORD1;
	float3 wpos  : TEXCOORD2;
	float4 spos  : TEXCOORD3;
};

float4 main(PS_IN i) : COLOR
{
	float2 uv = i.spos.xy / i.spos.w * float2(0.5, -0.5) + 0.5;
	uv += float2(abs(ddx(uv).x), abs(ddy(uv).y)) * 0.5;

	float4 frame = tex2D(Frame, uv);
	float3 original = frame.rgb;
	float3 scene = original;
	float3 ray = normalize(i.wpos - EYE_POS);

	float depth = SceneDepth(tex2D(Depth, uv).r * DEPTH_SCALE, frame.a);
	bool beyondDepth = depth <= 0.0 || abs(depth - DEPTH_SCALE) < SKY_DEPTH_TOLERANCE;
	float sceneDistance = beyondDepth ? FAR : depth / max(dot(ray, EYE_FORWARD), 0.05);

	float3 underwaterSun = -SUN_DIR;
	float sunUp = saturate(SUN_DIR.z * 10.0);

	float3 worldPos = EYE_POS + ray * sceneDistance;
	float caustics = CausticLight(NormalMap, worldPos, EYE_POS, SURFACE_Z, SUN_DIR, TIME);
	scene *= beyondDepth ? 1.0 : lerp(1.0, caustics, SUNLIT);

	float eyeDepth = max(SURFACE_Z - EYE_POS.z, 0.0);
	float surfaceDistance = ray.z > 0.0 ? eyeDepth / ray.z : FAR;
	float waterDistance = min(sceneDistance, surfaceDistance);

	float3 color = WaterAttenuate(scene, waterDistance * MURK, WaterInScatter(ZENITH_COLOR, ray, eyeDepth * MURK));

	float marchRange = min(waterDistance, SHAFT_RANGE);
	float stepLength = marchRange / SHAFT_STEPS;
	float jitter = frac(52.9829189 * frac(dot(uv * float2(1920.0, 1080.0), float2(0.06711056, 0.00583715))));

	float cosTheta = dot(ray, -underwaterSun);
	float g2 = SHAFT_G * SHAFT_G;
	float phase = (1.0 - g2) / pow(max(1.0 + g2 - 2.0 * SHAFT_G * cosTheta, 1e-3), 1.5);
	float skyBrightness = min(dot(ZENITH_COLOR, float3(0.2126, 0.7152, 0.0722)) / WATER_SCATTER_REF_LUMA, 1.5);

	float3 shafts = 0;
	[loop]
	for (int s = 0; s < SHAFT_STEPS; s++)
	{
		float t = (s + jitter) * stepLength;
		float3 p = EYE_POS + ray * t;
		float below = max(SURFACE_Z - p.z, 0.0);
		float2 entry = SunEntryPoint(p, SURFACE_Z, underwaterSun);
		float focus = WaveCausticLod(NormalMap, entry, TIME, SHAFT_FOCUS_DEPTH, SHAFT_LOD, SHAFT_EPSILON);
		float swell = WaveNoise(Noise, float3(entry / SWELL_TILE + TIME * SWELL_DRIFT, TIME * SWELL_EVOLVE));
		focus += SHAFT_SWELL * (swell * swell - 0.33);
		float3 transmission = exp(-WATER_ABSORB * MURK * (below / max(-underwaterSun.z, 0.05) + t));
		shafts += transmission * max(1.0 + SHAFT_CONTRAST * (focus - 1.0), 0.0);
	}

	color += SUN_TINT * skyBrightness * sunUp * SUNLIT * phase * SHAFT_BRIGHTNESS * shafts / SHAFT_STEPS;

	float waterZ = SURFACE_Z + SwellHeight(Noise, i.wpos.xy, TIME) - SWELL_HEIGHT * 0.33;
	color = i.wpos.z < waterZ ? max(color, 0.0) : original;
	float waterline = 1.0 - smoothstep(0.0, WATERLINE_WIDTH, abs(i.wpos.z - waterZ));
	color *= lerp(1.0, WATERLINE_SHADE, waterline);

	return float4(color, 1.0);
}
