# borealis

Our most epic *(maybe not)* and beloved *(that's mostly me I think...)* shaderpack!!!

> 1) **If you don't understand source engine basics such as depth and color passes, etc... You probably shouldn't touch this :v**
> 2) **If you add a new shader PLEASE COMMIT THE RELEVANT .hlsl!!!**
> 3) **Everything in this readme was read, corrected and approved by a human (hi!!!) so it is correct albeit the wording is a bit weird at times, sorry!**

Metastruct's client shader effects built for gm_construct_m3 but will *mostly* work on other maps.

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
- We do not mount shaders for builds that are not Windows/Proton because the native builds of Linux and MacOS use `ToGL` (https://github.com/valvesoftware/togl), which fucks up with them.
- Shaders start with `shaderpack.WhenMounted`, this waits for every `.vcs` needed.

## Compiling

`./compile.sh [-s] GMOD_DIR name [name ...] -- COMPILER_COMMAND...` compiles `shaders/<name>.hlsl` into `GMOD_DIR/garrysmod/shaders/fxc/<name>.vcs`.
- `GMOD_DIR` is the GarrysMod install folder.
- After `--`, put the command you use to run ShaderCompile, e.g. `-- ShaderCompile.exe` or `-- wine /path/to/ShaderCompile.exe`.
- `-s` writes `<name>_<unix>.vcs` instead, so we can mount a new version of the same shader with a timestamp.

On Windows, use `compile.ps1`:
```powershell
.\compile.ps1 -GmodDir "C:\path\to\GarrysMod" -Names ssao_ps30,sky_ps30 -Compiler "C:\path\to\ShaderCompile.exe"
```
Add `-Stamp` for the timestamped name.

> I recommend using [autoshader](https://github.com/Earu/gm_autoshader) for iterating quickly between shader versions, it can get quite tedious otherwise.

## Core

### sh_shaderpack

- `cl_shaderpack 1` is the main convar and will override every `cl_draw_*` cvar.
- `shaderpack.Toggle(id, convar, shaders, start, stop)` makes a cvar to start/stop and returns the apply function.
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
- Refog: glow render modes draw after `PostDrawTranslucentRenderables`. In `PreDrawViewModels` the frame is recaptured, changed pixels are marked in the stencil with a depth marker (`depthmark_ps30`), and refog effects draw again over them. Most of its cost is the second slice capture.

### sh_cover

A map of where there is open sky. It works with props and whatnot within a short radius ~750units, but further is only map geometry.

- Span map: the server bakes the BSP's world faces into 1024x1024 columns of 32 units, up to 4 sky-open height spans per column (RGBA16 VTF, `include/cover_spans.hlsl`). It sends the compressed blob through `fatdl` or the `net` library, clients cache the VTF under `data/shaderpack/cover`. Nodraw brushes and static props are not included in it.
- `cover.SkyLevel()` gives the floor of the outdoor level the eye is in. Typically volumetric clouds and auroras use it to set their height in the map.
- Cover window: a 64x64 grid of 24-unit columns around the eye, traced with `MASK_SOLID` (props included, players filtered). Each column stores where rain stops: a roof, the water surface over a lake bed, the ground, or the top of the world when the sky is blocked. Columns are retraced when the eye moves 80 units in z and continuously at a low rate, so props built later count. Used by rain, ripples, wetness and fog. `cover.Listen` notifies consumers per column.

### sh_bsp

BSP parser.

### cl_depth_hacks

Detection of things that are drawing into the translucent pass even though they are opaque or mostly opaque.

- See-through materials (wireframe, additive, translucent) get render mode 4 so they stop writing a fake depth over the sky.
- Depth plans for entities that break the depth pass: `GetRenderMesh` entities, PAC3's `RenderOverride` (wrapped), prop2mesh, `render.MaterialOverride` leaks.
- Alpha-tested brush entities get a proxy followed by a state-reset quad, since they corrupt later draws without a base texture. (fixed in https://github.com/Facepunch/garrysmod-issues/issues/7095, should probably remove next gmod update).
- WireGPU and lua screens get depth.
- World and model materials flagged `$translucent` that are really cutouts are switched to alpha test by measuring texture alpha, cached in `data/shaderpack/opacity`.

### cl_wind

`shaderpack.wind`: fixed heading of 20 degrees, wind blows toward it. `Strength()` is a wall-clock breeze (0.15 to 0.45), pulled to 1.5 by rain, 0.5 by snow, cut by fog. The heading cannot change at runtime: clouds and fog animate as `position - wind * time`. Used by grass, seagrass, kelp, rain, snow, leaves, clouds and fog.

### halo

`lua/includes/modules/halo.lua` replaces GMod's halo library, same API (`halo.Add`, `halo.Render`, `halo.RenderedEntity`, `PreDrawHalos`).

- Entities are drawn through their own path: `RenderOverride`, `ENT:Draw` / `DrawTranslucent`, `SWEP:DrawWorldModel`, PAC3 parts, clientside and bonemerged children (prop2mesh meshes, held weapons). Stock halo only called `DrawModel`, so those were missing. Entities checking `halo.RenderedEntity() == self` can still draw a plain model.
- Each group gets a stencil id, the ids become codes 230 to 255 in frame alpha (an 8x MSAA edge blend tops out at 223, so it never reads as a group), then `halo_rows_ps30` and `halo_ps30` draw a crisp outline from an exact distance, `max(blurx, blury)` pixels wide (max 15). Up to 6 groups per pass. Frame RGB is never copied or restored.
- Passes are scissored to the screen rect of the drawn entities' render bounds, full screen when a corner is behind the camera or PAC3 is involved. Content drawn outside an entity's render bounds gets no outline.
- Without the shaders (ToGL, `cl_shaderpack 0`) it falls back to the stock blur glow, still with the new entity drawing.
- `core/sv_halo` registers the shaders. The loader keeps `sv_` files on the server and `cl_` files on the client.

### cl_bench

`ms_shaderpack_bench` Needs `fps_max 0` and vsync off. Literally the benchmark of the shaderpack.

## Effects

### Sky

- **procsky** `cl_draw_procsky`: single-scattering atmosphere (Rayleigh, Mie, ozone) rendered into a 256x128 LUT 5 times a second; `sky_ps30` reads it and adds the sun disc. The same model runs in Lua for the fog colour (horizon averaged over 8 azimuths), the cloud lighting and sky colours other effects read (`procsky.GetLights`, `GetCloudLighting`, `GetSkyColors`, `GetLut`). It overrides `SetupWorldFog` with tod's range and the horizon colour.
- **Theme** `procsky.SetTheme`: seasonal look, every key optional: `moonVisible`, `clouds`, `auroraHue`, `stars`, `airglow`, `fogScale`, `tintMul`, `tint`, `overcast`, `overcastBrightness`. Rain and snow set `overcast`.
- **Night sky and auroras** `cl_draw_auroras`: procedural stars, a milky way from `materials/shaderpack/aurora/milkyway.vtf` (baked offline, changing `SKY_POLE` needs a rebake) and horizon airglow. Stars fade in once the sun is 3 degrees below the horizon. Aurora curtains render into a 1024 map in `PreRender` and show only in deep night (21:30 to 02:30 at full).
- **Sun shafts** `cl_draw_sunshafts`: after the translucent pass, a near quad sets frame alpha 0 and a far quad depth-tested against the world sets alpha 1 where sky shows. The frame is blurred toward the sun twice at half resolution and added in the sun's colour. Needs HDR (a frame with alpha). Off under overcast.
- **Cheap clouds** `cl_draw_clouds`: the vclouds volume baked into lat-long RGBA16F LUTs, one band of 16 per frame, crossfaded between bakes. The bake origin is fixed per level. Deck height is `max(ceiling, floor + 4800)`, 14000 under overcast. Falls back to a mesh deck without shaders.
- **Volumetric clouds** `cl_draw_vclouds`: a world-space slab ray marched at composite order 10, 5000 units above `cover.SkyLevel()` (3000 outside levels). Geometry occludes it and the camera can fly into it. It replaces the skybox deck while on. Coverage drifts on two slow sines off the shared wall clock (0.38 ± 0.1), 0.8 under rain and snow. It fogs itself with the engine's fog ramp. Light colours are packed as an 8-bit hue plus a log scale.
- **Cloud shadows** (follows `cl_draw_vclouds`): the slab's shade on the ground, same field and wind as vclouds via `vclouds.GetLayer`. Fades in with sun elevation from 2 to 12 degrees.

### Weather

- **Fog** `cl_draw_fog`: a ray-marched height layer at order 20. tod's fog (ground layer) and rain (taller haze) profiles are blended by share. The base eases to the ground under the player plus 40 units, the colour is the engine fog colour.
- **Rain and snow** `cl_draw_precipitations`: one quad per drop placed by the vertex shader from a template mesh, over a 3x3 grid of 512-unit tiles around the eye. The streak shader discards below the cover window's cut, so rain stops at roofs and doorways. Ripples are one quad per block of level ground, shaded as a height field mirroring the horizon colour. Constants are set once per frame and tile positions ride in the model matrix: with the threaded material system, per-draw constants land on the wrong draws.
- **Wetness** `cl_draw_wetness`: darkens and glosses up-facing surfaces the rain reaches (cover window, far gloss map beyond it), with puddles on level ground using screen-space reflections and the procsky LUT as fallback. Wets toward tod's rain amount and dries slowly.

### Liquids

- **Water** `cl_draw_water`: replaces engine water on surface water brushes. The engine materials are forced cheap, nearly transparent and fogless; borealis draws its own surface meshes at order 1 (waves, reflections, per-body murk and sky openness) and a full-screen underwater pass with a sky fill and the sun seen from below. Other liquids are left to the engine. `surfacewater.CausticSource` exposes the surface for caustics.
- **Lava** `cl_draw_lava`: light, heat shimmer, edge glow and embers around m3's magma cave pools. A 256x256 mask is baked once on the client into `data/shaderpack/lava`. Draws only within 1500 units of a pool.
- **Lava splashes**: crowns, spatters and drops on lava. Bullet splashes come from the client's water splash sounds; props and players need the server half (`lava.Splash`, net `ms_lava_splash`).

### Foliage

`cl_foliage` builds tufts per 512-unit chunk within a frame budget, batches them into meshes sorted by vis cluster and culls by frustum, PVS and line of sight against world brushes. Lightmap light is baked into vertices and scaled by tod's current light style.

- **Grass** `cl_draw_grass`, `cl_draw_grass_distance`: tufts of three crossed quads on grass surfaces up to a slope limit. The vertex shader tilts blades downwind. Sparser and fully dry in winter, half dry in autumn.
- **Seagrass** `cl_draw_seagrass`: meadows on sunlit sandy water beds.
- **Kelp** `cl_draw_kelp`: forests on sunlit rocky sea beds.
- **Leaves** `cl_draw_leaves`: falling and fallen leaves, October only.

### Lighting

- **SSAO** `cl_draw_ssao`: two-pass SAO. Pass one samples a spiral around each pixel at half resolution (`cl_ssao_halfres`), pass two blurs a 4x4 window that cancels the sample pattern and composites at order -1. Lightmaps already contain occlusion, so it removes at most `cl_ssao_ambient` of brightness. Tuning: `cl_ssao_radius`, `cl_ssao_intensity`, `cl_ssao_strength`, `cl_ssao_debug`. Also in the spawnmenu post process tab.

## Writing an effect

- Register with `shaderpack.Toggle` and add the file to `FILES` in the right place.
- Create a new material on every start. A material kept from an older version silently drops the constants it was not created with.
- Set `$linearread_textureN 1` for data textures; only `$basetexture` reads linear by default.
- `screenspace_general` from `CreateShaderMaterial` writes no alpha and discards pixels with output alpha 0.
- Anything memoized per frame must key on the view: the m3 apartments render a second main view each frame.
- Hook callbacks that error are removed, and skyboxer's dispatcher dies with them. Wrap experimental code in `pcall`.
- Keep module tables as `x = x or {}` under `shaderpack.*`; reassigning one on reload wipes live registrations.
- Full-screen passes are expensive: measure before adding taps or march steps.

## Data

Clients write caches under `data/shaderpack/`: `cover` (span maps), `lava` (pool masks), `opacity` (cutout measurements). Delete them to force a rebuild.
