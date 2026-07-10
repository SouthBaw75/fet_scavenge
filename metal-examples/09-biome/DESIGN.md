# BIOME — Design Document

An advanced life simulator. You are the **caretaker** of a colony of small
creatures ("critters") living in a contained ecosystem. You don't control them
directly — you shape their world (food, climate, disease, who breeds) and watch
a living population grow, adapt, and **evolve across generations**. Every
critter is a unique individual defined by a real inherited genome.

Built on the same C++/Metal foundation as the other examples, at
`metal-examples/09-biome/`.

> **Tags:** `[V1]` = in the first vertical slice. `[V2]`/`[LATER]` = layered on
> once the core is proven. Numbers are first-pass values for tuning.

## Locked decisions
1. **DNA depth:** full **nucleotide-level** genome — genes are real A/C/G/T
   sequences translated to traits; mutations are physical base changes.
2. **Player role:** a light **god-game** — place food, breed pairs, warm/cool,
   quarantine/cure, cull, trigger events.
3. **Reproduction:** **sexual only** — two parents, meiosis with crossing over.
4. **View:** **2D top-down** with procedural creature bodies.
5. **Slice:** genetics + life + movement + reproduction + inspector first;
   sickness/seasons/disasters layered after (a basic contagion is in v1).

---

## 1. The genetics engine (centerpiece)

- **Diploid genome.** Each critter carries chromosome *pairs* — two homologs,
  one from each parent. Genes sit at fixed **loci**.
- **Real DNA.** Each gene is a sequence of bases packed 2 bits each (A/C/G/T).
  Trait contribution is *translated* from the sequence (GC content), and each
  allele carries a **dominance** value read from the sequence too.
- **Dominance from one formula:** a locus phenotype is
  `(e_a·d_a + e_b·d_b) / (d_a + d_b)` where `e` = expression, `d` = dominance.
  A strongly dominant allele overrides (Mendelian dominant/recessive); equal
  dominance blends (incomplete/codominant). Recessives hide but still inherit.
- **Meiosis with crossing over.** Genes lie on **chromosomes**; a gamete is
  built per chromosome by copying one homolog up to a random crossover point
  then the other — giving **linkage** (nearby genes travel together) and
  **recombination**. Offspring = one gamete from each parent.
- **Mutation** `[V1]`: at gamete formation, a small per-gene chance to flip a
  random base — most neutral, some harmful, rare beneficial.
- **Sex:** an X/Y pair. Mothers XX, fathers XY; father passes X or Y → ~50/50.
- **Polygenic + pleiotropy:** size averages several loci; big critters are
  slower and hungrier (one trait dragging others — a real evolutionary
  constraint). Population genetics (drift, sweeps, bottlenecks, inbreeding
  depression) all **emerge** from the rules.

**v1 trait loci:** size, speed, metabolism, three color genes (RGB → families
look alike), sensory range, fertility, disease resistance. Lifespan derived
from metabolism.

## 2. Lifelike movement `[V1]`
Procedural bodies: a **Verlet spine** the body follows so critters bend and
slither with momentum; a travelling sine wiggle scaled by speed; steering
behaviors (seek/flee/wander/arrive) drive intent; squash/stretch and a head
that turns toward its target. (IK legs are a `[V2]` upgrade.)

## 3. Behavior — utility AI `[V1]`
Each critter scores its drives — hunger, energy/rest, reproduction urge — each
tick and does the highest, weighted by its genes; produces organic foraging,
resting, and courting with no scripting.

## 4. Environment `[V1]`
A world of growing/regrowing food plants (real carrying capacity), open ground,
finite space. Overpopulation → starvation → crash → recovery. `[V2]` seasons,
day/night, temperature, water, terrain, predators, disasters.

## 5. Sickness `[V1 basic]`
A contagion spreads by proximity, saps energy/health, and can kill.
**Disease-resistance genes** govern recovery, so epidemics leave a more
resistant population — evolution you can watch. `[V2]` multiple pathogens,
incubation, mutation, quarantine tools.

## 6. Social & reproduction `[V1]`
Adults of opposite sex with high urge + energy mate on contact; the female
conceives (offspring genome fixed at conception via meiosis), gestates, then
gives birth. `[V2]` mate choice / sexual selection, kin clustering, dominance
hierarchies, alarm-spreading.

## 7. Caretaker tools `[V1]`
Click to **select/inspect**; drop **food**; **pause** and **time-scale**;
**cull** the selected. `[V2]` pair-breeding, warm/cool, quarantine/cure,
mutagen, disasters, goal/challenge modes.

## 8. Inspector (crucial) `[V1]`
Click a critter for a panel: name, sex, age, generation, parents, live drives,
its **trait bars**, and a **genome strip** showing both homologs' bases as
colored ticks with expressed/carrier status. `[V2]` family tree, colony graphs
(population, allele frequencies, trait drift over generations).

## 9. Tech
CPU fixed-timestep sim (deterministic); rendering reuses the instanced-glow +
SDF-shape + digit-font toolkit. Ground is a procedural shader; critters, food,
and HUD are instanced quads.

## 10. Roadmap
- **v1 (now):** genome engine, procedural movement, utility needs, food +
  carrying capacity, sexual reproduction (meiosis/mutation), birth/death,
  basic contagion, click-inspect genome/trait panel, time controls.
- **v2:** seasons/day-night/temperature/water, mate choice + social depth,
  predators & disasters, pair-breeding + climate tools, colony graphs, IK legs.
- **v3:** multiple species/food webs, terrain, challenge/goal modes, save/load.
