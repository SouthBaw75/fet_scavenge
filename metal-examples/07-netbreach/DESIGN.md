# NET BREACH — Design Document

A cyberpunk tower-defense game. You are a **netrunner** defending your **Core**
(the mainframe) from waves of hostile **ICE** — intrusion programs crawling the
data-conduits of a circuit-board grid. Install defensive towers, loot the
programs you destroy for **Spark-Nodes**, and keep the Core alive.

Rendered entirely in procedural neon on our Metal engine — no art assets.

> **Tags:** `[V1]` = in the first vertical slice. `[V2]` / `[LATER]` = planned
> expansions built on top of the proven core. Numbers are first-pass values for
> tuning, not final balance.

---

## 1. Core loop

```
BUILD PHASE  ->  place / upgrade / sell ICE towers (spend Spark-Nodes)
     |
   WAVE       ->  programs stream along the conduit toward the Core
     |
  COMBAT      ->  towers auto-fire; kills drop Spark-Nodes; leaks drain Core Integrity
     |
 WAVE CLEAR   ->  clear bonus + no-leak streak bonus
     |
   repeat, escalating; a Black ICE boss every 5th wave
```

Win a sector by surviving all its waves. Lose if **Core Integrity** hits 0.

---

## 2. Currency & resources

- **Spark-Nodes (⚡)** `[V1]` — the one in-mission currency. Dropped by every kill
  and awarded at wave-clear. Spent on **building towers** and **upgrading** them.
  Selling a tower refunds ~75% of what you sank into it.
- **Core Integrity** `[V1]` — your lives. Each program that reaches the Core drains
  Integrity by its **breach value**. Start a sector with **20**.
- **Power** `[V2]` — a bar that charges from kills; spent on active **Hacks**
  (screen abilities). Deferred out of v1 to keep the slice lean.
- **Data Cores** `[LATER]` — rare meta-currency from bosses/sector-clears, spent
  in a between-mission tech tree (new towers, global buffs). Post-campaign meta.

### Economy (first-pass v1 numbers)
- Starting Spark-Nodes: **120**
- Kill rewards: Bit **2**, Daemon **3**, Wisp **5**, Golem **8**, Boss **60**
- Wave-clear bonus: **10 + waveNumber**
- No-leak streak: **+5** per consecutive wave cleared with zero leaks (resets on leak)

---

## 3. The counter system (backbone)

Tower choice matters because **damage types** trade against **enemy defenses**.
You cannot win with one tower type.

| Damage type | Strong vs | Weak vs |
|---|---|---|
| **Kinetic** (bullets/rail) | unshielded, bosses | Armor |
| **Energy** (arc/laser/plasma) | Armor | Shields |
| **Ion/EMP** `[V2]` | Shields, tech | organic, fast |
| **Explosive** (splash) `[V2]` | swarms/clusters | single tanks, flyers |

Enemy defenses: **Armor** (cuts kinetic ~50%), **Shield** `[V2]` (absorbs a pool,
stripped by ion/energy), **Evasion** (dodges a % of shots; countered by slowing),
**Cloak** `[LATER]` (needs detection), **Flying** `[V2]` (needs anti-air).

**The v1 triangle** (taught by the 3 launch towers vs 4 enemies):
- **Swarms** overwhelm single-target fire → **Arc Coil** chain lightning.
- **Fast** enemies slip past slow fire → **Cryo Node** slow lets towers connect.
- **Armored** tanks shrug off bullets → **Arc Coil** energy ignores armor; **Sentry** struggles.

---

## 4. Towers

3 launch towers `[V1]`, each with **3 linear upgrade tiers**. The branching A/B
specializations `[V2]` are listed for direction but NOT built in v1.

### 4.1 Sentry — pulse turret `[V1]`
Cheap, reliable single-target DPS. Cyan tracer rounds.
- **Damage type:** Kinetic
- Build **40⚡**

| Tier | Cost | Damage | Fire rate | Range | Notes |
|---|---|---|---|---|---|
| 1 | (build) | 6 | 2.0/s | 3.0 | — |
| 2 | 30 | 10 | 2.5/s | 3.0 | — |
| 3 | 60 | 16 | 3.0/s | 3.5 | — |

