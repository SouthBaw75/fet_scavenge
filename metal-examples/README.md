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

Two billboard particle systems add life: dark smoke puffs from the funnel
(heavier when you throttle up) and white foam churns off the stern into a
wake that spreads and rides the wave surface. They're alpha-blended
camera-facing quads, triple-buffered so the CPU builds the next frame's
geometry while the GPU draws the current one — the wake is layered beneath
the boat and the smoke above it.

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

## Where to go from here

- **Textures & samplers** — `MTLTexture`, `MTKTextureLoader`
- **Instancing** — draw thousands of meshes in one call (`drawPrimitives:instanceCount:`)
- **Precompiled shaders** — move MSL into `.metal` files built into a `.metallib`
- **metal-cpp** — Apple's official header-only C++ bindings if you want to
  drop Objective-C entirely: https://developer.apple.com/metal/cpp/
- **Xcode GPU capture** — profile any of these with Product ▸ Debug ▸ GPU frame capture
