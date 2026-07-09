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

## Where to go from here

- **Textures & samplers** — `MTLTexture`, `MTKTextureLoader`
- **Instancing** — draw thousands of meshes in one call (`drawPrimitives:instanceCount:`)
- **Precompiled shaders** — move MSL into `.metal` files built into a `.metallib`
- **metal-cpp** — Apple's official header-only C++ bindings if you want to
  drop Objective-C entirely: https://developer.apple.com/metal/cpp/
- **Xcode GPU capture** — profile any of these with Product ▸ Debug ▸ GPU frame capture