- **Branch A `[V2]` — Gatling:** fire rate ramps while firing the same target.
- **Branch B `[V2]` — Hollowpoint:** armor pierce + crit chance.

### 4.2 Arc Coil — tesla chain `[V1]`
Chain lightning; anti-swarm and anti-armor. Electric purple.
- **Damage type:** Energy (ignores Armor)
- Build **70⚡**

| Tier | Cost | Damage | Chains | Fire rate | Range | Notes |
|---|---|---|---|---|---|---|
| 1 | (build) | 5 | 2 | 1.0/s | 2.5 | arcs to nearest |
| 2 | 55 | 8 | 3 | 1.2/s | 2.5 | — |
| 3 | 90 | 12 | 4 | 1.4/s | 3.0 | — |

- **Branch A `[V2]` — Overload:** more chains, chains can re-hit.
- **Branch B `[V2]` — Ionizer:** strips shields, bonus vs tech.

### 4.3 Cryo Node — slow field `[V1]`
Support. Slows everything in radius; little/no damage. Ice blue.
- **Damage type:** — (utility)
- Build **50⚡**

| Tier | Cost | Slow | Radius | Notes |
|---|---|---|---|---|
| 1 | (build) | 30% | 2.0 | aura, always on |
| 2 | 40 | 45% | 2.5 | — |
| 3 | 70 | 60% | 3.0 | small chance to briefly freeze |

- **Branch A `[V2]` — Deep Freeze:** can freeze solid for short lockdowns.
- **Branch B `[V2]` — Shatter:** frozen/slowed enemies take bonus damage from all sources.

### Later towers `[V2+]`
Railgun (long-range pierce), Plasma Mortar (AoE splash), Flak Battery (anti-air),
Prism Laser (ramping beam), EMP Pylon (ion/stun). These unlock across sectors and
bring the Explosive/Ion damage types and the Flying/Shield defenses online.

---

## 5. Enemies

v1 roster: 4 regular programs + 1 boss `[V1]`.

| Enemy | HP | Speed | Defense | Reward | Breach | Teaches |
|---|---|---|---|---|---|---|
| **Bit** | 12 | 1.0 | none | 2 | 1 | basics; swarm → Arc Coil |
| **Daemon** | 8 | 2.2 | none | 3 | 1 | fast → Cryo to connect hits |
| **Wisp** | 20 | 1.4 | Evasion 35% | 5 | 1 | evasive → slow it, focus fire |
| **Golem** | 90 | 0.6 | Armor (kinetic −50%) | 8 | 3 | armor → Energy beats Kinetic |
| **BOSS: Black ICE** | 1200 | 0.5 | Armor + phases | 60 | 10 | tests the whole board |

- **Wisp evasion** `[V1]`: dodges a fraction of incoming shots; **Cryo slow reduces
  its dodge**, so slow-then-shoot is the answer. (True Flying + anti-air arrives
  with Flak in `[V2]`.)
- **Black ICE boss** `[V1]`: huge HP, slow, periodically **EMP-stuns nearby towers**
  for ~2s and spawns a trickle of Bits. `[V2]` adds distinct phases.
- `[V2+]` enemies: **Warden** (shield), **Splitter** (spawns 2 on death), **Phantom**
  (cloaks), **Medibot** (heals allies), **flying** variants.

---

## 6. Sector 1 — "Slums Grid" (v1 map & waves)

- **Layout `[V1]`:** single fixed conduit path across a circuit-board grid, from a
  breach point to the Core. Buildable tiles flank the path. No rerouting yet.
- **Waves `[V1]`:** 10 waves; boss on wave 10. Build phase between waves (a "Deploy"
  button starts the next wave early for a small Spark-Node bonus).

