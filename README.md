# borealis

Our most epic *(maybe not)* and beloved *(that's mostly me I think...)* shaderpack!!!

> 1) **If you don't understand source engine basics such as depth and color passes, etc... You probably shouldn't touch this :v**
> 2) **If you add a new shader PLEASE COMMIT THE RELEVANT .hlsl!!!**
> 3) **Everything in this readme was read, corrected and approved by a human (hi!!!) so it is correct albeit the wording is a bit weird at times, sorry!**

Metastruct's client shader effects built for gm_construct_m3 but will *mostly* work on other maps, plus [tod](#tod), the time of day, weather and season they're based on.

Relevant documentation and help pages:
- https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/dx-graphics-hlsl
- https://developer.valvesoftware.com/wiki/Shader_Authoring
- https://wiki.facepunch.com/gmod/custom_shaders
- https://wiki.facepunch.com/gmod/Shaders/screenspace_general
- https://wiki.facepunch.com/gmod/Shaders/screenspace_general_8tex
- https://github.com/meetric1/gmod_shader_guide

## General facts

- Every effect draws through `screenspace_general` (or `_8tex`) with a custom `$pixshader` and sometimes `$vertexshader`.
- Gmod keeps the first shader it loaded under a certain name, so if you recompiled a shader with the same name, you need a restart. (This is also valid for the server e.g you need to reboot, not restart!).
- `shader_to_gma` packs `shaders/fxc` into a GMA, sends it to clients when they spawn and mounts it. (`ShaderMounted` is called at that point if you need that).
- The native builds of Linux and MacOS use `ToGL` (https://github.com/valvesoftware/togl), which crashes the game on `tex3Dlod` and on a `cmp` that writes `DEPTH0` (it emits invalid GLSL). `shader_to_gma` adds a `<name>_togl_<ps30/vs30>` copy of each shader that has them and those clients use it instead: `texldl` on volume samplers becomes `texld` (the volumes have no mips, so it samples the same), and the depth `cmp` writes a spare temp that is then moved into `oDepth`. Shaders with other instructions ToGL rejects are left off on those builds. Only the `x86-64` branch's ToGL is supported: the main and `dev` branch builds reject `ddx`/`ddy`, compare branches and loops, so native clients on those branches get no shaders.
- Shaders start with `shaderpack.WhenMounted`, this waits for every `.vcs` needed.

## Compiling

`./compile.sh [-s] GMOD_DIR name [name ...] -- COMPILER_COMMAND...` compiles `shaders/<name>.hlsl` into `GMOD_DIR/garrysmod/shaders/fxc/<name>.vcs`.
- `GMOD_DIR` is the GarrysMod install folder.
- After `--`, put the command you use to run ShaderCompile, e.g. `-- ShaderCompile.exe` or `-- wine /path/to/ShaderCompile.exe`.
- `-s` writes `<name>_<unix>.vcs` instead, so we can mount a new version of the same shader with a timestamp.

On Windows, use `compile.ps1`:
```powershell
.\compile.ps1 -GmodDir "C:\path\to\GarrysMod" -Names borealis_ssao_ps30,borealis_sky_ps30 -Compiler "C:\path\to\ShaderCompile.exe"
```
Add `-Stamp` for the timestamped name.

> I recommend using [autoshader](https://github.com/Earu/gm_autoshader) for iterating quickly between shader versions, it can get quite tedious otherwise.

## Core

### sh_shaderpack

- `borealis_enabled 1` is the main convar and will override every `borealis_*` cvar.
- `shaderpack.Toggle(id, convar, shaders, start, stop)` makes a cvar to start/stop and returns the apply function.
- `shaderpack.PostProcess(name, entry)` adds a Post Process tab entry whose tick box shows off and locks while `borealis_enabled` is 0.
- `shaderpack.MigrateConVars()` copies saved values from the old `cl_*` names once per client, tracked by the `borealis_convars_renamed` cookie.
- `shaderpack.AfterWorld(id, fn)` runs `fn` after `InitPostEntity`. The shader GMA stays mounted over different sessions, so shaders would otherwise start before the map loads in.
- `shaderpack.UsableRT` whether a render target is real:tm:.
> During map load the engine creates a 32x32 error texture that makes `IsError()` false, and a material bound to it keeps that forever, not good.

### sh_depthslices

Shared depth for full-screen composites.

- The engine depth pass (`render.GetResolvedFullFrameDepth`) is R32F, view z / 4000 (4000 is a source engine constant here). Sky is 1.0. It only has what the engine draws e.g PAC3, grass, clientside Lua geometry, etc... are missing.
- The slice capture draws 32 log-spaced quads from 16 to 8000 units (`SLICE_RATIO` in `include/slices.hlsl`) that write slice codes into frame alpha, so Lua-drawn geometry gets a coarse depth. Shaders take the nearest of the two. The capture runs once per view, whoever asks first pays for it. Water writes exact depth into alpha as codes 64 and above.
> This is expensive, so make sure you need it before using it.
- `AddEffect(name, order, draw, refog, needsDepth)`: order is a distance, lower draws first and is farther.
- Effects must leave frame alpha alone, or the next effect reads their output as slice codes. Use `KeepAlpha` / `Composite`.
- Refog: glow render modes draw after `PostDrawTranslucentRenderables`. In `PreDrawViewModels` the frame is recaptured, changed pixels are marked in the stencil with a depth marker (`borealis_depthmark_ps30`), and refog effects draw again over them. Most of its cost is the second slice capture.

### sh_cover

A map of where there is open sky. It works with props and whatnot within a short radius ~750units, but further is only map geometry.

- Span map: the server bakes the BSP's world faces into 1024x1024 columns of 32 units, up to 4 sky-open height spans per column (RGBA16 VTF, `include/cover_spans.hlsl`). It sends the compressed blob through `fatdl` or the `net` library, clients cache the VTF under `data/shaderpack/cover`. Nodraw brushes and static props are not included in it.
- ToGL loads RGBA16 VTFs as black, so non-Windows clients write the same bytes as a double-width RGBA8888 VTF (`<key>_rgba8.vtf`) and `borealis_spanpack_ps30` packs it into an RGBA16 render target once.
- `cover.SkyLevel()` gives the floor of the outdoor level the eye is in. Typically volumetric clouds and auroras use it to set their height in the map.
- Cover window: a 64x64 grid of 24-unit columns around the eye, traced with `MASK_SOLID` (props included, players filtered). Each column stores where rain stops: a roof, the water surface over a lake bed, the ground, or the top of the world when the sky is blocked. Columns are retraced when the eye moves 80 units in z and continuously at a low rate, so props built later count. Used by rain, ripples, wetness and fog. `cover.Listen` notifies consumers per column.

### bspdata

BSP parser shared by borealis and tod, `require("bspdata")` then the `bspdata` global (`lua/includes/modules/bspdata.lua`).

### cl_depth_hacks

Detection of things that are drawing into the translucent pass even though they are opaque or mostly opaque.

- See-through materials (wireframe, additive, translucent) get render mode 4 so they stop writing a fake depth over the sky.
- Depth plans for entities that break the depth pass: `GetRenderMesh` entities, PAC3's `RenderOverride` (wrapped), prop2mesh, `render.MaterialOverride` leaks.
- Alpha-tested brush entities get a proxy followed by a state-reset quad, since they corrupt later draws without a base texture. (fixed in https://github.com/Facepunch/garrysmod-issues/issues/7095, should probably remove next gmod update).
- WireGPU and lua screens get depth.
- World and model materials flagged `$translucent` that are really cutouts are switched to alpha test by measuring texture alpha, cached in `data/shaderpack/opacity`.

### cl_wind

`shaderpack.wind`: fixed heading of 20 degrees, wind blows toward it. `Strength()` is a wall-clock breeze (0.15 to 0.45), pulled to 1.5 by rain, 0.5 by snow, cut by fog. The heading cannot change at runtime: clouds and fog animate as `position - wind * time`, and the grass vertex shader has it hardcoded (`WIND_DIR` in `include/grass_vs.hlsl`). Used by grass, seagrass, kelp, rain, snow, leaves, clouds and fog.

### halo

`lua/includes/modules/halo.lua` replaces GMod's halo library, same API (`halo.Add`, `halo.Render`, `halo.RenderedEntity`, `PreDrawHalos`).

- Entities are drawn through their own path: `RenderOverride`, `ENT:Draw` / `DrawTranslucent`, `SWEP:DrawWorldModel`, PAC3 parts, clientside and bonemerged children (prop2mesh meshes, held weapons). Stock halo only called `DrawModel`, so those were missing. Entities checking `halo.RenderedEntity() == self` can still draw a plain model.
- Each group gets a stencil id, the ids become codes 230 to 255 in frame alpha (an 8x MSAA edge blend tops out at 223, so it never reads as a group), then `borealis_halo_rows_ps30` and `borealis_halo_ps30` draw a crisp outline from an exact distance, `max(blurx, blury)` pixels wide (max 15). Up to 6 groups per pass. Frame RGB is never copied or restored.
- Passes are scissored to the screen rect of the drawn entities' render bounds, full screen when a corner is behind the camera or PAC3 is involved. Content drawn outside an entity's render bounds gets no outline.
- Without the shaders (ToGL rejected them, `borealis_enabled 0`) it falls back to the stock blur glow, still with the new entity drawing.
- `core/sv_halo` registers the shaders. The loader keeps `sv_` files on the server and `cl_` files on the client.

### cl_chunks

Shared lifecycle for world-grid effects: request within a radius, build queue (nearest first, chunks behind the eye last), frustum culling, eviction, pause and teardown. All grids share one adaptive build budget (4 to 8 ms per frame), so adding a grid cannot stack another budget on the frame. One grid loads at a time.

`chunks.Grid({ name, size, radius, pad, cacheLimit, load, build, destroy, failed })` returns a grid with `Start`, `Stop`, `SetPaused` and `Visible(chunks.View())`. `load` and `build(ch)` run in coroutines and call `chunks.YieldIfOverBudget()` in their loops. `build` sets `ch.cz` and `ch.radius` and returns a cost, 0 for an empty chunk. Finish `mesh.Begin` before calling `YieldIfOverBudget`. The effect keeps its materials, draw calls and finer occlusion.

### sh_trails

`shaderpack.trails`: the ground contact map shared by snow and grass.

- A 1024² RGBA16F window of 2048 units around the eye, addressed toroidally (`frac(x, -y) / 2048`), so recentring only clears the strips that enter.
- Entities whose bottom is near the brush ground under them (any `.mdl` entity, players, and their children) are drawn from above with an ortho camera into a stamp RT (Arkham Origins' capture), once per slice height with a clip plane at that height, with a MAX blend.
- Ground: five brush-only traces from the top of the entity's AABB (centre and four corners inset to 35%) are fitted to a plane, and the slice clip planes are tilted to it, so a prop lying on a slope is measured from the slope under it. A fit steeper than 50° falls back to a flat plane at the centre hit. `borealis_trailstamp_ps30` blurs the stamps into the trail map, also with a MAX blend.
- `trails.Use(id, user)` registers a consumer, `nil` removes it. The map runs while there is at least one. `user` is `{ channel, slices, live, recover, accept }`: the channel it owns (1 = R, 2 = G), its slice heights ascending, whether the channel is live, a function giving the refill per second for a trail channel, and `accept(groundTrace, x, y, groundZ, cache)` to skip entities. With slices `s1..sn`, geometry between `s(k-1)` and `sk` writes `1 - s(k-1) / sn`, so a texel holds the clearance under the lowest thing above it.
- Trail channels keep prints and refill: once a second they are decremented with a reverse-subtract blend, never resampled, so prints cannot drift. Surface colours are sRGB-decoded before blending, so the decrement is picked through `ToLinear`. Stationary entities are restamped once a second.
- Live channels hold where things are now. Each tracked entity keeps its stamp until it moves or goes away, then its old rect is cleared in the live channels (reverse subtract then MAX with 0, which leaves the others alone) and every live entity overlapping it is restamped in the same frame. `OnEntityCreated` forces a gather, so new props count on their first frame instead of within 0.25 s.
- Prints only exist inside the window and only for entities in your PVS. `ents.FindInBox` does not return clientside models, so they are never stamped.

### cl_skywall

Sky faces write no depth, so anything drawn after the world shows through them. Once per frame the world's sky faces are drawn into a screen-size RGBA16F target with its own depth buffer, as view depth / 4000 (`borealis_waterdepth_ps30`). Snow, grass, seagrass, kelp and water sample it at `VPOS` (`include/skywall.hlsl`) and discard pixels behind a sky face. `skywall.Texture()` renders it on the first call of a frame and returns `vgui/black` (no clipping) inside another render target. `skywall.InvSize()` gives the texel size the shaders need.

### cl_bench

`borealis_shaderpack_bench` Needs `fps_max 0` and vsync off. Literally the benchmark of the shaderpack.

## tod

Time of day, weather and season, the `tod` global.
`lua/autorun/tod.lua` is not tied to the borealis shaderpack and just works without borealis enabled or present.
- `sv_tod`: 0 manual, 1 realtime on the server's clock (its UTC offset is sent to clients), 2 demo (a day every 20 seconds). `settod <hour|demo|realtime>`, or `!tod` and `!weather` with aowl.
- Day cycle: hour-stamped keys in `lua/tod/default_cycle.lua` (`tod.SetConfigCycle`), sampled on a monotone cubic by `tod.SampleCycle`. `tod.AlignSunToLight` places the sun from the light level. Keys drive the skypaint, engine fog, shadows, the world light style (`tod.MultToLightEnv`, 98 to 127) and the `grade_*` values of `sh_grade`.
- Weather: one weather per hour slot, picked from a hash of the slot so every machine agrees, ramped over 10 minutes. `tod.AddOverrideConfig(name, config, probability, curve)` for rain and snow, `tod.AddFogConfig` for fog. `tod.GetWeather(name)` gives 0 to 1, `tod.force_weather` overrides it. `tod.SetVolumetricFog` hands a weather's fog to `borealis_fog`.
- Seasons: `tod.GetSeason()` is winter from December to February, autumn in October and November, summer otherwise. `sv_tod_season` forces one on the next map load.
  - Winter loads `snow.lua`: ground textures become snow, tinted by `tod.snow.SetTint`, and snow footsteps.
  - Other seasons load `rain.lua`: rumble outside, drips under cover, thunder with a flash. `cl_rain_volume`, `cl_rain_mute_losefocus`.
  - Autumn also loads `autumn.lua`, which recolours grass textures on the client.

## Effects

### Sky

- **procsky** `borealis_procsky`: single-scattering atmosphere (Rayleigh, Mie, ozone) rendered into a 256x128 LUT 5 times a second; `borealis_sky_ps30` reads it and adds the sun disc. The same model runs in Lua for the fog colour (horizon averaged over 8 azimuths), the cloud lighting and sky colours other effects read (`procsky.GetLights`, `GetCloudLighting`, `GetSkyColors`, `GetLut`). It overrides `SetupWorldFog` with tod's range and the horizon colour.
- **Theme** `procsky.SetTheme`: seasonal look, every key optional: `moonVisible`, `clouds`, `auroraHue`, `stars`, `airglow`, `fogScale`, `tintMul`, `tint`, `overcast`, `overcastBrightness`. Rain and snow set `overcast`.
- **Night sky and auroras** `borealis_auroras`: procedural stars, a milky way from `materials/shaderpack/aurora/milkyway.vtf` (baked offline, changing `SKY_POLE` needs a rebake) and horizon airglow. Stars fade in once the sun is 3 degrees below the horizon. Aurora curtains render into a 1024 map in `PreRender` and show only in deep night (21:30 to 02:30 at full).
- **Sun shafts** `borealis_sunshafts`: after the translucent pass, a near quad sets frame alpha 0 and a far quad depth-tested against the world sets alpha 1 where sky shows. The frame is blurred toward the sun twice at half resolution and added in the sun's colour. Needs HDR (a frame with alpha). Off under overcast.
- **Cheap clouds** `borealis_clouds`: the vclouds volume baked into lat-long RGBA16F LUTs, one band of 16 per frame, crossfaded between bakes. The bake origin is fixed per level. Deck height is `max(ceiling, floor + 4800)`, 14000 under overcast. Falls back to a mesh deck without shaders.
- **Volumetric clouds** `borealis_vclouds`: a world-space slab ray marched at composite order 10, 5000 units above `cover.SkyLevel()` (3000 outside levels). Geometry occludes it and the camera can fly into it. The engine depth has no 3D skybox, so the end of that pass copies a mask of its geometry, which hides the clouds while the eye is below the slab. It replaces the skybox deck while on. Coverage drifts on two slow sines off the shared wall clock (0.38 ± 0.1), 0.8 under rain and snow. It fogs itself with the engine's fog ramp. Light colours are packed as an 8-bit hue plus a log scale.
- **Cloud shadows** (follows `borealis_vclouds`): the slab's shade on the ground, same field and wind as vclouds via `vclouds.GetLayer`. Fades in with sun elevation from 2 to 12 degrees.

### Weather

- **Fog** `borealis_fog`: a ray-marched height layer at order 20. tod's fog (ground layer) and rain (taller haze) profiles are blended by share. The base eases to the ground under the player plus 40 units, the colour is the engine fog colour.
- **Rain and snow** `borealis_precipitations`: one quad per drop placed by the vertex shader from a template mesh, over a 3x3 grid of 512-unit tiles around the eye. The streak shader discards below the cover window's height, so rain stops at roofs and doorways. Ripples are one quad per block of level ground, shaded as a height field mirroring the horizon colour. Constants are set once per frame and tile positions ride in the model matrix: with the threaded material system, per-draw constants land on the wrong draws.
- **Wetness** `borealis_wetness`: darkens and glosses up-facing surfaces the rain reaches (cover window, far gloss map beyond it), with puddles on level ground using screen-space reflections and the procsky LUT as fallback. Wets toward tod's rain amount and dries slowly. Off in winter, when the ground is frozen.
- **Deep snow** `borealis_snow`: winter only. A 10-unit snow layer built from the world's BSP triangles up to about 72 degrees of slope, whatever their material (water and `tools/` textures excepted), so feet, wheels and props sink into it. Brush entities get none, since their faces move.
  - Mesh: triangles are clipped to a 32-unit grid in 512-unit chunks, lifted along z, given welded vertex normals and skirts on open edges. Depth thins to 30% over 48 units toward real drop-offs. Across a step of up to 24 units the lower snow ramps up over 48 units to meet the upper snow. Against taller walls snow drifts up: 20% of the wall's height, capped at 24 units, curving down over three times that width. Vertices under a roof or in water get no snow. Light is baked per vertex like foliage. It draws in `PostDrawOpaqueRenderables` and writes the engine depth pass with `borealis_waterdepth_ps30`.
  - Trails: the R channel of `core/sh_trails`, one 10-unit slice, so it is a mask of everything below the snow top, blurred and gained by 1.6. Entities on ground that cannot see the sky are skipped, since the map is 2D and the snow above them may be on a roof. Full refill takes 20 minutes, 2 minutes under heavy snowfall.
  - `borealis_snowcover_ps30` raymarches the trail map down from the snow top (POM), outputs depth at the hit so sunk feet show inside their prints, and adds self-shadowing toward the baked sun, sky-tinted walls and glints. `screenspace_general` gets no engine fog, so the shader applies it.
  - Projected shadows and decals on the ground under the snow are hidden by it.
  - Engine lights: projected textures (flashlights, lamps) come from `render.RenderFlashlights` drawing the chunks again with a `VertexLitGeneric` material. Dynamic lights have no listing API, so `core/cl_dynamic_lights` samples `render.ComputeDynamicLighting` on a 24x24 grid of 64-unit cells around the eye into a texture the shader reads. Grass reads the same dynamic light texture. Its blades are cut out in the pixel shader, so projected textures are rendered from above onto a ground-following proxy mesh into a second texture, which the grass shader samples at each blade's position.

### Liquids

- **Water** `borealis_water`: replaces engine water on surface water brushes. The engine materials are forced cheap, nearly transparent and fogless; borealis draws its own surface meshes at order 1 (waves, reflections, per-body murk and sky openness) and a full-screen underwater pass with a sky fill and the sun seen from below. Other liquids are left to the engine. `surfacewater.CausticSource` exposes the surface for caustics.
- **Lava** `borealis_lava`: light, heat shimmer, edge glow and embers around m3's magma cave pools. A 256x256 mask is baked once on the client into `data/shaderpack/lava`. Draws only within 1500 units of a pool.
- **Lava splashes**: crowns, spatters and drops on lava. Bullet splashes come from the client's water splash sounds; props and players need the server half (`lava.Splash`, net `borealis_lava_splash`).

### Foliage

`cl_foliage` builds tufts per 512-unit chunk on a `cl_chunks` grid, skipping the 3D skybox, batches them into meshes sorted by vis cluster and culls by frustum and PVS. Lightmap light is baked into vertices and scaled by tod's current light style.

- **Grass** `borealis_grass`, `borealis_grass_distance`: tufts of three crossed quads on grass surfaces up to a slope limit. The vertex shader tilts blades downwind. Sparser and fully dry in winter, half dry in autumn.
  - Pushing: the vertex shader leans tufts away from up to 5 pushers, added to the wind lean and capped at the same maximum. They ride in ambient cube rows 1 to 5 (`shaderpack.SetVertexConstants`) as `(x, floor(y) + radius / 128, floor(z) + strength * 0.99)`, since vertex shaders cannot read textures here. Active slots are packed first, so the shader skips all of them with one branch when row 1 is empty. Pushers are players and NPCs, plus any other model entity moving faster than 20 units/s, with a radius of their AABB half width plus 32. Every 32 units of travel they drop a trail point that recovers over 2.5 seconds on a smoothstep. Nothing switches in one frame: a pusher eases in and out over 0.35 s, slots keep their item across frames, a new item fades in over 0.3 s and an evicted one fades out over 0.4 s before its slot is reused. The 5 strongest and nearest to the eye win (pushers count double), so trails only show near the camera and shorten when several things move at once.
  - Trampling: the live G channel of `core/sh_trails`, slices at 10, 24, 40 and 64 units. The pixel shader reads the clearance at each pixel and shortens blades to it, leaning them out as they shorten, so grass stays under props and around feet, and stands back up as soon as they leave. The quads are not moved: the trail texture is only readable in the pixel shader. Every entity is stamped whatever the ground under it, so something on a balcony also flattens the grass below.
- **Seagrass** `borealis_seagrass`: meadows on sunlit sandy water beds.
- **Kelp** `borealis_kelp`: forests on sunlit rocky sea beds.
- **Leaves** `borealis_leaves`: falling and fallen leaves, October only.

### Lighting

- **SSAO** `borealis_ssao`: two-pass SAO. Pass one samples a spiral around each pixel at half resolution (`borealis_ssao_halfres`), pass two blurs a 4x4 window that cancels the sample pattern and composites at order -1. Lightmaps already contain occlusion, so it removes at most `borealis_ssao_ambient` of brightness. Tuning: `borealis_ssao_radius`, `borealis_ssao_intensity`, `borealis_ssao_strength`, `borealis_ssao_debug`. Also in the spawnmenu post process tab.

## Writing an effect

- Register with `shaderpack.Toggle` and add the file to `FILES` in the right place.
- Create a new material on every start. A material kept from an older version silently drops the constants it was not created with.
- Set `$linearread_textureN 1` for data textures; only `$basetexture` reads linear by default.
- `screenspace_general` from `CreateShaderMaterial` writes no alpha and discards pixels with output alpha 0.
- Anything memoized per frame must key on the view: the m3 apartments render a second main view each frame.
- Hook callbacks that error are removed, and skyboxer's dispatcher dies with them. Wrap experimental code in `pcall`.
- Keep module tables as `x = x or {}` under `shaderpack.*`; reassigning one on reload wipes live registrations.
- Full-screen passes are expensive: measure before adding taps or march steps.
- Inside a pushed render target, `render.DrawScreenQuadEx` takes screen coordinates and `render.DrawScreenQuad` fills the whole target regardless of the viewport. To fill a rect of an RT, use `cam.Start2D` and `surface.DrawTexturedRect`, which take RT pixels. `render.Clear` does respect `render.SetViewPort`.

## Data

Clients write caches under `data/shaderpack/`: `cover` (span maps), `lava` (pool masks), `opacity` (cutout measurements). tod writes autumn grass under `data/tod_autumn/`. Delete them to force a rebuild.
