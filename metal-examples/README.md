# C++ / Metal Examples

Four small, self-contained demos showing what C++ with Apple's Metal API can
do on a MacBook. Each example is a single Objective-C++ file (`main.mm`) —
C++ for all the logic and math, with a thin Objective-C layer for the window,
which is how real-world C++ Metal engines bind to macOS. Shaders are written
in Metal Shading Language and compiled at runtime, so everything you need to
read lives in one file per demo.

## Requirements

- A Mac (any Apple Silicon MacBook is ideal; Intel Macs with Metal work too)
- Xcode command line tools: `xcode-select --install`

No SDKs, package managers, or downloads beyond that.

## Build & run

```sh
cd metal-examples
make
./build/01-triangle
./build/02-cube
./build/03-particles
./build/04-raymarch
```

Quit any demo with **Cmd+Q** or by closing the window. The window title shows
live FPS — on a ProMotion display these run at 120 Hz.

## The examples

### 01 — Hello Triangle
The minimal Metal render pipeline: a command queue, one pipeline state, one
draw call. The three vertices are generated inside the vertex shader (no
vertex buffer at all) and animated with a time uniform. Start here to see the
smallest amount of code that puts the GPU on screen.

### 02 — Spinning Cube
The skeleton of every 3D game renderer: a vertex buffer with positions and
normals, model/view/projection matrices built with Apple's `simd` library, a
depth buffer, back-face culling, and per-pixel directional lighting.

### 03 — One Million GPU Particles
The showpiece for Apple Silicon. A **compute shader** integrates gravity
physics for 1,000,000 particles every frame entirely on the GPU, then a render
pass draws them as additively-blended glowing points. The CPU's only job is
handing the GPU a mouse position. Move your cursor over the window and the
swarm chases it; leave, and the attractor wanders on its own. This works so
well because of unified memory — the GPU reads the particle buffer directly
with no PCIe copies.

### 04 — Raymarched Scene
Zero geometry: a single fullscreen triangle, and the fragment shader
**ray-marches a signed-distance-field world for every pixel** — a bouncing
sphere and orbiting torus over a checkerboard floor, with soft shadows,
ambient occlusion, specular highlights, fog, and an orbiting camera. At Retina
resolution that's millions of ray marches per frame, sustained at full
refresh rate.

### 05 — Ocean
*(Realism pass:* whitecaps form where the wave surface **folds** — the
Gerstner displacement's Jacobian — not just where it's high; the sun path is
a **GGX microfacet glitter** whose roughness grows with distance so near
water sparkles while the path stretches to the horizon; an atmospheric sky
with drifting fbm **clouds** that appear in the reflections; and the whole
scene renders in **HDR with bloom**, tonemapped in a final composite. Wave
intensity is adjustable live: ↑/↓ or presets 1–5, from glassy to storm.)*
How games render water. A grid of ~780,000 vertices (generated from the
vertex index — no vertex buffer) is displaced every frame by a sum of six
**Gerstner waves**, the classic technique from GPU Gems: points move in
circles so crests sharpen and troughs flatten, and long waves travel faster
than short ones just like the real sea. The fragment shader adds everything
that makes water read as water: fresnel reflectivity, sky reflection, a hot
sun glint, subsurface scattering through backlit crests, procedural foam,
and distance fog into the horizon. The sky is a second bufferless fullscreen
pass. No textures or assets — every pixel is math.

### 06 — Tugboat (a game!)
Drive a tugboat across the ocean — seen from a chase camera angled 30° down —
and collect the floating buoys. The water is the same Gerstner-wave surface as
example 05, and the key trick is that the **boat and buoys sample the exact
same wave function on the CPU** — the shader's wave table is generated from one
C++ table at startup, so the game logic and the GPU water can never disagree.
Everything rides the swell: the boat bobs, pitches, and rolls, and the buoys
spin and bounce. Distance haze fades the far water into the sky at the horizon.

Physics feel like a boat, not a car — throttle is persistent, drag brakes you,
and the rudder only bites when water is flowing past it, so you can't spin in
place. The boat and buoys are built from procedural colored boxes (no models).

Three particle systems add life. Dark smoke puffs from the funnel (heavier
when you throttle up) as camera-facing billboards. White spray bursts off the
bow — emitted in proportion to how deep the bow is buried in the wave times
boat speed, so it erupts as the hull slams into crests, then arcs back down
under gravity. The wake is different again: a bow
wave springs from a point at the cutwater and spreads into a V whose vertex
stays pinned where the bow cuts the water, while a bright churned trail
streams from the stern — drawn as flat foam quads laid on the water surface
(not billboards) with a world-space noise-broken alpha, so it reads as
churned water rather than a floating puff. Both are alpha-blended
and triple-buffered so the CPU builds the next frame's geometry while the GPU
draws the current one; the wake is layered beneath the boat and smoke above.

The boat itself is a real 3D model (`assets/Tugboat.usdz`) loaded at startup
with Apple's **Model I/O** framework — `MDLAsset` → `MTKMesh` gives Metal
vertex/index buffers directly, and each submesh's base-color texture is pulled
from the USDZ and sampled by a dedicated textured pipeline. If the file is
missing the game falls back to a procedural box-boat, so it always runs. Drop
a different model in and pass it as an argument to try it:
`./build/06-tugboat path/to/model.usdz`. Scale, orientation, and draft are
auto-fitted from the model's bounding box (with tuning constants at the top of
`main.mm`).

Controls:

