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
Care for a colony of **Bubble Burrowers** (*Bullavermis communis*) — small
amphibious wetland herbivores rendered as **big translucent speckled membrane
bodies** that paddle along on **four splayed veined webbed fins**, with a small
snout bump and two low dark-navy eyes; they **camouflage** toward the ground —
chromatophores easing the coat toward the moss over several seconds when they
hold still and washing back out on the move — and fade into a decaying corpse
when they die.
Every trait is read from a real, inherited **nucleotide genome** — built to the
spec in `09-biome/DESIGN.md`. Diploid A/C/G/T
genes on chromosomes, traits translated from the sequence, dominance read from
the sequence, **meiosis with crossing-over + point mutation**, and X/Y sex — so
the colony genuinely evolves across generations. Sixteen genes drive visible,
heritable **morphology**: body size, elongation, belly girth, eye size, **iris
color**, a snout, side-fins, and a two-color banding pattern, so lineages look
alike and drift apart as mutations and recombination accumulate.

The species is naturally **blue-green** (jade → turquoise), seeded into the
colour genes so a fresh colony reads teal and then **evolves or splices** toward
other hues from there. A **day/night cycle** sweeps the world from a warm dawn
through bright noon to a dusk glow and a blue, vignetted night — and because the
Bubble Burrower is **crepuscular**, the colony is liveliest at dawn and dusk,
dozes through the deep night, and its **pupils widen in low light**. After dark
each animal gives off a **slight bioluminescent glow in its own dominant
colour**. Over the top drifts **weather**: spells of clear, cloudy, and rainy
sky ease in and out, with animated **rain streaks** and a grey overcast wash;
rain keeps their skin moist (they drink less) and calls off play. The **SKY**
panel scrubs the time of day, sets the day length, has **MAKE RAIN**, and
carries independent **on/off toggles for each element** (DAY/NIGHT, CLOUDS,
RAIN) so you can switch any of them off entirely.

A drifting **climate** (gentle seasons over a slow-wandering baseline) turns
that variation into **directional natural selection**: cold favors large, dark
bodies that hold heat, warmth favors small, pale ones (Bergmann's + Gloger's
rules), so mismatched critters burn energy faster, breed less, and die younger —
and the colony's average size and coloration visibly **track the environment
over generations**. An **evolution graph** (top-left, hide it with its X
button) plots the climate against the colony-average size, coat darkness,
resistance, prey and predator populations so you can watch the drift happen. The
world is a **procedural biome** — grass, dirt, sand, and rock painted from
moisture/elevation noise with relief shading, **snow** creeping over high ground
when it turns cold, and the whole palette shifting frosty-blue to sun-baked-tan
with the temperature; **soft contact shadows** ground every critter, nest, and
plant, and **pools of animated water** (ringed by reed grass that parts as
critters wade through) dot the map — critters build up thirst and head to the
nearest shore to drink, dehydrating if they neglect it. **Scroll to zoom**
(toward the cursor) and **drag to pan** around the world, or use the VIEW
buttons; a top-center readout tracks living **organisms, total deaths, and
net growth/decline** since the colony began. Critters have
procedural Verlet-spine bodies, utility-AI needs (hunger / energy / reproduction
/ **flee** / **hunker** / **play** / drink / nest), forage regrowing food, court
and breed, follow elders as a colony, and catch a contagion whose
spread is governed by disease-resistance genes. Click any critter to inspect its
trait bars and its genome (both homologs shown as colored base ticks).

**Predators** hunt the colony in **coordinated packs**, turning it into an
ecosystem: prey/predator numbers rise and fall in out-of-phase **population
cycles** (visible on the graph). Nearby hunters coalesce into a pack that
**focus-fires a single quarry** — picking the most vulnerable target (young,
slow, sick, exhausted, frail, or a **straggler** isolated from the herd) — and
each member takes a **geometric role**: red **chasers** drive from behind, amber
**flankers** swing wide to cut off the sides, and violet **ambushers** slip
ahead to intercept the escape line, so the pack **encircles** its target instead
of all charging the same spot (their dorsal spikes are tinted by role, so you can
read the strategy). The pack shares sightings, so members converge even when they
can't personally see the quarry. Sharp-eyed critters still spot hunters and
sprint away, and — because a coat that **matches the ground is spotted only up
close** — predation selects for **camouflage**; and because packs cut out
stragglers, it also rewards **staying in the group and trailing the elders**.
Predators breed when well-fed and starve when prey are scarce.

**Sexual selection & nests.** Females don't just mate with whoever's nearest —
they **choose the showiest male** in sight (vivid colour + prominent fins +
size, scaled by condition, so it's an honest signal). That spreads ornament
genes… but vivid coats are exactly what predators spot from farthest away, so
**display trades off against survival** — the classic evolutionary tension, and
you can watch it swing as you add or remove hunters. Expectant mothers **build
nests**: woven mounds they return to and improve over time. Pups are born at the
nest with an energy **head start** scaled by its quality, and a nest gives
**cover** — critters near one are harder for predators to spot.

**Bubble Burrower life history.** True to the species spec, they **breed slowly
and invest heavily**: a female bears just **one or two** live young per birth
(twins are the exception, likelier in good condition), bonded **pairs stay
together** across seasons and prefer each other as mates, and both parents enter
a long **parental-care** period afterward before the urge to breed rebuilds — so
the colony grows gradually and every juvenile matters. They're **long-lived**,
most reaching an **elder** stage. Socially they behave like an extended family:
they **stay grouped** (cohesion toward nearby kin) and **trail the elders**, who
amble at the head of the band. When life is easy — fed, watered, healthy, and no
predator in sight — they break into **playful bouts**, darting around a companion
and **blowing streams of bubbles** (they also bubble near water and during
courtship displays). A moderate, not-yet-close threat triggers a **hunker-and-
hide** response — freeze low, tuck in, and let the camouflage deepen — while a
close one still sends them sprinting.

Everything is driven from a **sliding control panel** — click the tab on the
right edge to slide it in or out. It carries all the caretaker tools, worked
entirely with the mouse: play/pause and time-scale, a **climate slider** and
food **abundance** slider, scatter-food, add/cull/reset/**clear**,
**start-population** and **lifespan** sliders, **add/remove predators**, and a
**gene lab**.
Pick a trait, set an expression dial, and hit *Splice Into Colony* to introduce
individuals carrying an engineered **dominant** allele — then watch that
experimental gene sweep through the population or get selected out. (The old
keyboard shortcuts still work as accelerators.)

### 10 — GLIMMER (organism design sandbox)
A focused prototype of the intended `09-biome` organism: a **translucent
glass-membrane swimmer**. Its bulbous, speckled, glossy body glows with internal
sparkle and a top sheen (a crisp-edged but see-through membrane), two big dark
**navy eyes** sit up front, and four little **webbed, veined fins** *paddle* to
push it along — the body lurches forward on each power stroke and glides between,
so its locomotion is genuinely fin-driven. A few of them drift around a dim
underwater arena so the look and motion can be reviewed up close. All procedural
SDF — no art. Space pauses; R sends them somewhere new.

## Where to go from here

- **Textures & samplers** — `MTLTexture`, `MTKTextureLoader`
- **Instancing** — draw thousands of meshes in one call (`drawPrimitives:instanceCount:`)
- **Precompiled shaders** — move MSL into `.metal` files built into a `.metallib`
- **metal-cpp** — Apple's official header-only C++ bindings if you want to
  drop Objective-C entirely: https://developer.apple.com/metal/cpp/
- **Xcode GPU capture** — profile any of these with Product ▸ Debug ▸ GPU frame capture