| Wave | Composition | Lesson |
|---|---|---|
| 1 | 8× Bit | place your first Sentry |
| 2 | 14× Bit (tight) | swarm → build an Arc Coil |
| 3 | 6× Bit, 6× Daemon | Daemons are fast → Cryo |
| 4 | 16× Daemon (rush) | slow field carries the wave |
| 5 | 3× Golem | armor wall → Arc Coil energy |
| 6 | 10× Bit, 6× Daemon, 1× Golem | mixed pressure |
| 7 | 8× Wisp | evasive → slow + focus |
| 8 | 4× Golem, 6× Wisp | tank + evasive together |
| 9 | 12× Bit, 8× Daemon, 3× Golem, 4× Wisp | everything |
| 10 | **Black ICE** boss + Bit trickle | final exam |

`[LATER]` Sectors 2–4 (Corpo Datacenter, Black ICE Vault, Core Nexus) add branching
paths, **rerouting junctions** (spend Power to lengthen the enemy path), new enemies,
new tower unlocks, and a mega-boss.

---

## 7. Active abilities — "Hacks" `[V2]`

Player-triggered, charged by the Power bar. Not in v1.
- **Overclock** — all towers +50% fire rate, 8s
- **EMP Burst** — stun every enemy on screen
- **Firewall** — temporary barrier that blocks/reroutes a conduit segment
- **Orbital Strike** — nuke a target area
- **Core Restore** — heal Integrity

---

## 8. Visual direction (the "epic" part)

- **Board:** dark violet-black circuit grid; glowing traces; the enemy conduit is a
  bright animated data-stream (current flowing toward the Core).
- **Everything procedural neon** — towers are glowing geometric constructs, enemies
  are neon/wireframe shapes, projectiles are bright tracers with trails, deaths are
  particle bursts (reuse our particle system).
- **Color = information:** each damage type and enemy reads by color even in chaos.
  Palette: cyan, magenta, electric yellow, hot pink, acid green on deep purple.
- **Bloom post-process** for the signature glow; subtle scanlines + chromatic
  aberration + a grid pulse.
- **Juice:** screen shake on heavy hits, hit-flashes, floating neon damage glyphs,
  range rings that pulse on hover, slow-mo + white flash on boss death.

---

## 9. Technical plan (mapping to our Metal engine)

We already have the pieces: additive-glow particles, instanced draws, procedural
shader geometry, a fixed-ish timestep. New work is a bloom pass + a grid shader +
the game simulation.

- **Sim / render split:** a fixed-timestep simulation (structs-of-arrays for
  enemies, towers, projectiles) separate from rendering, so gameplay is
  deterministic and frame-rate independent.
- **Path & grid:** the conduit is a polyline of waypoints; enemies advance along it
  by arc-length. Grid tiles flag buildable vs path vs Core. Placement snaps to tiles.
- **Targeting:** towers pick a target within range by policy (first / closest /
  strongest); Arc Coil floods to nearest N; Cryo is an always-on aura.
- **Combat:** projectiles as short-lived entities (or hitscan for beams); damage
  applies the type-vs-defense table. Deaths spawn particle bursts + Spark-Node pickups.
- **Rendering:** instanced neon quads / SDF shapes with an additive glow shader;
  one **bloom** post-process for the whole scene; a circuit-grid background shader
  (kin to our water/grid shaders). HUD in a simple immediate-mode overlay.
- **Data-driven waves:** waves, tower stats, and enemy stats live in tables (like the
  tugboat's tuning constants) so balancing is edits, not rewrites.

---

## 10. Build roadmap

- **v1 — Vertical slice (next):** Sector 1, fixed path, 10 waves + boss; **Sentry /
  Arc Coil / Cryo Node** with linear tiers; **Bit / Daemon / Wisp / Golem** + Black
  ICE; Spark-Node economy, build/upgrade/sell, Core Integrity, win/lose; full neon
  look + bloom + particle deaths. Proves the whole loop, end to end.
- **v2 — Depth:** branching A/B tower specializations; Power bar + Hacks; Explosive
  & Ion damage (Plasma/Flak/EMP towers); Flying + Shield enemies (Wisp goes truly
  airborne, Warden, Splitter).
- **v3 — Campaign:** Sectors 2–4 with branching paths and **rerouting junctions**,
  Phantom/Medibot, mega-boss, Data-Core meta tech tree, endless mode + score.