| Key | Action | Key | Action |
| --- | --- | --- | --- |
| `W` / `↑` | throttle up | `A` / `←` | rudder left |
| `S` / `↓` | throttle down | `D` / `→` | rudder right |
| `Space` | cut throttle | `R` | reset boat |

Score and current throttle show in the window title. Get within range of a
buoy and it's collected and respawns somewhere new.

### 07 — NET BREACH (cyberpunk tower defense — in progress)
A neon tower-defense game built to the spec in `07-netbreach/DESIGN.md`: you're
a netrunner defending your Core from waves of intrusion ICE crawling a
circuit-board conduit. **Current build (step 2):** TRON-styled palette
(cyan/white defenses vs orange intruders on a near-black grid), HDR + bloom
post chain, and real gameplay — three placeable towers (Sentry tracers, Arc
Coil chain lightning, Cryo slow aura) with linear tier upgrades, the
Spark-Node economy (kills pay; build, upgrade, sell), enemy HP bars, and Core
integrity. Keys 1/2/3 pick a tower; left-click builds or upgrades;
right-click sells. The 10-wave table with Golem/Wisp and the Black ICE boss
land next.

### 08 — WAR SIM (battle simulator)
A TABS-style battle simulator: paint two armies on a grassy battlefield, hit
SPACE, and watch hundreds of little soldiers charge, volley, and hack it out
until one side is annihilated. Four unit types with distinct silhouettes and
behavior — Infantry (sword & shield), Archers (true ballistic arrow arcs),
Cavalry (charge bonus), Berserkers (glass cannons) — every character drawn
procedurally as SDF shapes on alpha-tested billboards (depth-sorted for free,
no art assets). Fixed 60 Hz sim with spatial-hash targeting and separation,
blood puffs, persistent ground splats and corpses, victory hops for the
winners. Pick units from the on-screen HUD (or keys 1–5) — including the
**Catapult**, which lobs flaming balls that explode on impact and level
everything in the blast radius, friendly fire included. Click/drag stamps
squads (left half = RED, right half = BLUE); right-click erases; D deploys
default armies; R clears. Scroll to zoom; arrow keys or Q/E orbit and tilt
the battle-cam. Melee hits knock units back with sparks and dust; catapult
strikes shake the camera and leave scorched craters. Random terrain makes
every field tactical: **hills and valleys** (real displaced geometry — slower
uphill, faster downhill, archers outrange from high ground, shots land on the
true surface), **lakes** (impassable; projectiles splash harmlessly into
them), **forests** (slow troops — cavalry worst of all), and **boulders**
(impassable). Press T during setup to reroll the terrain. Every soldier also
rolls individual **skill** at spawn — HP, damage, attack speed, and archery
accuracy all vary man to man (veterans stand slightly taller), so even
identical squads fight like real, uneven troops.

The simulation-depth pack (v6) adds **morale & routing** — soldiers lose
courage as friends die around them, break below the threshold, and flee the
field with a white flag overhead (fleeing men are cut down from behind, can
rally in safety, and victory goes to whoever still *holds the field*, not
total annihilation) — plus **line-holding formations**, five new units
(**Pikemen** whose braced walls gore charging cavalry, **Ballistae** firing
bolts that skewer a whole file of men, **Healers**, a hulking **Champion**
who cleaves three men a swing, and a mounted **Commander** whose banner aura
emboldens nearby troops — and whose death sends a shock through the whole
army), and a **weapon-vs-armor matrix**: arrows bounce off shields, axes
crush them, pikes and bolts punch through heavy armor.

### 09 — BIOME (life simulator)
Care for a colony of critters whose every trait is read from a real, inherited
**nucleotide genome** — built to the spec in `09-biome/DESIGN.md`. Diploid A/C/G/T
genes on chromosomes, traits translated from the sequence, dominance read from
the sequence, **meiosis with crossing-over + point mutation**, and X/Y sex — so
the colony genuinely evolves across generations. Sixteen genes drive visible,
heritable **morphology**: body size, elongation, belly girth, eye size, a snout,
side-fins, and a two-color banding pattern, so lineages look alike and drift
apart as mutations and recombination accumulate.

A drifting **climate** (gentle seasons over a slow-wandering baseline) turns
that variation into **directional natural selection**: cold favors large, dark
bodies that hold heat, warmth favors small, pale ones (Bergmann's + Gloger's
rules), so mismatched critters burn energy faster, breed less, and die younger —
and the colony's average size and coloration visibly **track the environment
over generations**. An always-on **evolution graph** plots the climate against
the colony-average size, coat darkness, resistance, and population so you can
watch the drift happen; the ground itself tints frosty-blue to sun-baked-tan
with the temperature. Critters have procedural Verlet-spine bodies, utility-AI
needs (hunger / energy / reproduction), forage regrowing food, court and breed,
and catch a contagion whose spread is governed by disease-resistance genes.
Click any critter to inspect its trait bars and its genome (both homologs shown
as colored base ticks). F scatters food, `,`/`.` cool/warm the climate, Space
pauses, `[`/`]` change speed, K culls, I introduces a stranger, R resets.

## Where to go from here

- **Textures & samplers** — `MTLTexture`, `MTKTextureLoader`
- **Instancing** — draw thousands of meshes in one call (`drawPrimitives:instanceCount:`)
- **Precompiled shaders** — move MSL into `.metal` files built into a `.metallib`
- **metal-cpp** — Apple's official header-only C++ bindings if you want to
  drop Objective-C entirely: https://developer.apple.com/metal/cpp/
- **Xcode GPU capture** — profile any of these with Product ▸ Debug ▸ GPU frame capture
