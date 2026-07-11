// 09 — BIOME (life simulator, vertical slice)
//
// Care for a colony of critters whose every trait is read from a real,
// inherited nucleotide genome. Watch them forage, rest, court, breed, sicken,
// and — across generations — EVOLVE.
//
//   * Diploid genome of A/C/G/T genes on chromosomes; traits translated from
//     the sequence; dominance read from the sequence; meiosis with crossing
//     over + point mutation; X/Y sex. See DESIGN.md.
//   * Procedural Verlet-spine bodies with a speed-scaled slither.
//   * Utility-AI needs: hunger / energy / reproduction urge.
//   * Food plants grow and regrow (carrying capacity); starvation, old age,
//     and a contagious sickness thin the herd; disease-resistance genes let
//     epidemics select the population.
//   * Click a critter to inspect its traits and genome.
//
// Controls:
//   Click        select / inspect a critter
//   F            scatter food   ·   Space pause   ·   [ ] slower/faster
//   K            cull selected  ·   I introduce a random critter  ·  R reset
//
// CPU fixed-timestep sim; instanced-quad rendering (SDF shapes + digit font).

#include "../common/app.h"
#import <AVFoundation/AVFoundation.h>
#include <simd/simd.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <random>
#include <string>
#include <vector>

// ---------------------------------------------------------------- Tuning ---

static const float kWorldW = 120.0f;
static const float kWorldH = 72.0f;
static const int kMaxCritters = 800;   // living + still-decaying corpses (vector cap)
static const int kLiveCap     = 420;   // hard cap on LIVING critters — births stop here
                                       // (keeps the O(n^2) scans / the machine responsive)
static const float kDecaySecs = 22.0f; // how long a corpse takes to fade away
static const int kMaxFood = 600;
static const int kMaxPredators = 90;
static const int kMaxNests = 200;
static const float kNestRadius = 3.2f;   // shelter + build range
static const int kMaxWater = 12;
static const int kMaxRipples = 700;
static const int kMaxBubbles = 900;
static const int kMaxDecor = 9000;
static const int kMaxInstances = 32768;
static const int kMaxInFlight = 3;
static const int kSpineNodes = 6;

// Environmental selection. The climate drifts (gentle seasons + a slow
// random-walk trend) and imposes a survival cost on critters whose body size
// and coat darkness are ill-suited to it — cold favors large, dark bodies that
// retain heat (Bergmann's + Gloger's rules), heat favors small, pale ones. So
// the population's genome tracks the environment over generations: real,
// visible directional selection on top of drift and mutation.
static const float kSeasonSecs   = 120.0f;  // one seasonal cycle (sim seconds)
static const float kThermalCost  = 0.055f;  // energy/sec drain at full mismatch
// Bubble Burrower life history: a slow-breeding, long-lived, deeply social
// species. Pairs bond, invest heavily in one or two young, follow experienced
// elders, and play when times are good.
static const float kPackRange    = 16.0f;   // hunters within this range hunt as one pack
static const float kFeedSecs     = 1.3f;    // bite-and-shake duration before the prey is consumed
static const float kElderFrac    = 0.68f;   // age fraction at which a critter is an "elder"
static const float kCareSecs     = 16.0f;   // post-birth parental-care cooldown before urge rebuilds
static const float kCamoRate     = 0.11f;   // camouflage ease speed (~1/9s to full → the spec's 5-15s)
static const float kColonyRange  = 14.0f;   // how far a critter senses colony-mates for cohesion
static const float kElderRange   = 22.0f;   // how far followers look for an elder to trail
static const int   kHistLen      = 120;     // trait-history samples (~sim minutes)
static const float kSampleSecs   = 1.0f;    // one history sample per sim second

// Genome layout: kNumGenes autosomal loci spread across kChromosomes. Related
// genes share a chromosome so they tend to inherit together (linkage).
static const int kNumGenes = 24;
static const int kChromosomes = 4;
static const int kGenesPerChrom = kNumGenes / kChromosomes;   // 6
static const float kMutationRate = 0.04f;   // chance per gene per gamete

// Gene indices -> traits. Genes on a chromosome inherit together (linkage).
// The last four are heritable BEHAVIOURAL loci — they give each lineage its own
// temperament (bold/timid, social/loner, curious/cautious, active/lazy).
enum { GSize0 = 0, GSize1 = 1, GSpeed = 2, GMetab = 3,
       GColR  = 4, GColG  = 5, GColB  = 6, GResist = 7,
       GAspect = 8, GGirth = 9, GEye = 10, GSnout = 11,
       GSpikes = 12, GPattern = 13, GPatHue = 14, GFert = 15,
       GEyeR = 16, GEyeG = 17, GEyeB = 18, GEyeShine = 19,
       GBold = 20, GSocial = 21, GCurious = 22, GActivity = 23 };

// --------------------------------------------------------------- Genetics ---
// A gene is 16 bases packed 2 bits each in a uint32 (A=0,C=1,G=2,T=3).

static inline int baseAt(uint32_t g, int i) { return (g >> (2 * i)) & 3; }

// Expression: GC content (0..1). C=1, G=2 are the "strong" bases.
static float geneExpression(uint32_t g) {
    int gc = 0;
    for (int i = 0; i < 16; i++) { int b = baseAt(g, i); if (b == 1 || b == 2) gc++; }
    return gc / 16.0f;
}
// Dominance: read from the high half of the strand (a different region than
// expression leans on), so dominance and value vary independently.
static float geneDominance(uint32_t g) {
    int d = 0;
    for (int i = 8; i < 16; i++) { int b = baseAt(g, i); if (b >= 2) d++; }
    return 0.15f + 0.85f * (d / 8.0f);
}
// A locus phenotype from its two alleles: dominance-weighted blend. One
// formula yields dominant/recessive AND incomplete/codominant behavior.
static float locusValue(uint32_t a, uint32_t b) {
    float ea = geneExpression(a), da = geneDominance(a);
    float eb = geneExpression(b), db = geneDominance(b);
    return (ea * da + eb * db) / (da + db + 1e-4f);
}

struct Genome {
    uint32_t hom[2][kNumGenes];   // two homologs
    int sexAllele[2];             // 0 = X, 1 = Y  (XX female, XY male)
};

static uint32_t randomGene(std::mt19937 &rng) {
    // 32 random bits = 16 random bases.
    return ((uint32_t)rng() ) ^ ((uint32_t)rng() << 1);
}

// Build a gene whose expression (GC content) lands near a target value, with
// randomized base positions/identities so it still carries genetic variation.
static uint32_t tintGene(float v, std::mt19937 &rng) {
    std::uniform_real_distribution<float> u(0, 1);
    int k = (int)lroundf(std::clamp(v, 0.0f, 1.0f) * 16.0f);
    int idx[16]; for (int i = 0; i < 16; i++) idx[i] = i;
    for (int i = 15; i > 0; i--) { int j = (int)(u(rng)*(i+1)); std::swap(idx[i], idx[j]); }
    uint32_t g = 0;
    for (int i = 0; i < 16; i++) {
        int b = (i < k) ? (u(rng) < 0.5f ? 1 : 2)    // C or G  → GC (expressed)
                        : (u(rng) < 0.5f ? 0 : 3);   // A or T  → AT
        g |= ((uint32_t)b) << (2 * idx[i]);
    }
    return g;
}

static Genome randomGenome(std::mt19937 &rng, int forcedSex /* -1 any */) {
    Genome g;
    for (int h = 0; h < 2; h++)
        for (int i = 0; i < kNumGenes; i++) g.hom[h][i] = randomGene(rng);
    std::uniform_real_distribution<float> u(0, 1);
    // Base coat: the species is naturally blue-green (jade → turquoise). Seed the
    // colour genes low-red / mid-green / high-blue, with jitter so the founding
    // colony varies around teal — and can still evolve toward other hues, or be
    // spliced red/green, from there.
    auto jit = [&](float c){ return std::clamp(c + (u(rng)-0.5f)*0.30f, 0.0f, 1.0f); };
    for (int h = 0; h < 2; h++) {
        g.hom[h][GColR] = tintGene(jit(0.20f), rng);
        g.hom[h][GColG] = tintGene(jit(0.52f), rng);
        g.hom[h][GColB] = tintGene(jit(0.82f), rng);
    }
    // Temperament: give each founder a definite personality spanning the full
    // range (both homologs near the same target so it actually shows), so the
    // starting colony is a mix of bold/timid, social/loner, curious/cautious,
    // busy/lazy individuals — which then evolves.
    float tb = u(rng), ts = u(rng), tc = u(rng), ta = u(rng);
    for (int h = 0; h < 2; h++) {
        g.hom[h][GBold]     = tintGene(jit(tb), rng);
        g.hom[h][GSocial]   = tintGene(jit(ts), rng);
        g.hom[h][GCurious]  = tintGene(jit(tc), rng);
        g.hom[h][GActivity] = tintGene(jit(ta), rng);
    }
    int sex = (forcedSex >= 0) ? forcedSex : (u(rng) < 0.5f ? 0 : 1);
    g.sexAllele[0] = 0;                    // one X always
    g.sexAllele[1] = (sex == 0) ? 0 : 1;   // female XX, male XY
    return g;
}

static bool isMale(const Genome &g) { return g.sexAllele[0] == 1 || g.sexAllele[1] == 1; }

// Build one gamete (a single strand of kNumGenes) via meiosis: per chromosome,
// copy one homolog up to a random crossover, the other after; then mutate.
static void makeGamete(const Genome &g, std::mt19937 &rng, uint32_t out[kNumGenes]) {
    std::uniform_int_distribution<int> coin(0, 1);
    for (int c = 0; c < kChromosomes; c++) {
        int base = c * kGenesPerChrom;
        int strand = coin(rng);
        std::uniform_int_distribution<int> cut(0, kGenesPerChrom);
        int cross = cut(rng);
        for (int i = 0; i < kGenesPerChrom; i++) {
            int src = (i < cross) ? strand : (1 - strand);
            out[base + i] = g.hom[src][base + i];
        }
    }
    // Point mutations: flip one random base of a gene.
    std::uniform_real_distribution<float> u(0, 1);
    std::uniform_int_distribution<int> pos(0, 15);
    std::uniform_int_distribution<int> nb(0, 3);
    for (int i = 0; i < kNumGenes; i++) {
        if (u(rng) < kMutationRate) {
            int p = pos(rng);
            uint32_t mask = ~(3u << (2 * p));
            out[i] = (out[i] & mask) | ((uint32_t)nb(rng) << (2 * p));
        }
    }
}

// Fertilization: gamete from mother + gamete from father; father's sex strand
// decides the child's sex.
static Genome breed(const Genome &mom, const Genome &dad, std::mt19937 &rng) {
    Genome kid;
    makeGamete(mom, rng, kid.hom[0]);
    makeGamete(dad, rng, kid.hom[1]);
    std::uniform_int_distribution<int> coin(0, 1);
    kid.sexAllele[0] = 0;                                  // X from mother
    kid.sexAllele[1] = coin(rng) ? dad.sexAllele[1] : dad.sexAllele[0]; // X or Y from father
    // Guard: mother contributes only X (already 0); ensure male marker only
    // comes from the father strand above.
    return kid;
}

// Phenotype: the visible, playable traits translated from the genome. Many
// are small physical shifts that compound over generations so lineages
// visibly diverge in body plan and markings.
struct Phenotype {
    float size;        // body scale
    float speed;       // move speed
    float metabolism;  // energy burn + hunger rate
    float sensory;     // perception radius (tied to eye size)
    float fertility;   // urge growth / litter viability
    float resistance;  // disease resistance
    float lifespan;    // seconds
    // --- visible morphology ---
    float aspect;      // 0..1 body elongation (long+slender vs short+round)
    float girth;       // 0..1 belly fullness
    float eyeSize;     // eye radius fraction
    float snout;       // 0..1 head projection
    float spikes;      // 0..1 side-fin prominence
    float pattern;     // 0..1 banding strength
    simd_float3 color;  // primary coat color
    simd_float3 color2; // secondary (banding) color
    simd_float3 eyeColor; // heritable iris color
    float eyeShine;    // 0..1 iris brightness
    // --- heritable temperament (drives individual behaviour) ---
    float boldness;    // 0 timid (flees early, stays home) .. 1 bold (holds, roams)
    float sociability; // 0 loner .. 1 clings to the colony / elders
    float curiosity;   // 0 cautious .. 1 explores far, plays, investigates
    float activity;    // 0 languid (rests often) .. 1 restless / busy
};

// Hermite smoothstep on the CPU side (mirrors the shader's smoothstep).
static inline float smoothstepf(float a, float b, float x) {
    float t = std::clamp((x - a) / (b - a), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

// Perceived brightness of a coat color (Rec. 601 luma); 1-this is "darkness".
static inline float coatLuma(simd_float3 c) {
    return 0.299f * c.x + 0.587f * c.y + 0.114f * c.z;
}
// Colour vividness (saturation): how far the coat is from a drab gray. Vivid
// coats are attractive to mates but also easier for predators to spot.
static inline float coatVividness(simd_float3 c) {
    float mx = std::max(std::max(c.x, c.y), c.z);
    float mn = std::min(std::min(c.x, c.y), c.z);
    return std::clamp((mx - mn) * 1.6f, 0.0f, 1.0f);
}

// How well a phenotype suits the current climate, 0 (lethal mismatch) .. 1
// (ideal). want=1 in the cold (favor big + dark), want=0 in the heat.
static inline float adaptation(const Phenotype &p, float climate) {
    float want     = 0.5f - 0.5f * climate;                       // cold->1 hot->0
    float sizeNorm = std::clamp((p.size - 0.6f) / 1.1f, 0.0f, 1.0f);
    float dark     = 1.0f - coatLuma(p.color);
    float miss     = 0.6f * fabsf(sizeNorm - want) + 0.4f * fabsf(dark - want);
    return std::clamp(1.0f - miss, 0.0f, 1.0f);
}

static Phenotype phenotypeOf(const Genome &g) {
    auto L = [&](int i) { return locusValue(g.hom[0][i], g.hom[1][i]); };
    Phenotype p;
    float sz = (L(GSize0) + L(GSize1)) * 0.5f;
    p.size = 0.6f + 1.1f * sz;
    p.eyeSize = 0.09f + 0.15f * L(GEye);
    // Pleiotropy: bigger critters are slower and burn more energy; sharper
    // eyes see farther.
    p.speed = (6.0f + 10.0f * L(GSpeed)) * (1.25f - 0.5f * sz);
    p.metabolism = (0.5f + 1.2f * L(GMetab)) * (0.7f + 0.6f * sz);
    p.sensory = 10.0f + 62.0f * p.eyeSize;
    p.fertility = 0.4f + 0.9f * L(GFert);
    p.resistance = L(GResist);
    // Long-lived (the spec's 10–15 "years"): a high floor so most reach the
    // elder stage, with metabolism and size shading the exact span.
    p.lifespan = 72.0f + 78.0f * (1.0f - L(GMetab)) + 24.0f * (1.0f - sz);
    // Coat color from three heritable loci (R/G/B), saturation-boosted around
    // their mean so a "red" reads as vivid red and a "blue" as vivid blue — and
    // a red x blue cross (high R + high B) comes out clearly purple. New hues
    // keep emerging as the color genes recombine and mutate.
    float cr0 = L(GColR), cg0 = L(GColG), cb0 = L(GColB);
    float cmean = (cr0 + cg0 + cb0) / 3.0f;
    auto csat = [&](float v){ return std::clamp(cmean + (v - cmean) * 2.1f, 0.0f, 1.0f); };
    p.color = simd_make_float3(0.08f + 0.90f * csat(cr0),
                               0.08f + 0.90f * csat(cg0),
                               0.08f + 0.90f * csat(cb0));
    p.aspect = L(GAspect);
    p.girth = L(GGirth);
    p.snout = L(GSnout);
    p.spikes = L(GSpikes);
    p.pattern = L(GPattern);
    // Secondary color: a shift toward the complement, scaled by the hue gene,
    // so markings read distinct from the coat.
    float hue = L(GPatHue);
    simd_float3 comp = simd_make_float3(1.0f, 1.0f, 1.0f) - p.color;
    p.color2 = (p.color + (comp - p.color) * (0.35f + 0.55f * hue)) * 0.92f;
    // Heritable iris color (its own loci, so it recombines independently). The
    // channels are saturation-boosted around their mean so eyes read as vivid,
    // varied colors (blue, green, amber, red) rather than muddy grays.
    float er0 = L(GEyeR), eg0 = L(GEyeG), eb0 = L(GEyeB);
    float emean = (er0 + eg0 + eb0) / 3.0f;
    auto sat = [&](float v){ return std::clamp(emean + (v - emean) * 2.6f, 0.0f, 1.0f); };
    p.eyeColor = simd_make_float3(0.10f + 0.85f * sat(er0),
                                  0.10f + 0.85f * sat(eg0),
                                  0.10f + 0.85f * sat(eb0));
    p.eyeShine = L(GEyeShine);
    // Temperament — read straight from the behavioural loci, so it's heritable and
    // varies from critter to critter (and drifts across lineages over generations).
    p.boldness    = L(GBold);
    p.sociability = L(GSocial);
    p.curiosity   = L(GCurious);
    p.activity    = L(GActivity);
    return p;
}

// ------------------------------------------------------------------ World ---

enum { AWander = 0, AForage = 1, ARest = 2, AMate = 3, AFlee = 4, ANest = 5, ADrink = 6,
       APlay = 7, AHunker = 8 };

struct Critter {
    uint32_t id;
    Genome genome;
    Phenotype ph;
    bool male;
    simd_float2 pos, vel;
    float heading;
    simd_float2 spine[kSpineNodes];
    float age, maturity;
    float energy;      // 0..1
    float hunger;      // 0..1 (1 = starving)
    float thirst;      // 0..1.5 (1 = parched)
    float urge;        // 0..1 reproduction
    float health;      // 0..1
    float sick;        // 0..1 infection load, 0 = healthy
    int action;
    int targetFood;
    uint32_t targetMate;
    bool pregnant;
    float gestation;
    Genome unborn;     // first offspring's genome, fixed at conception
    Genome mateGenome; // the father's genome, for meiosis of litter-mates
    float phase;       // slither phase
    int generation;
    bool sheltered;    // within a nest's radius this step
    bool alive;
    float decay;       // 0 while alive; 0->1 as a corpse rots, then removed
    float grab;        // >0 while seized in a predator's jaws (can't flee)
    float rest;        // 0 awake .. 1 asleep (still, eyes closed, gently breathing)
    simd_float2 goal;  // a personal destination it roams toward (purposeful wander)
    float retarget;    // seconds until it picks a fresh goal
    int   commit;      // frames of commitment left to the current action (anti-dither)
    // --- Bubble Burrower life history ---
    uint32_t partner;  // bonded mate (0 = unbonded); pairs stay together for life
    float care;        // parental-care cooldown after a birth; urge stays low while >0
    float camo;        // eased camouflage 0..1 (ramps up when still, decays when moving)
    float bubbleAcc;   // accumulator that paces rising bubble emission
};

// Mate attractiveness (sexual-selection signal): vivid colour + prominent fins
// + size, scaled by condition (energy·health) so it's an honest signal. Females
// prefer high-ornament males — which also makes those males more visible to
// predators, the classic survival-vs-display trade-off.
static inline float ornament(const Critter &c) {
    float vivid = coatVividness(c.ph.color);
    float sizeN = std::clamp((c.ph.size - 0.6f) / 1.1f, 0.0f, 1.0f);
    float condition = c.energy * c.health;
    return (0.42f*vivid + 0.30f*c.ph.spikes + 0.18f*sizeN + 0.10f)
         * (0.55f + 0.45f*condition);
}

struct Food {
    simd_float2 pos;
    float growth;      // 0..1
    bool alive;
};

// A simple hunting predator (not diploid — a lean agent). It preys on
// critters, and its numbers rise and fall with the prey supply, producing
// predator/prey population cycles. Prey coats that match the ground are harder
// for it to spot, so predation selects for camouflage.
// Predators hunt in coordinated packs. Nearby hunters coalesce into a pack that
// focus-fires a single shared quarry (favouring isolated / weak / young prey),
// and each member takes a geometric role — chasers drive from behind, flankers
// cut off the sides, ambushers slip ahead to intercept — so the pack encircles
// its target instead of all charging the same spot.
enum { PR_Chaser = 0, PR_FlankL = 1, PR_FlankR = 2, PR_Ambush = 3 };
struct Predator {
    simd_float2 pos, vel;
    float heading;
    simd_float2 spine[kSpineNodes];
    float age, lifespan;
    float energy;      // starves at 0
    float size;
    uint32_t targetPrey;
    float cooldown;    // brief pause after a kill
    float phase;
    bool alive;
    uint32_t pack;     // pack identity (nearby hunters merge into one)
    int role;          // PR_Chaser / PR_FlankL / PR_FlankR / PR_Ambush this step
    float feedT;       // >0 while biting/shaking a caught prey before consuming it
    int cryVoice;      // cry-pool voice sounding for the prey it's eating (-1 none)
};

// A nest: a built breeding site. A female returns to hers to give birth (pups
// start with an energy bonus scaled by nest quality) and it offers cover —
// prey near a nest are harder for predators to spot. Nests improve while
// tended and decay when abandoned.
struct Nest {
    simd_float2 pos;
    uint32_t owner;
    float quality;     // 0..1, built up over time
    bool alive;
};

// A pool of drinking water. Critters build up thirst and head to the nearest
// pool to drink; neglecting it dehydrates them.
struct Water {
    simd_float2 pos;
    float radius;
};

// An expanding ring left in the water as something moves across it (a wake).
struct Ripple {
    simd_float2 pos;
    float age, life;
};

// A small air bubble a Bubble Burrower blows — rising and wobbling before it
// pops. Emitted near water, during playful bouts, and in courtship displays.
struct Bubble {
    simd_float2 pos, vel;
    float age, life, size, seed;
};

// Static ground cover — moss, clover, flowers, pebbles, twigs — scattered once
// to carpet the world with damp-forest-floor detail.
struct Decor {
    simd_float2 pos;
    float size, rot, seed;
    int kind;             // 0 moss  1 clover  2 flower  3 pebble  4 twig
    simd_float3 color;
};

// -------------------------------------------------------------- Instances ---

struct InstC {
    float cx, cy, hx, hy, rot, shape;
    float r, g, b, a;
    float p0, p1, p2, p3;
};

// ------------------------------------------------------------ HUD widgets ---
// Every control is a clickable rectangle rebuilt each frame; the mouse handler
// hit-tests these instead of the keyboard driving the sim.
enum {
    WA_None = 0, WA_Toggle, WA_Pause, WA_SpeedDn, WA_SpeedUp,
    WA_ClimateSlider, WA_Food, WA_FoodSlider, WA_Introduce, WA_Cull, WA_Reset,
    WA_TraitPick, WA_ExprSlider, WA_Splice, WA_ToggleGraph,
    WA_AddPredator, WA_CullPredators, WA_StartPopSlider, WA_LifespanSlider,
    WA_ClearColony, WA_ZoomIn, WA_ZoomOut, WA_ResetView, WA_BirthRateSlider,
    WA_DayLenSlider, WA_TimeOfDaySlider, WA_MakeRain,
    WA_ToggleDayNight, WA_ToggleClouds, WA_ToggleRain, WA_SpawnPack, WA_ToggleSound,
    WA_ToggleBubbleSfx, WA_ToggleAuto, WA_TargetPopSlider, WA_ToggleEnv,
};
struct UIWidget { float x, y, w, h; int act; float val; };

// Genes exposed in the splice lab (short label + locus).
struct TraitBtn { const char *name; int gene; };
static const TraitBtn kTraits[] = {
    {"SIZE", GSize0}, {"SPEED", GSpeed}, {"METAB", GMetab}, {"RESIST", GResist},
    {"EYES", GEye},   {"RED", GColR},    {"GREEN", GColG},  {"BLUE", GColB},
    {"FINS", GSpikes},{"BODY", GAspect},
    {"BOLD", GBold},  {"SOCIAL", GSocial}, {"CURIOUS", GCurious}, {"ACTIVE", GActivity},
};
static const int kNumTraitBtns = sizeof(kTraits) / sizeof(kTraits[0]);

static const char *kShaderSource = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct Uni {
    float2 scale;
    float2 offset;
    float2 resolution;
    float time;
    float pad;        // carries the climate value for the ground shader
    float daylight;   // 0 night .. 1 full day
    float warmth;     // dawn/dusk warm cast, 0..1
    float cloud;      // overcast amount, 0..1
    float rain;       // rainfall intensity, 0..1
    float aquarium;   // 0 forest .. 1 aquarium (tank floor + water wash)
};

float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}
float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1,0)), f.x),
               mix(hash21(i + float2(0,1)), hash21(i + float2(1,1)), f.x), f.y);
}
float fbm(float2 p) { float v=0,a=0.5; for(int i=0;i<4;i++){v+=a*vnoise(p);p*=2.03;a*=0.5;} return v; }
float3 gammaOut(float3 c) { return pow(max(c,0.0), float3(0.4545)); }

// ---- ground ----
struct FSOut { float4 position [[position]]; float2 uv; };
vertex FSOut fs_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid<<1)&2, vid&2);
    FSOut o; o.position = float4(p*2.0-1.0, 0.0, 1.0); o.uv = float2(p.x, 1.0-p.y); return o;
}
fragment float4 ground_fragment(FSOut in [[stage_in]], constant Uni &u [[buffer(0)]]) {
    float2 ndc = float2(in.uv.x*2.0-1.0, 1.0-in.uv.y*2.0);
    float2 w = (ndc - u.offset) / u.scale;

    // Biome fields: large-scale moisture + elevation choose the ground type.
    float moist = fbm(w * 0.018 + 11.3);
    float elev  = fbm(w * 0.030 + 3.7);

    // Damp forest-floor palette: mossy greens over dark wet earth.
    float3 moss  = mix(float3(0.09,0.17,0.07), float3(0.17,0.30,0.11), moist);
    float3 dirt  = float3(0.16,0.12,0.08);       // dark damp earth
    float3 mud   = float3(0.24,0.19,0.12);       // wet mud patches
    float3 stone = float3(0.20,0.20,0.19);       // dark stone

    float3 col = moss;
    col = mix(col, dirt, 1.0 - smoothstep(0.30, 0.50, moist));                 // dry -> bare earth
    col = mix(col, mud,  (1.0 - smoothstep(0.20,0.34,moist)) * smoothstep(0.35,0.55,elev));
    col = mix(col, stone, smoothstep(0.66, 0.82, elev) * 0.7);                 // sparse stone

    // Mossy micro-texture: clumpy green mottling + fine speckle.
    float moss2 = fbm(w * 0.9 + 4.0);
    col = mix(col, col * float3(1.25,1.35,1.05), smoothstep(0.55,0.8,moss2) * 0.5*moist);
    col *= 0.88 + 0.22 * fbm(w * 1.7);
    col += 0.04 * (fbm(w * 3.1 + 7.0) - 0.5);

    // Relief shading — light from the upper-left over the elevation field.
    float e0 = fbm(w*0.05), ex = fbm((w+float2(1.6,0))*0.05), ey = fbm((w+float2(0,1.6))*0.05);
    float shade = clamp(0.85 + (-(ex-e0)*0.8 - (ey-e0)*0.6) * 4.0, 0.55, 1.35);
    col *= shade;

    // Climate: frosty-blue cold vs sun-baked warm; snow on higher ground when
    // it gets truly cold.
    float clim = clamp(u.pad, -1.0, 1.0);
    float3 cold = float3(0.14,0.20,0.26), warm = float3(0.34,0.29,0.14);
    col = mix(col, mix(cold, warm, clim*0.5+0.5), 0.24 * abs(clim));
    float snow = smoothstep(0.45, 0.9, -clim) * smoothstep(0.35, 0.65, elev);
    col = mix(col, float3(0.82,0.86,0.92), clamp(snow, 0.0, 0.85));

    // Aquarium: replace the forest floor with a sandy / fine-gravel tank bottom.
    if (u.aquarium > 0.5) {
        float grain = fbm(w * 2.6 + 9.0);                       // sand mottle
        float3 sand = mix(float3(0.60,0.54,0.40), float3(0.72,0.66,0.52), grain);
        float2 gc = floor(w * 3.2);                             // scattered gravel/pebbles
        float pk = fract(sin(dot(gc, float2(12.99,78.23)))*43758.5);
        sand = mix(sand, float3(0.45,0.42,0.40), smoothstep(0.90,0.98,pk)*0.6);
        sand *= 0.9 + 0.2*fbm(w*1.4);                           // gentle undulation shading
        col = sand;
    }

    // Darken beyond the world bounds.
    float2 bd = max(float2(0.0)-w, w-float2(120.0,72.0));
    col *= 1.0 / (1.0 + max(max(bd.x,bd.y),0.0)*0.15);
    return float4(gammaOut(col), 1.0);
}

// ---- sky / weather overlay ----
// A fullscreen wash composited OVER the whole world (ground + critters + water)
// but under the HUD. Outputs PREMULTIPLIED colour for (One, 1-SrcAlpha)
// blending, so several tint layers accumulate cleanly. Carries the day/night
// tint, an overcast grey, a dawn/dusk warm cast, a night vignette, and top-down
// rain impacts (bright drop ticks + faint expanding rings) on the ground.
fragment float4 sky_fragment(FSOut in [[stage_in]], constant Uni &u [[buffer(0)]]) {
    float3 pc = float3(0.0);      // accumulated premultiplied colour
    float  a  = 0.0;              // accumulated coverage
    // helper: composite one straight (colour, alpha) layer on top
    #define OVER(C, A) { float sa=(A); pc = (C)*sa + pc*(1.0-sa); a = sa + a*(1.0-sa); }

    float night = clamp(1.0 - u.daylight, 0.0, 1.0);

    // Aquarium: a blue-green water column washed over everything, lighter toward
    // the top (surface light) and deeper toward the bottom, with a slow caustic
    // shimmer. Drawn first so the day/night tint still layers on top.
    if (u.aquarium > 0.5) {
        float depth = in.uv.y;                                 // 0 top (surface) .. 1 bottom
        float3 shallow = float3(0.16, 0.42, 0.48);
        float3 deep    = float3(0.04, 0.16, 0.26);
        float3 water = mix(shallow, deep, depth);
        // gentle moving caustic ripples
        float2 wp = in.uv * float2(u.resolution.x/max(u.resolution.y,1.0), 1.0);
        float caust = fbm(wp*7.0 + float2(u.time*0.12, u.time*0.07))
                    + 0.5*fbm(wp*13.0 - float2(u.time*0.09, 0.0));
        water += smoothstep(1.1, 1.7, caust) * 0.10;           // faint bright ripples
        OVER(water, 0.42 + 0.14*depth);                        // denser deeper
        // a brighter band of surface light along the very top
        OVER(float3(0.7,0.9,0.95), smoothstep(0.16, 0.0, depth) * 0.18);
    }

    // Deep-night blue wash, strongest at the screen edges (vignette).
    float2 q = in.uv - 0.5;
    float vig = smoothstep(0.2, 0.9, length(q));
    float nightA = night * (0.50 + 0.28 * vig);
    OVER(float3(0.02, 0.045, 0.11), nightA * 0.9);

    // Overcast: a flat cool grey that mutes the scene.
    OVER(float3(0.34, 0.37, 0.41), u.cloud * 0.22);

    // Dawn / dusk warm cast, low on the horizon (bottom of the screen), fading
    // out under heavy overcast.
    float horizon = smoothstep(0.1, 0.9, in.uv.y);
    OVER(float3(0.95, 0.55, 0.22), u.warmth * (0.10 + 0.16 * horizon) * (1.0 - 0.6*u.cloud));

    // Rain: top-down impacts on the ground — a bright drop where each raindrop
    // lands, then a faint expanding ring. Sized in WORLD units (so they read at a
    // consistent, visible scale and track panning/zooming). Rings kept subtle.
    if (u.rain > 0.01) {
        OVER(float3(0.03, 0.06, 0.11), u.rain * 0.16);          // wet grey-out
        float2 ndc = float2(in.uv.x*2.0-1.0, 1.0-in.uv.y*2.0);
        float2 w = (ndc - u.offset) / u.scale;                  // world coords on the ground
        float cell = 3.4;                                       // world units between drops
        float2 id = floor(w / cell);
        float ringAcc = 0.0, dropAcc = 0.0;
        for (int dy=-1; dy<=1; dy++) for (int dx=-1; dx<=1; dx++) {
            float2 g = id + float2(dx,dy);
            float2 c = (g + 0.2 + 0.6*float2(hash21(g), hash21(g+7.3))) * cell;  // drop centre (world)
            float ph = hash21(g + 1.9);
            float age = fract(u.time/1.3 + ph);                 // 0 lands .. 1 gone
            float d = length(w - c);                            // world-unit distance
            dropAcc += smoothstep(0.55, 0.0, d) * smoothstep(0.16, 0.0, age);   // impact flash (~0.5 units)
            float rad = age * 1.9;                              // ring grows to ~1.9 units
            ringAcc += smoothstep(0.28, 0.0, abs(d - rad)) * (1.0 - age) * step(0.05, age);
        }
        OVER(float3(0.74,0.83,0.97), clamp(ringAcc,0.0,1.0) * u.rain * 0.13);    // faint, soft rings
        OVER(float3(0.90,0.95,1.0),  clamp(dropAcc,0.0,1.0) * u.rain * 0.28);    // brighter impact ticks
    }

    #undef OVER
    return float4(pc, a);
}

// ---- instanced entities ----
struct EInst {
    packed_float2 center; packed_float2 half2; float rot; float shape;
    packed_float4 color; packed_float4 params;
};
struct EOut {
    float4 position [[position]]; float2 lp; float4 color; float4 params; float shape;
};
constant float2 kCorners[6] = {
    float2(-1,-1), float2(1,-1), float2(1,1), float2(-1,-1), float2(1,1), float2(-1,1),
};
vertex EOut entity_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device EInst *insts [[buffer(0)]],
                          constant Uni &u [[buffer(1)]]) {
    EInst it = insts[iid];
    float2 lp = kCorners[vid];
    float2 p = lp * float2(it.half2);
    float cs = cos(it.rot), sn = sin(it.rot);
    float2 world = float2(it.center) + float2(p.x*cs - p.y*sn, p.x*sn + p.y*cs);
    EOut o;
    o.position = float4(world * u.scale + u.offset, 0.0, 1.0);
    o.lp = lp; o.color = float4(it.color); o.params = float4(it.params); o.shape = it.shape;
    return o;
}

constant ushort kDigit[10][7] = {
    {0x0E,0x11,0x13,0x15,0x19,0x11,0x0E},{0x04,0x0C,0x04,0x04,0x04,0x04,0x0E},
    {0x0E,0x11,0x01,0x06,0x08,0x10,0x1F},{0x1F,0x02,0x04,0x02,0x01,0x11,0x0E},
    {0x02,0x06,0x0A,0x12,0x1F,0x02,0x02},{0x1F,0x10,0x1E,0x01,0x01,0x11,0x0E},
    {0x06,0x08,0x10,0x1E,0x11,0x11,0x0E},{0x1F,0x01,0x02,0x04,0x08,0x08,0x08},
    {0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E},{0x0E,0x11,0x11,0x0F,0x01,0x02,0x0C},
};
// 5x7 uppercase font, A..Z, for HUD labels.
constant ushort kAlpha[26][7] = {
    {0x0E,0x11,0x11,0x1F,0x11,0x11,0x11},{0x1E,0x11,0x11,0x1E,0x11,0x11,0x1E}, // A B
    {0x0E,0x11,0x10,0x10,0x10,0x11,0x0E},{0x1E,0x11,0x11,0x11,0x11,0x11,0x1E}, // C D
    {0x1F,0x10,0x10,0x1E,0x10,0x10,0x1F},{0x1F,0x10,0x10,0x1E,0x10,0x10,0x10}, // E F
    {0x0E,0x11,0x10,0x17,0x11,0x11,0x0F},{0x11,0x11,0x11,0x1F,0x11,0x11,0x11}, // G H
    {0x0E,0x04,0x04,0x04,0x04,0x04,0x0E},{0x07,0x02,0x02,0x02,0x02,0x12,0x0C}, // I J
    {0x11,0x12,0x14,0x18,0x14,0x12,0x11},{0x10,0x10,0x10,0x10,0x10,0x10,0x1F}, // K L
    {0x11,0x1B,0x15,0x15,0x11,0x11,0x11},{0x11,0x11,0x19,0x15,0x13,0x11,0x11}, // M N
    {0x0E,0x11,0x11,0x11,0x11,0x11,0x0E},{0x1E,0x11,0x11,0x1E,0x10,0x10,0x10}, // O P
    {0x0E,0x11,0x11,0x11,0x15,0x12,0x0D},{0x1E,0x11,0x11,0x1E,0x14,0x12,0x11}, // Q R
    {0x0F,0x10,0x10,0x0E,0x01,0x01,0x1E},{0x1F,0x04,0x04,0x04,0x04,0x04,0x04}, // S T
    {0x11,0x11,0x11,0x11,0x11,0x11,0x0E},{0x11,0x11,0x11,0x11,0x11,0x0A,0x04}, // U V
    {0x11,0x11,0x11,0x15,0x15,0x1B,0x11},{0x11,0x11,0x0A,0x04,0x0A,0x11,0x11}, // W X
    {0x11,0x11,0x0A,0x04,0x04,0x04,0x04},{0x1F,0x01,0x02,0x04,0x08,0x10,0x1F}, // Y Z
};
// A few symbols (codes 36+): '+', '-', '.', '%'.
constant ushort kSym[4][7] = {
    {0x00,0x04,0x04,0x1F,0x04,0x04,0x00},   // 36 '+'
    {0x00,0x00,0x00,0x1F,0x00,0x00,0x00},   // 37 '-'
    {0x00,0x00,0x00,0x00,0x00,0x0C,0x0C},   // 38 '.'
    {0x18,0x19,0x02,0x04,0x08,0x13,0x03},   // 39 '%'
};

fragment float4 entity_fragment(EOut in [[stage_in]]) {
    float2 p = in.lp;
    int shape = int(in.shape + 0.5);
    float a = 0.0;
    if (shape == 0) {                       // soft body blob
        float r = length(p); a = smoothstep(1.0, 0.15, r);
    } else if (shape == 1) {                // selection ring
        float r = length(p); float aa = fwidth(r);
        a = smoothstep(2.5*aa, 0.0, abs(r-0.9));
    } else if (shape == 2) {                // organic leafy sprig (params.x = seed)
        float seed = in.params.x;
        float ang = atan2(p.y, p.x), rad = length(p);
        float lobe = 0.5 + 0.5*cos(ang*5.0 + seed);          // a few leaf lobes
        float wob = 0.18*vnoise(float2(ang*2.5, 1.3)+seed);  // broken edge
        float edge = 0.40 + 0.42*lobe + wob;
        float aa = fwidth(rad);
        float av = smoothstep(edge, edge-0.14-aa, rad);
        if (av < 0.02) discard_fragment();
        float tex = 0.70 + 0.5*vnoise(p*5.0 + seed);         // leaf mottling
        float3 leaf = in.color.rgb * (0.55 + 0.7*rad) * tex; // dark base, bright tips
        return float4(gammaOut(leaf)*av, av);
    } else if (shape == 3) {                // eye: pupil + heritable iris + sclera
        float r = length(p);
        float3 iris = in.color.rgb;
        float3 c = (r < 0.26) ? float3(0.03)                 // pupil
                 : (r < 0.74) ? iris * (0.72 + 0.5*(0.74-r)) // iris fills most of eye
                 : float3(0.95);                             // thin sclera rim
        float av = smoothstep(1.0, 0.78, r);
        return float4(gammaOut(c) * av, av);
    } else if (shape == 4) {                // solid rect (bars, panels, ticks)
        return float4(gammaOut(in.color.rgb) * in.color.a, in.color.a);
    } else if (shape == 5) {                // digit (params.x = value 0..9)
        int d = clamp(int(in.params.x + 0.5), 0, 9);
        int cx = clamp(int((p.x*0.5+0.5)*5.0), 0, 4);
        int cy = clamp(int((1.0-(p.y*0.5+0.5))*7.0), 0, 6);
        uint bit = (uint(kDigit[d][cy]) >> uint(4-cx)) & 1u;
        if (bit == 0u) discard_fragment();
        return float4(gammaOut(in.color.rgb), in.color.a);
    } else if (shape == 6) {                // rounded HUD panel
        float2 q = abs(p) - float2(0.86,0.86);
        float dd = length(max(q,0.0)) - 0.12;
        float aa = fwidth(dd);
        a = smoothstep(aa,-aa,dd);
        return float4(gammaOut(in.color.rgb)*in.color.a*a, in.color.a*a);
    } else if (shape == 7) {                // heart / sick pip (small diamond)
        float d = abs(p.x)+abs(p.y); a = smoothstep(1.0,0.4,d);
    } else if (shape == 8) {                // text glyph: params.x = 0-9 digit, 10-35 A-Z
        int code = clamp(int(in.params.x + 0.5), 0, 39);
        int cx = clamp(int((p.x*0.5+0.5)*5.0), 0, 4);
        int cy = clamp(int((1.0-(p.y*0.5+0.5))*7.0), 0, 6);
        ushort rowbits = (code < 10) ? kDigit[code][cy]
                       : (code < 36) ? kAlpha[code-10][cy] : kSym[code-36][cy];
        uint bit = (uint(rowbits) >> uint(4-cx)) & 1u;
        if (bit == 0u) discard_fragment();
        return float4(gammaOut(in.color.rgb), in.color.a);
    } else if (shape == 9) {                // woven nest bowl (params.x = seed)
        float seed = in.params.x;
        float ang = atan2(p.y, p.x), rad = length(p);
        float outer = 0.90 + 0.10*vnoise(float2(ang*3.0, 2.0)+seed) + 0.05*sin(ang*6.0+seed);
        float aa = fwidth(rad);
        float disc = smoothstep(outer, outer-0.12-aa, rad);
        if (disc < 0.02) discard_fragment();
        float inner = 0.46 + 0.09*vnoise(float2(ang*4.0, 6.0)+seed);
        float cup = smoothstep(inner-0.06, inner+0.12, rad);       // 0 hollow .. 1 rim
        float strands = vnoise(float2(ang*20.0, rad*9.0)+seed);    // woven look
        float3 twig = in.color.rgb * (0.55 + 0.75*strands);
        float3 hollow = in.color.rgb * 0.22;
        float3 col = mix(hollow, twig, cup);
        col += in.color.rgb * 0.30 * smoothstep(outer-0.18, outer, rad); // rim highlight
        return float4(gammaOut(col)*disc, disc);
    } else if (shape == 10) {               // realistic pond: sky reflection + algae
        float t = in.params.x, seed = in.params.y;
        float ang = atan2(p.y, p.x), rad = length(p);
        // Irregular shoreline (no hard circle).
        float edge = 0.92 + 0.055*vnoise(float2(ang*3.0,1.0)+seed)
                          + 0.03*sin(ang*4.0 + seed*1.7);
        float aa = fwidth(rad);
        float mask = smoothstep(edge, edge-0.10-aa, rad);
        if (mask < 0.01) discard_fragment();

        // Reflection coords, distorted by slow ripples so the sky shimmers.
        float2 uv = p * 1.6 + seed;
        float2 rip = float2(fbm(uv*3.0 + float2(t*0.15, 0.0)),
                            fbm(uv*3.0 + float2(0.0, t*0.13))) - 0.5;
        uv += rip * 0.13;
        // Reflected sky: drifting fbm clouds over a steely blue.
        float2 flow = float2(t*0.02, t*0.015);
        float clouds = fbm(uv*1.1 + flow)*0.6 + fbm(uv*2.3 - flow*1.2)*0.4;
        float3 col = mix(float3(0.09,0.15,0.21), float3(0.60,0.66,0.71),
                         smoothstep(0.42, 0.86, clouds));
        // Deeper water in the middle reads darker.
        float depth = 1.0 - smoothstep(0.15, edge, rad);
        col *= 1.0 - 0.42*depth;
        // Green algae / duckweed, thicker in the shallows near the rim.
        float shallow = smoothstep(0.45, edge, rad);
        float weed = fbm(p*7.0 + 5.0);
        col = mix(col, float3(0.24,0.46,0.18),
                  smoothstep(0.60,0.74,weed) * (0.35 + 0.65*shallow) * 0.85);
        col = mix(col, float3(0.17,0.33,0.15),
                  smoothstep(0.55,0.63, fbm(p*3.0+11.0)) * shallow * 0.4);
        // Subtle sparkle on ripple crests, then a wet dark shore rim.
        col += smoothstep(0.78, 1.0, clouds + 0.3*(rip.x+rip.y)) * 0.10;
        col = mix(col, float3(0.05,0.07,0.06), smoothstep(edge-0.15, edge, rad) * 0.55);
        return float4(gammaOut(col)*mask, mask);
    } else if (shape == 11) {               // soft expanding ripple crest
        float r = length(p);
        float d = (r - 0.82) / 0.15;
        float av = exp(-d*d) * in.color.a;   // gaussian ring, no hard edge
        return float4(gammaOut(in.color.rgb)*av, av);
    } else if (shape == 12) {               // grass / reed tuft (params.x = seed)
        float seed = in.params.x;
        float up = clamp(p.y*0.5 + 0.5, 0.0, 1.0);   // 0 base .. 1 tip
        float vmask = smoothstep(-1.0,-0.85,p.y) * (1.0 - smoothstep(0.80,1.05,p.y));
        float av = 0.0, shade = 0.7;
        for (int k = 0; k < 7; k++) {                // a fan of fine blades
            float fk = float(k);
            float rnd = fract(sin(seed*2.3 + fk*7.1) * 91.7);
            float root = (fk - 3.0) * 0.24 + 0.10*sin(seed + fk);
            float lean = (rnd - 0.5) * 2.0 * (0.15 + 0.30*rnd) * up*up;  // curve to tip
            float w = 0.075 * (1.0 - up*0.85);                          // taper to a point
            float blade = smoothstep(w, 0.0, abs(p.x - (root + lean))) * vmask;
            if (blade > av) { av = blade; shade = 0.6 + 0.4*rnd; }
        }
        if (av < 0.02) discard_fragment();
        float3 g = in.color.rgb * shade * (0.5 + 0.65*up);   // dark base, bright tips
        return float4(gammaOut(g)*av, av);
    } else if (shape == 13) {               // moss clump (params.x = seed)
        float seed = in.params.x;
        float ang = atan2(p.y, p.x), rad = length(p);
        float edge = 0.72 + 0.26*vnoise(float2(ang*2.5, 1.0)+seed);   // lumpy outline
        float m = smoothstep(edge, edge-0.30, rad);
        if (m < 0.02) discard_fragment();
        float tex = 0.55 + 0.65*vnoise(p*6.0 + seed);                 // granular moss
        float3 c = in.color.rgb * tex;
        return float4(gammaOut(c)*m, m);
    } else if (shape == 14) {               // little flower
        float ang = atan2(p.y, p.x), rad = length(p);
        float pr = 0.52 + 0.34*cos(ang*5.0);                         // 5 petals
        float m = smoothstep(pr, pr-0.18, rad);
        if (m < 0.02) discard_fragment();
        float3 c = (rad < 0.24) ? float3(0.95,0.82,0.20) : in.color.rgb; // yellow center
        return float4(gammaOut(c)*m, m);
    } else if (shape == 15) {               // Bubble Burrower membrane body (x=seed,y=time)
        float seed=in.params.x, t=in.params.y;
        float rr=length(p), ang=atan2(p.y,p.x), aa=fwidth(rr);
        float edge=0.90*(1.0-0.09*cos(ang)) + 0.02*sin(ang*4.0+t*0.6); // round, slightly tapered front
        float m=smoothstep(edge+aa, edge-aa, rr); if(m<0.01) discard_fragment();
        float3 bcol=in.color.rgb;
        float A=0.50*in.color.a;                                        // see-through membrane + honors fade
        float3 col=bcol*(0.92+0.08*cos(ang*6.0))*(0.85+0.22*fbm(p*3.0+seed)); // faint ribs + tissue
        col*=0.88+0.32*smoothstep(0.25,edge,rr);                        // thin rim brighter
        float2 gp=floor(p*15.0+seed*3.0);                              // internal sparkle (glitter)
        float glit=smoothstep(0.90,0.99, fract(sin(dot(gp,float2(12.9898,78.233)))*43758.5453));
        col+=glit*float3(0.80,0.92,1.0)*0.55; A=max(A, glit*0.9*in.color.a);  // cool sparkle, keeps the hue
        float gloss=smoothstep(0.6,0.0,length(p-float2(-0.16,0.42)));  // top specular sheen
        col+=gloss*float3(0.72,0.82,0.95)*0.40; A=mix(A,0.8*in.color.a,gloss*0.5);
        float rim=smoothstep(edge-0.13,edge-0.005,rr);                 // bright membrane edge
        col=mix(col, bcol*1.7+0.08, rim*0.55); A=mix(A,0.72*in.color.a,rim);
        A*=m; return float4(gammaOut(col)*A, A);
    } else if (shape == 16) {               // bubble dome (transparent air chamber)
        float rr=length(p), aa=fwidth(rr);
        float m=smoothstep(0.96+aa,0.96-aa,rr); if(m<0.01) discard_fragment();
        float A=0.26*in.color.a;
        float3 col=in.color.rgb*0.8+0.08;
        float rim=smoothstep(0.66,0.96,rr);
        col=mix(col, float3(0.9,0.97,1.0), rim*0.55); A=mix(A,0.55*in.color.a,rim);
        float hi=smoothstep(0.42,0.0,length(p-float2(-0.30,0.34)));    // specular glint
        col+=hi*0.7; A=max(A, hi*0.7*in.color.a);
        A*=m; return float4(gammaOut(col)*A, A);
    } else if (shape == 17) {               // big glossy dark navy eye (color = iris tint)
        float rr=length(p), aa=fwidth(rr);
        float m=smoothstep(0.95+aa,0.95-aa,rr); if(m<0.01) discard_fragment();
        float3 iris=in.color.rgb;
        float3 col=mix(float3(0.02,0.03,0.10), iris*0.5, smoothstep(0.1,0.7,rr));  // dark navy core
        col=mix(col, float3(0.01,0.01,0.04), smoothstep(0.82,0.97,rr));            // near-black rim
        col=max(col, float3(0.9,0.95,1.0)*smoothstep(0.26,0.0,length(p-float2(-0.28,0.30)))); // glint
        return float4(gammaOut(col)*m, m*in.color.a);
    } else if (shape == 18) {               // translucent veined webbed fin (color=membrane)
        float up=clamp(p.y*0.5+0.5, 0.0, 1.0);                        // 0 base .. 1 tip
        float halfw=0.12 + 0.9*up*(1.0-0.28*up);                      // widen + round the tip
        float aa=fwidth(p.x)+0.01;
        float side=smoothstep(halfw+aa, halfw-aa, abs(p.x));
        float vert=smoothstep(-1.0,-0.92,p.y)*(1.0-smoothstep(0.9,1.0,up));
        float m=side*vert; if(m<0.01) discard_fragment();
        float vx=p.x/max(halfw,0.01);
        float vein=smoothstep(0.12,0.0, abs(fract(vx*2.5+0.5)-0.5));  // ~5 radiating rays
        float3 col=in.color.rgb*(0.75+0.55*up);
        col=mix(col, in.color.rgb*1.7+0.16, vein*0.55*up);           // glowing vein tips
        float A=(0.30+0.32*up)*m*in.color.a;                         // sheer base, fuller tip
        return float4(gammaOut(col)*A, A);
    } else if (shape == 19) {               // glowing love heart (mating)
        float2 hp = p * 1.28; hp.y = -hp.y;                          // lobes up on screen
        float x2 = hp.x*hp.x, yv = hp.y;
        float base = x2 + yv*yv - 1.0;                               // can be negative inside
        float h = base*base*base - x2 * yv*yv*yv;                    // classic heart implicit
        float m = smoothstep(0.05, -0.05, h); if (m < 0.01) discard_fragment();
        float3 col = mix(in.color.rgb, float3(1.0,0.85,0.90), 0.35 + 0.35*hp.y);  // brighter top
        col += 0.25;                                                 // luminous
        float A = m * in.color.a;
        return float4(gammaOut(col)*A, A);
    }
    // Premultiplied by in.color.a so fading sprites (e.g. decaying corpses)
    // dissolve correctly instead of brightening.
    return float4(gammaOut(in.color.rgb) * a * in.color.a, a * in.color.a);
}

// HUD instances positioned directly in NDC.
vertex EOut hud_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                       const device EInst *insts [[buffer(0)]],
                       constant Uni &u [[buffer(1)]]) {
    EInst it = insts[iid];
    float2 lp = kCorners[vid];
    EOut o;
    o.position = float4(float2(it.center) + lp * float2(it.half2), 0.0, 1.0);
    o.lp = lp; o.color = float4(it.color); o.params = float4(it.params); o.shape = it.shape;
    return o;
}
)METAL";

// --------------------------------------------------------------- Renderer ---

@interface BiomeRenderer : NSObject <MTKViewDelegate>
- (instancetype)initWithView:(MTKView *)view;
@end

@implementation BiomeRenderer {
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _groundPipeline;
    id<MTLRenderPipelineState> _entityPipeline;
    id<MTLRenderPipelineState> _skyPipeline;
    id<MTLRenderPipelineState> _hudPipeline;
    id<MTLBuffer> _instBuffers[kMaxInFlight];
    id<MTLBuffer> _glowBuffers[kMaxInFlight];
    id<MTLBuffer> _hudBuffers[kMaxInFlight];
    int _frameIndex;
    dispatch_semaphore_t _frameSemaphore;
    std::vector<InstC> _scratch;
    std::vector<InstC> _glow;      // bioluminescent halos, drawn AFTER the night wash
    std::vector<InstC> _hud;

    std::vector<Critter> _critters;
    std::vector<Food> _food;
    std::vector<Predator> _predators;
    std::vector<Nest> _nests;
    std::vector<Water> _water;
    std::vector<Ripple> _ripples;
    std::vector<Bubble> _bubbles;
    std::vector<Bubble> _hearts;    // little glowing hearts that float up during mating
    std::vector<Decor> _decor;
    std::mt19937 _rng;
    int _initialPop;        // colony size at start, for growth %
    uint32_t _nextId;
    int _generation;
    int _births, _deaths;
    uint32_t _selected;
    bool _paused;
    float _timeScale;
    float _foodTimer;

    // Environment + evolutionary history.
    double _worldTime;      // accumulated sim seconds (drives seasons)
    float _climate;         // -1 cold .. +1 hot (current)
    float _climateTrend;    // slow-drifting climate baseline
    float _sampleTimer;
    int   _histCount, _histHead;
    float _histClim[kHistLen];  // all normalized 0..1 for plotting
    float _histSize[kHistLen];
    float _histDark[kHistLen];
    float _histRes[kHistLen];
    float _histPop[kHistLen];
    float _histPred[kHistLen];   // predator population (normalized)

    int _foodTarget;        // carrying-capacity target (set from the HUD)
    int _startPop;          // colony size at reset (HUD)
    float _lifespanMul;     // global multiplier on genetic lifespan (HUD)
    float _birthRate;       // reproduction multiplier: urge speed + litter size (HUD)

    // Auto-adjust: a feedback controller that steers birth rate + food to hold
    // the colony on a steady ~5%-per-minute growth trajectory.
    bool  _autoAdjust;
    float _autoTargetPop;   // target average the balance controller holds
    float _autoTimer;       // seconds until the next control update
    int   _livingCount;     // living critters this step (cached; drives the birth cap)

    // Day/night + weather.
    float _timeOfDay;       // 0..1 through one day (0 = midnight, 0.5 = noon)
    float _dayLen;          // seconds per full day (HUD)
    float _daylight;        // 0 night .. 1 day (derived)
    float _skyWarm;         // dawn/dusk warm cast 0..1 (derived)
    float _activity;        // crepuscular activity multiplier (derived)
    float _cloud, _rain;            // current overcast / rainfall, 0..1
    float _cloudTarget, _rainTarget;// where the weather is drifting toward
    float _weatherTimer;            // time until the next weather regime
    bool _dayNightOn, _cloudsOn, _rainOn;   // HUD toggles for each sky element
    bool _aquarium;                 // AQUARIUM ⇄ FOREST: aquatic movement + tank reskin
    uint32_t _nextPack;             // next unique pack id to hand out

    // Ambient audio: three looping layers (day / night / rain) whose volumes
    // crossfade with the time of day and the weather, plus event one-shots.
    AVAudioPlayer *_sndDay, *_sndNight, *_sndRain;
    float _volDay, _volNight, _volRain;     // current eased volumes
    float _muteGain;                        // eased 0/1 so mute/unmute doesn't click
    bool _muted;                            // HUD sound toggle
    NSArray<AVAudioPlayer *> *_cries;       // prey distress-cry pool (on seize)
    int _cryIdx;
    NSArray<AVAudioPlayer *> *_crawls;      // crawl-texture pool (colony movement)
    int _crawlIdx; float _crawlTimer;
    NSArray<AVAudioPlayer *> *_bubbleSfx;   // bubble-blowing pool
    int _bubbleIdx; float _bubbleTimer;
    bool _bubbleSfxOn;                       // HUD toggle just for the bubble sound

    // Sliding control panel + mouse widget state.
    std::vector<UIWidget> _widgets;
    float _panelT, _panelTarget;   // 0 hidden .. 1 shown
    float _panelScroll;            // vertical scroll offset when content overflows
    float _panelOverflow;          // how far content runs past the window (px), recomputed each build
    int   _spliceGene;             // locus selected in the gene lab
    float _spliceExpr;             // engineered expression level 0..1
    bool  _showGraph;              // evolution graph visible?
    int   _dragAct;                // slider being dragged (WA_None if none)
    float _dragX, _dragW;
    int   _flashAct;               // last-clicked widget, for a click flash
    float _flashVal, _flashT;      // _flashT counts down (seconds)

    simd_float2 _uScale, _uOffset;
    double _startTime, _lastFrameTime, _simAccum;
    float _smoothedFPS;

    // Camera (zoom + pan) and world drag-to-pan / click-to-select state.
    float _zoom;                   // 1 = whole world in view
    simd_float2 _panCenter;        // world point held at screen center
    bool _worldDrag, _worldMoved;
    float _downPxX, _downPxY;
    simd_float2 _panAtDown, _downWorld;
}

- (instancetype)initWithView:(MTKView *)view {
    if (!(self = [super init])) return nil;
    id<MTLDevice> device = view.device;
    _queue = [device newCommandQueue];

    id<MTLLibrary> lib = CompileLibrary(device, kShaderSource);
    if (!lib) return nil;
    NSError *err = nil;
    id<MTLFunction> fsv = [lib newFunctionWithName:@"fs_vertex"];

    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    d.vertexFunction = fsv;
    d.fragmentFunction = [lib newFunctionWithName:@"ground_fragment"];
    _groundPipeline = [device newRenderPipelineStateWithDescriptor:d error:&err];
    if (!_groundPipeline) { fprintf(stderr,"ground: %s\n", err.localizedDescription.UTF8String); return nil; }

    d.colorAttachments[0].blendingEnabled = YES;
    d.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    d.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    d.vertexFunction = [lib newFunctionWithName:@"entity_vertex"];
    d.fragmentFunction = [lib newFunctionWithName:@"entity_fragment"];
    _entityPipeline = [device newRenderPipelineStateWithDescriptor:d error:&err];
    if (!_entityPipeline) { fprintf(stderr,"entity: %s\n", err.localizedDescription.UTF8String); return nil; }

    // Sky / weather overlay: fullscreen wash, same premultiplied blend as entities.
    d.vertexFunction = fsv;
    d.fragmentFunction = [lib newFunctionWithName:@"sky_fragment"];
    _skyPipeline = [device newRenderPipelineStateWithDescriptor:d error:&err];
    if (!_skyPipeline) { fprintf(stderr,"sky: %s\n", err.localizedDescription.UTF8String); return nil; }

    // HUD reuses the entity fragment shader (EOut in) with the NDC hud_vertex —
    // restore it after the sky pass swapped in sky_fragment (FSOut in).
    d.vertexFunction = [lib newFunctionWithName:@"hud_vertex"];
    d.fragmentFunction = [lib newFunctionWithName:@"entity_fragment"];
    _hudPipeline = [device newRenderPipelineStateWithDescriptor:d error:&err];
    if (!_hudPipeline) { fprintf(stderr,"hud: %s\n", err.localizedDescription.UTF8String); return nil; }

    for (int i = 0; i < kMaxInFlight; i++) {
        _instBuffers[i] = [device newBufferWithLength:kMaxInstances*sizeof(InstC)
                                              options:MTLResourceStorageModeShared];
        _glowBuffers[i] = [device newBufferWithLength:kMaxCritters*sizeof(InstC)
                                              options:MTLResourceStorageModeShared];
        _hudBuffers[i] = [device newBufferWithLength:4096*sizeof(InstC)
                                             options:MTLResourceStorageModeShared];
    }
    _frameIndex = 0;
    _frameSemaphore = dispatch_semaphore_create(kMaxInFlight);
    _scratch.reserve(kMaxInstances);
    _glow.reserve(kMaxCritters);
    _hud.reserve(4096);
    // Reserve to the hard caps so births/food never reallocate the vectors
    // mid-simulation (which would invalidate the references we hold).
    _critters.reserve(kMaxCritters);
    _food.reserve(kMaxFood);
    _predators.reserve(kMaxPredators);
    _nests.reserve(kMaxNests);
    _water.reserve(kMaxWater);
    _ripples.reserve(kMaxRipples);
    _bubbles.reserve(kMaxBubbles);
    _hearts.reserve(256);
    _decor.reserve(kMaxDecor);

    _rng.seed(0xB10E);
    _nextId = 1;
    _selected = 0;
    _paused = NO;
    _timeScale = 1.0f;
    _widgets.reserve(64);
    _panelT = _panelTarget = 1.0f;   // start open so the controls are discoverable
    _spliceGene = GSize0;
    _spliceExpr = 0.9f;
    _showGraph = true;
    _dragAct = WA_None;
    _flashAct = WA_None;
    _flashVal = 0;
    _flashT = 0;
    _startPop = 24;
    _lifespanMul = 1.0f;
    _birthRate = 1.6f;
    _autoAdjust = false; _autoTargetPop = 170.0f; _autoTimer = 0.0f; _livingCount = 0;
    _timeOfDay = 0.30f;         // start a little after dawn
    _dayLen = 100.0f;           // seconds per day
    _daylight = 1.0f; _skyWarm = 0.0f; _activity = 1.0f;
    _cloud = 0.15f; _rain = 0.0f;
    _cloudTarget = 0.15f; _rainTarget = 0.0f; _weatherTimer = 20.0f;
    _dayNightOn = true; _cloudsOn = true; _rainOn = true;
    _aquarium = false;
    _panelScroll = 0.0f; _panelOverflow = 0.0f;
    _nextPack = 1;
    _zoom = 1.0f;
    _panCenter = simd_make_float2(kWorldW*0.5f, kWorldH*0.5f);
    _worldDrag = false; _worldMoved = false;
    [self resetColony];

    __unsafe_unretained BiomeRenderer *weakSelf = self;
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                          handler:^NSEvent *(NSEvent *e) {
        if (e.modifierFlags & NSEventModifierFlagCommand) return e;
        unsigned short c = e.keyCode;
        if (c == 49) { weakSelf->_paused = !weakSelf->_paused; return nil; }  // space
        if (c == 3)  { [weakSelf scatterFood:60]; return nil; }               // F
        if (c == 40) { [weakSelf cullSelected]; return nil; }                 // K
        if (c == 34) { [weakSelf introduceRandom]; return nil; }              // I
        if (c == 15) { [weakSelf resetColony]; return nil; }                  // R
        if (c == 33) { weakSelf->_timeScale = std::max(weakSelf->_timeScale*0.5f, 0.25f); return nil; } // [
        if (c == 30) { weakSelf->_timeScale = std::min(weakSelf->_timeScale*2.0f, 8.0f); return nil; }  // ]
        if (c == 43) { weakSelf->_climateTrend = std::max(weakSelf->_climateTrend-0.15f, -0.75f); return nil; } // , cool
        if (c == 47) { weakSelf->_climateTrend = std::min(weakSelf->_climateTrend+0.15f,  0.75f); return nil; } // . warm
        return e;
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                          handler:^NSEvent *(NSEvent *e) {
        if (!e.window) return e;
        MTKView *v = (MTKView *)e.window.contentView;
        if (![v isKindOfClass:[MTKView class]] || weakSelf->_uScale.x == 0) return e;
        NSPoint pt = [v convertPoint:e.locationInWindow fromView:nil];
        float bw = (float)v.bounds.size.width, bh = (float)v.bounds.size.height;
        // 1) HUD widgets first (topmost wins → iterate in reverse).
        if ([weakSelf hudMouseDown:simd_make_float2((float)pt.x,(float)pt.y) bw:bw bh:bh])
            return nil;
        // 2) world: begin a click/drag. A click selects on mouse-up; a drag pans.
        simd_float2 ndc = simd_make_float2((float)(pt.x/bw)*2.0f-1.0f,
                                           (float)(pt.y/bh)*2.0f-1.0f);
        weakSelf->_worldDrag = true;
        weakSelf->_worldMoved = false;
        weakSelf->_downPxX = (float)pt.x; weakSelf->_downPxY = (float)pt.y;
        weakSelf->_panAtDown = weakSelf->_panCenter;
        weakSelf->_downWorld = (ndc - weakSelf->_uOffset) / weakSelf->_uScale;
        return e;
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDragged
                                          handler:^NSEvent *(NSEvent *e) {
        if (!e.window) return e;
        MTKView *v = (MTKView *)e.window.contentView;
        if (![v isKindOfClass:[MTKView class]]) return e;
        NSPoint pt = [v convertPoint:e.locationInWindow fromView:nil];
        float bw = (float)v.bounds.size.width, bh = (float)v.bounds.size.height;
        if (weakSelf->_dragAct != WA_None) {                 // slider drag
            float frac = ((float)pt.x - weakSelf->_dragX) / std::max(weakSelf->_dragW, 1.0f);
            [weakSelf applySlider:weakSelf->_dragAct frac:std::clamp(frac,0.0f,1.0f)];
            return nil;
        }
        if (weakSelf->_worldDrag) {                          // pan the camera
            float dpx = (float)pt.x - weakSelf->_downPxX, dpy = (float)pt.y - weakSelf->_downPxY;
            if (fabsf(dpx) + fabsf(dpy) > 3.0f) weakSelf->_worldMoved = true;
            simd_float2 dndc = simd_make_float2(2.0f*dpx/bw, 2.0f*dpy/bh);
            simd_float2 dworld = dndc / weakSelf->_uScale;
            weakSelf->_panCenter = weakSelf->_panAtDown - dworld;
            [weakSelf clampPan];
            return nil;
        }
        return e;
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp
                                          handler:^NSEvent *(NSEvent *e) {
        weakSelf->_dragAct = WA_None;
        if (weakSelf->_worldDrag) {
            if (!weakSelf->_worldMoved) [weakSelf selectAt:weakSelf->_downWorld];  // a click
            weakSelf->_worldDrag = false;
        }
        return e;
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
                                          handler:^NSEvent *(NSEvent *e) {
        if (!e.window) return e;
        MTKView *v = (MTKView *)e.window.contentView;
        if (![v isKindOfClass:[MTKView class]] || weakSelf->_uScale.x == 0) return e;
        NSPoint pt = [v convertPoint:e.locationInWindow fromView:nil];
        float bw = (float)v.bounds.size.width, bh = (float)v.bounds.size.height;
        // Over the open control panel: scroll its content instead of zooming.
        float panelX = bw - 300.0f * weakSelf->_panelT;
        if (weakSelf->_panelT > 0.5f && pt.x >= panelX) {
            weakSelf->_panelScroll = std::clamp(
                weakSelf->_panelScroll - (float)e.scrollingDeltaY,
                0.0f, weakSelf->_panelOverflow);
            return nil;
        }
        simd_float2 ndc = simd_make_float2((float)(pt.x/bw)*2.0f-1.0f,
                                           (float)(pt.y/bh)*2.0f-1.0f);
        float f = 1.0f + (float)e.scrollingDeltaY * 0.01f;   // scroll up = zoom in
        f = std::clamp(f, 0.5f, 1.6f);
        [weakSelf zoomBy:f atNdc:ndc];
        return nil;
    }];

    printf("=== BIOME v37 (Bubble Burrower) — if you don't see this line you're "
           "running an OLD BINARY (run: rm -rf build && make build/09-biome) ===\n"
           "New: little glowing HEARTS float up from courting and mating pairs.\n"
           "Plus heritable TEMPERAMENT (bold/social/curious/active) driving\n"
           "individual behaviour, purposeful goal-seeking, and the BALANCE\n"
           "auto-pilot + TARGET POP (set it to ~50 for a small colony).\n");

    [self setupAudio];
    _startTime = CACurrentMediaTime();
    _lastFrameTime = _startTime;
    _simAccum = 0;
    _smoothedFPS = 60;
    return self;
}

// ------------------------------------------------------------------ Setup ---

- (simd_float2)randomPos {
    std::uniform_real_distribution<float> ux(4, kWorldW-4), uy(4, kWorldH-4);
    return simd_make_float2(ux(_rng), uy(_rng));
}

- (void)spawnCritter:(Genome)g at:(simd_float2)pos gen:(int)gen {
    if ((int)_critters.size() >= kMaxCritters) return;
    Critter c = {};
    c.id = _nextId++;
    c.genome = g;
    c.ph = phenotypeOf(g);
    c.male = isMale(g);
    c.pos = pos;
    c.vel = simd_make_float2(0,0);
    std::uniform_real_distribution<float> u(0,1);
    c.heading = u(_rng) * 6.28f;
    for (int i = 0; i < kSpineNodes; i++) c.spine[i] = pos;
    c.age = (gen == 0) ? u(_rng) * 20.0f : 0.0f;   // seed colony has mixed ages
    c.maturity = 9.0f;
    c.energy = 0.7f + 0.3f * u(_rng);
    c.hunger = 0.2f * u(_rng);
    c.thirst = 0.2f * u(_rng);
    c.urge = 0;
    c.health = 1.0f;
    c.sick = 0;
    c.action = AWander;
    c.targetFood = -1;
    c.targetMate = 0;
    c.pregnant = false;
    c.phase = u(_rng) * 6.28f;
    c.generation = gen;
    c.alive = true;
    c.decay = 0.0f;
    c.partner = 0;
    c.care = 0.0f;
    c.camo = 0.0f;
    c.bubbleAcc = u(_rng);
    c.grab = 0.0f;
    c.rest = 0.0f;
    c.goal = pos;
    c.retarget = u(_rng) * 3.0f;
    c.commit = 0;
    _critters.push_back(c);
}

- (void)scatterFood:(int)n {
    for (int i = 0; i < n && (int)_food.size() < kMaxFood; i++) {
        Food f;
        f.pos = [self randomPos];
        f.growth = 0.2f;
        f.alive = true;
        _food.push_back(f);
    }
}

- (void)introduceRandom {
    [self spawnCritter:randomGenome(_rng, -1) at:[self randomPos] gen:_generation];
}

- (int)livingCount {
    int n = 0; for (const Critter &c : _critters) if (c.alive) n++; return n;
}

// Colony auto-pilot (BALANCE): hold the population near a target AVERAGE by
// steering the whole ecosystem, not just births — food carrying capacity, birth
// rate, predators, and a touch of climate stress — so an overshoot is thinned by
// scarcity and predation and a shortfall recovers, giving a thriving, evolving
// colony that self-regulates instead of exploding.
- (void)autoAdjustStep:(float)dt {
    if (!_autoAdjust) return;
    _autoTimer -= dt;
    if (_autoTimer > 0.0f) return;
    _autoTimer = 2.5f;                                           // re-tune every 2.5s
    float target = std::clamp(_autoTargetPop, 20.0f, (float)kLiveCap - 20.0f);
    int pop = _livingCount;
    if (pop == 0) { [self introduceRandom]; [self introduceRandom]; return; }  // reseed a crash
    float e = (float)pop - target;                              // >0 over, <0 under
    float rel = e / std::max(target, 1.0f);                    // fractional error

    // 1) Food carrying capacity — the primary regulator. Lean when crowded
    //    (starvation thins them), rich when sparse.
    _foodTarget = std::clamp((int)(target * 1.4f - e * 1.6f), 60, 520);
    // 2) Birth rate — fewer young when crowded, more when sparse.
    _birthRate  = std::clamp(1.8f - rel * 2.6f, 0.5f, 4.5f);
    // 3) Predators — bring a hunting pack in to crop an overshoot; ease them off
    //    when the colony is thin. (Predators also self-limit by starving.)
    int preds = (int)_predators.size();
    int wantPreds = std::clamp((int)((pop - target*0.9f) / 22.0f), 0, 10);
    if (preds < wantPreds && pop > target)      [self spawnPack:std::min(4, wantPreds - preds)];
    else if (preds > 0 && pop < target * 0.8f)  [self cullPredators];
    // 4) Climate stress — when badly overpopulated, drift toward the nearer
    //    extreme (harsher → more thermal attrition + selection); relax back to
    //    temperate when at or below target.
    if (rel > 0.5f)      _climateTrend += (_climateTrend >= 0.0f ? 0.05f : -0.05f);
    else if (rel < 0.0f) _climateTrend *= 0.95f;
    _climateTrend = std::clamp(_climateTrend, -0.85f, 0.85f);
}

// Locate an asset by name, trying a few paths relative to where the binary is
// typically run from. Returns nil if the file is missing.
- (NSString *)assetPath:(NSString *)name {
    NSString *exeDir = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent] ?: @".";
    NSArray<NSString *> *candidates = @[
        [NSString stringWithFormat:@"09-biome/assets/%@.mp3", name],          // run from metal-examples/
        [NSString stringWithFormat:@"assets/%@.mp3", name],                   // run from 09-biome/
        [NSString stringWithFormat:@"../09-biome/assets/%@.mp3", name],       // run from build/
        [exeDir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"../09-biome/assets/%@.mp3", name]],  // relative to the exe
    ];
    for (NSString *path in candidates)
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return path;
    fprintf(stderr, "audio: could not find %s.mp3 (place it in 09-biome/assets/)\n", name.UTF8String);
    return nil;
}

// A looping ambience track, started at volume 0 (crossfaded up later).
- (AVAudioPlayer *)loadLoop:(NSString *)name {
    NSString *path = [self assetPath:name];
    if (!path) return nil;
    AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:nil];
    if (p) { p.numberOfLoops = -1; p.volume = 0.0f; [p prepareToPlay]; [p play]; }
    return p;
}

// Build a pool of `count` independent players for one clip, so the one-shot can
// overlap with itself. `names` may list several variant files to draw from.
- (NSArray<AVAudioPlayer *> *)loadPool:(NSArray<NSString *> *)names count:(int)count {
    NSMutableArray<AVAudioPlayer *> *pool = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        NSString *path = [self assetPath:names[i % names.count]];
        if (!path) continue;
        AVAudioPlayer *p = [[AVAudioPlayer alloc]
            initWithContentsOfURL:[NSURL fileURLWithPath:path] error:nil];
        if (p) { p.numberOfLoops = 0; p.enableRate = YES; [p prepareToPlay]; [pool addObject:p]; }
    }
    return pool;
}

- (void)setupAudio {
    _muted = false;
    _muteGain = 1.0f;
    _volDay = _volNight = _volRain = 0.0f;
    _sndDay   = [self loadLoop:@"day"];
    _sndNight = [self loadLoop:@"night"];
    _sndRain  = [self loadLoop:@"rain"];
    // Event one-shots (pooled so they can overlap).
    _cries      = [self loadPool:@[@"cry"] count:4];
    _crawls     = [self loadPool:@[@"crawl1",@"crawl2",@"crawl3",@"crawl4"] count:4];
    _bubbleSfx  = [self loadPool:@[@"bubble"] count:3];
    _cryIdx = _crawlIdx = _bubbleIdx = 0;
    _crawlTimer = 0.4f; _bubbleTimer = 1.0f;
    _bubbleSfxOn = true;
}

// One-shot: a prey's cry when it's seized. Cycles the pool so overlaps play, and
// returns the voice index so the caller can cut it off the instant the prey is
// consumed. Little random volume/pitch variation so repeats aren't identical.
- (int)playCry {
    if (_muted || _cries.count == 0) return -1;
    int voice = _cryIdx % (int)_cries.count;
    _cryIdx++;
    AVAudioPlayer *p = _cries[voice];
    std::uniform_real_distribution<float> u(0,1);
    p.volume = 0.7f + 0.25f * u(_rng);
    p.enableRate = YES;
    p.rate = 0.92f + 0.16f * u(_rng);
    p.currentTime = 0.0;
    [p play];
    return voice;
}

// Cut a cry off (the prey is gone, so the sound should stop immediately).
- (void)stopCry:(int)voice {
    if (voice >= 0 && voice < (int)_cries.count) { [_cries[voice] stop]; _cries[voice].currentTime = 0.0; }
}

// Crossfade the three ambience layers from the current game state each frame:
// day vs night by the light level, ducking under rain, which fades up on top.
- (void)updateAudio:(float)dt {
    const float master = 0.75f;
    // Lock the ambience volumes DIRECTLY to the same _rain / _daylight the sky
    // shader uses (both already ease smoothly), so the rain track fades in and
    // out exactly in step with the on-screen rain. Only the mute is smoothed,
    // to avoid a click.
    float rainMix = std::clamp(_rain, 0.0f, 1.0f);
    _muteGain += ((_muted ? 0.0f : 1.0f) - _muteGain) * std::min(6.0f * dt, 1.0f);  // ~0.16s
    // Rain audio must track how VISIBLE the rain is, not just _rain. A trace of
    // rain is nearly invisible, so it should be silent too — a curve + a hard
    // gate keep the sound off until it's actually raining on screen.
    float rainVis = (rainMix < 0.08f) ? 0.0f : powf((rainMix - 0.08f)/0.92f, 1.4f);
    float duck = 1.0f - 0.65f * rainVis;                 // forest ducks so rain dominates
    float forest = _aquarium ? 0.28f : 1.0f;             // no forest in a tank (full SFX later)
    _volDay   = _daylight * duck * master * _muteGain * forest;
    _volNight = (1.0f - _daylight) * duck * master * _muteGain * forest;
    _volRain  = std::clamp(rainVis * master * 1.9f, 0.0f, 1.0f) * _muteGain;   // rain sits louder
    if (_sndDay)   _sndDay.volume   = _volDay;
    if (_sndNight) _sndNight.volume = _volNight;
    if (_sndRain)  _sndRain.volume  = _volRain;

    if (_muted || _paused) return;
    std::uniform_real_distribution<float> u(0,1);
    // Ambient crawl texture: occasional soft crawl sounds, more often the more
    // of the colony is on the move — the sound of critters shuffling around you.
    _crawlTimer -= dt;
    if (_crawlTimer <= 0.0f) {
        int moving = 0;
        for (const Critter &c : _critters)
            if (c.alive && simd_length(c.vel) > 1.2f) moving++;
        if (moving > 0 && _crawls.count) {
            AVAudioPlayer *p = _crawls[_crawlIdx % _crawls.count]; _crawlIdx++;
            p.volume = 0.04f + 0.06f * u(_rng);      // soft, well under the ambience
            p.enableRate = YES; p.rate = 0.88f + 0.28f * u(_rng);
            p.currentTime = 0.0; [p play];
        }
        float busy = std::clamp(moving / 45.0f, 0.0f, 1.0f);
        _crawlTimer = 0.55f - 0.38f * busy + 0.25f * u(_rng);   // busier colony → more shuffling
    }
    // Bubble blowing: rare and soft, and only during an actual burst of bubbles
    // (not the odd stray one that's almost always drifting somewhere).
    _bubbleTimer -= dt;
    if (_bubbleTimer <= 0.0f) {
        if (_bubbleSfxOn && (int)_bubbles.size() >= 10 && _bubbleSfx.count) {
            AVAudioPlayer *p = _bubbleSfx[_bubbleIdx % _bubbleSfx.count]; _bubbleIdx++;
            p.volume = 0.05f + 0.06f * u(_rng);
            p.enableRate = YES; p.rate = 0.9f + 0.25f * u(_rng);
            p.currentTime = 0.0; [p play];
        }
        _bubbleTimer = 5.0f + 5.0f * u(_rng);       // every ~5-10s at most
    }
}

// Spawn a whole coordinated pack at once: n hunters clustered at one spot and
// sharing a single pack identity, so they immediately take up distinct roles
// (driver / flankers / ambusher) and run the full encircling hunt.
- (void)spawnPack:(int)n {
    simd_float2 c = [self randomPos];
    uint32_t pk = _nextPack++;
    std::uniform_real_distribution<float> u(0,1);
    for (int i = 0; i < n; i++) {
        simd_float2 pos = c + simd_make_float2((u(_rng)-0.5f)*6.0f, (u(_rng)-0.5f)*6.0f);
        size_t before = _predators.size();
        [self spawnPredator:pos];
        if (_predators.size() > before) _predators.back().pack = pk;   // one shared pack
    }
}

// Scatter static ground cover across the world (skipping the ponds) to carpet
// it in moss, clover, flowers, pebbles and twigs.
- (void)generateDecor {
    _decor.clear();
    std::uniform_real_distribution<float> u(0,1);
    const float cell = 1.2f;
    for (float gy = 2.0f; gy < kWorldH-2.0f; gy += cell) {
        for (float gx = 2.0f; gx < kWorldW-2.0f; gx += cell) {
            if ((int)_decor.size() >= kMaxDecor) return;
            if (u(_rng) > 0.72f) continue;                       // leave gaps
            simd_float2 pos = simd_make_float2(gx + (u(_rng)-0.5f)*cell,
                                               gy + (u(_rng)-0.5f)*cell);
            bool inWater = false;
            for (const Water &wp : _water)
                if (simd_distance(pos, wp.pos) < wp.radius*1.05f) { inWater = true; break; }
            if (inWater) continue;
            Decor d; d.pos = pos; d.seed = u(_rng)*100.0f; d.rot = u(_rng)*6.2831f;
            float r = u(_rng);
            if (r < 0.54f) {                    // moss clump
                d.kind = 0; d.size = 0.35f + 0.45f*u(_rng);
                d.color = simd_make_float3(0.09f+0.06f*u(_rng), 0.26f+0.18f*u(_rng), 0.08f+0.05f*u(_rng));
            } else if (r < 0.82f) {             // clover sprig
                d.kind = 1; d.size = 0.40f + 0.35f*u(_rng);
                d.color = simd_make_float3(0.13f, 0.40f+0.20f*u(_rng), 0.12f);
            } else if (r < 0.90f) {             // little flower
                d.kind = 2; d.size = 0.22f + 0.12f*u(_rng);
                d.color = (u(_rng) < 0.62f) ? simd_make_float3(0.95f,0.95f,0.90f)
                                            : simd_make_float3(0.72f,0.66f,0.90f);
            } else if (r < 0.96f) {             // pebble
                d.kind = 3; d.size = 0.24f + 0.22f*u(_rng);
                float s = 0.26f + 0.18f*u(_rng);
                d.color = simd_make_float3(s, s*0.95f, s*0.86f);
            } else {                            // twig
                d.kind = 4; d.size = 0.6f + 0.8f*u(_rng);
                d.color = simd_make_float3(0.25f, 0.18f, 0.10f);
            }
            _decor.push_back(d);
        }
    }
}

- (void)spawnPredator:(simd_float2)pos {
    if ((int)_predators.size() >= kMaxPredators) return;
    std::uniform_real_distribution<float> u(0,1);
    Predator p = {};
    p.pos = pos;
    p.vel = simd_make_float2(0,0);
    p.heading = u(_rng) * 6.28f;
    for (int i = 0; i < kSpineNodes; i++) p.spine[i] = pos;
    p.age = 0;
    p.lifespan = 90.0f + 40.0f * u(_rng);
    p.energy = 0.7f;
    p.size = 1.7f + 0.4f * u(_rng);      // larger than prey
    p.targetPrey = 0;
    p.cooldown = 0;
    p.phase = u(_rng) * 6.28f;
    p.alive = true;
    p.pack = _nextPack++;        // its own pack until it meets others
    p.role = PR_Chaser;
    p.feedT = 0.0f;
    p.cryVoice = -1;
    _predators.push_back(p);
}

- (void)cullPredators {
    _predators.clear();
}

// If something is moving across a pool, occasionally drop a ripple at its feet.
- (void)waterRippleAt:(simd_float2)pos vel:(simd_float2)vel dt:(float)dt {
    if (simd_length(vel) < 1.2f) return;
    std::uniform_real_distribution<float> u(0,1);
    for (const Water &wp : _water)
        if (simd_distance(pos, wp.pos) < wp.radius) {
            if (u(_rng) < 2.4f * dt && (int)_ripples.size() < kMaxRipples) {
                Ripple rp;
                rp.pos = pos + simd_make_float2((u(_rng)-0.5f)*0.7f, (u(_rng)-0.5f)*0.7f);
                rp.age = 0; rp.life = 1.8f;
                _ripples.push_back(rp);
            }
            return;
        }
}

// Blow a little air bubble that rises and pops. `strength` (0..1) paces how
// often bubbles appear; each critter carries an accumulator so emission is
// smooth and frame-rate independent.
- (void)emitBubble:(Critter &)c strength:(float)strength dt:(float)dt {
    if ((int)_bubbles.size() >= kMaxBubbles) return;
    std::uniform_real_distribution<float> u(0,1);
    c.bubbleAcc += strength * 3.0f * dt;
    if (c.bubbleAcc < 1.0f) return;
    c.bubbleAcc -= 1.0f;
    simd_float2 fwd = simd_make_float2(cosf(c.heading), sinf(c.heading));
    Bubble b;
    b.pos = c.pos + fwd * (0.6f * c.ph.size) + simd_make_float2((u(_rng)-0.5f)*0.4f, (u(_rng)-0.5f)*0.4f);
    b.vel = simd_make_float2((u(_rng)-0.5f)*0.6f, 0.8f + u(_rng)*0.7f);   // drifts up
    b.age = 0; b.life = 1.1f + u(_rng)*0.9f;
    b.size = 0.10f + u(_rng)*0.14f;
    b.seed = u(_rng)*10.0f;
    _bubbles.push_back(b);
}

// A little glowing heart drifting up from a spot — courtship / conception.
- (void)emitHeart:(simd_float2)pos {
    if ((int)_hearts.size() >= 256) return;
    std::uniform_real_distribution<float> u(0,1);
    Bubble h;
    h.pos = pos + simd_make_float2((u(_rng)-0.5f)*1.1f, (u(_rng)-0.5f)*0.6f);
    h.vel = simd_make_float2((u(_rng)-0.5f)*0.6f, 1.1f + u(_rng)*0.9f);      // floats up
    h.age = 0; h.life = 1.5f + u(_rng)*0.9f;
    h.size = 0.34f + u(_rng)*0.22f;
    h.seed = u(_rng)*10.0f;
    _hearts.push_back(h);
}

// Empty the world of animals and nests (leaves the food and climate history),
// so you can start from nothing or hand-place critters with ADD.
- (void)clearColony {
    _critters.clear();
    _predators.clear();
    _nests.clear();
    _selected = 0;
}

// ----------------------------------------------------------------- Camera ---

- (void)clampPan {
    // Keep the view over the world: allowable pan grows with zoom, so at fit
    // zoom the center stays put and you can never drag the world off-screen.
    float rx = kWorldW * 0.5f * std::max(0.0f, 1.0f - 1.0f/_zoom);
    float ry = kWorldH * 0.5f * std::max(0.0f, 1.0f - 1.0f/_zoom);
    _panCenter.x = std::clamp(_panCenter.x, kWorldW*0.5f - rx, kWorldW*0.5f + rx);
    _panCenter.y = std::clamp(_panCenter.y, kWorldH*0.5f - ry, kWorldH*0.5f + ry);
}

// Zoom by factor f, keeping the world point under `ndc` fixed on screen.
- (void)zoomBy:(float)f atNdc:(simd_float2)ndc {
    if (_uScale.x == 0) { _zoom = std::clamp(_zoom * f, 1.0f, 8.0f); return; }
    float oldZoom = _zoom;
    _zoom = std::clamp(_zoom * f, 1.0f, 8.0f);
    simd_float2 scaleNew = _uScale * (_zoom / oldZoom);
    simd_float2 worldC = _panCenter + ndc / _uScale;      // world point under cursor
    _panCenter = worldC - ndc / scaleNew;                 // hold it there
    [self clampPan];
}

- (void)resetColony {
    _critters.clear();
    _food.clear();
    _predators.clear();
    _nests.clear();
    _ripples.clear();
    _bubbles.clear();
    _hearts.clear();
    _generation = 0;
    _births = _deaths = 0;
    _selected = 0;
    _worldTime = 0;
    _climate = 0;
    _climateTrend = 0;
    _sampleTimer = 0;
    _histCount = _histHead = 0;
    _foodTarget = 320;
    // A few water pools scattered around the world.
    _water.clear();
    std::uniform_real_distribution<float> ur(0,1);
    int nPools = 2 + (int)(ur(_rng) * 2.5f);   // 2..4
    for (int i = 0; i < nPools; i++) {
        Water wtr; wtr.pos = [self randomPos]; wtr.radius = 4.0f + 4.0f * ur(_rng);
        _water.push_back(wtr);
    }
    [self generateDecor];                       // ground cover (skips the ponds)
    for (int i = 0; i < _startPop; i++)
        [self spawnCritter:randomGenome(_rng, i % 2) at:[self randomPos] gen:0];
    [self scatterFood:220];
    if (_startPop > 0)
        for (int i = 0; i < 2; i++) [self spawnPredator:[self randomPos]];
    _initialPop = (int)_critters.size();
}

- (void)selectAt:(simd_float2)world {
    uint32_t best = 0; float bestD = 3.0f;
    for (const Critter &c : _critters) {
        if (!c.alive) continue;
        float d = simd_distance(c.pos, world);
        if (d < bestD) { bestD = d; best = c.id; }
    }
    _selected = best;
}

- (void)cullSelected {
    for (Critter &c : _critters)
        if (c.id == _selected && c.alive) { c.alive = false; _deaths++; }
}

- (Critter *)critterById:(uint32_t)cid {
    for (Critter &c : _critters) if (c.id == cid && c.alive) return &c;
    return nullptr;
}

// Index of the nest owned by `owner`, creating one at `pos` if she has none.
- (int)nestForOwner:(uint32_t)owner at:(simd_float2)pos {
    for (size_t i = 0; i < _nests.size(); i++)
        if (_nests[i].alive && _nests[i].owner == owner) return (int)i;
    if ((int)_nests.size() >= kMaxNests) return -1;
    // Keep nests off the water — nudge to the nearest dry shore if needed.
    for (const Water &wp : _water) {
        float d = simd_distance(pos, wp.pos);
        if (d < wp.radius + 1.2f) {
            simd_float2 dir = d > 1e-3f ? (pos - wp.pos) / d : simd_make_float2(1,0);
            pos = wp.pos + dir * (wp.radius + 1.5f);
        }
    }
    Nest n; n.pos = pos; n.owner = owner; n.quality = 0.12f; n.alive = true;
    _nests.push_back(n);
    return (int)_nests.size() - 1;
}

// -------------------------------------------------------------------- Sim ---

- (void)simStep:(float)dt {
    std::uniform_real_distribution<float> u(0,1);

    // Living headcount, cached once a step. Used for the hard birth cap (which
    // keeps the O(n^2) neighbour scans — and the machine — from bogging down) and
    // by the balance controller.
    _livingCount = [self livingCount];

    // --- climate: gentle seasons over a slowly wandering baseline ---
    _worldTime += dt;
    _climateTrend += (u(_rng) - 0.5f) * 0.03f * dt;      // slow random walk
    _climateTrend = std::clamp(_climateTrend, -0.75f, 0.75f);
    float season = sinf((float)_worldTime * (6.2831853f / kSeasonSecs));
    _climate = std::clamp(0.35f * season + _climateTrend, -1.0f, 1.0f);

    // --- day/night: advance the clock and derive the light level (toggleable) ---
    if (_dayNightOn) {
        _timeOfDay += dt / std::max(_dayLen, 8.0f);
        _timeOfDay -= floorf(_timeOfDay);                    // wrap 0..1
        float sun = -cosf(_timeOfDay * 6.2831853f);          // -1 midnight .. +1 noon
        _daylight = std::clamp(smoothstepf(-0.32f, 0.32f, sun), 0.0f, 1.0f);
        _skyWarm  = (1.0f - smoothstepf(0.0f, 0.42f, fabsf(sun))) * 0.85f;  // peaks at dawn/dusk
        // Crepuscular: most active at dawn & dusk, dozy at deep night, easy by day.
        _activity = std::clamp(0.35f + 0.65f * _daylight + 0.45f * _skyWarm, 0.35f, 1.25f);
    } else {
        _daylight = 1.0f; _skyWarm = 0.0f; _activity = 1.0f;   // permanent daylight
    }

    // --- weather: drift between clear, cloudy and rainy regimes; each element is
    //     gated by its HUD toggle so it can be switched off entirely ---
    _weatherTimer -= dt;
    if (_weatherTimer <= 0.0f) {
        float r = u(_rng);
        if (_rainOn && r < 0.32f)        { _cloudTarget = 0.75f + 0.25f*u(_rng); _rainTarget = 0.45f + 0.5f*u(_rng); } // rain
        else if (_cloudsOn && r < 0.68f) { _cloudTarget = 0.45f + 0.35f*u(_rng); _rainTarget = 0.0f; }   // cloudy
        else                             { _cloudTarget = 0.08f + 0.18f*u(_rng); _rainTarget = 0.0f; }   // clear
        _weatherTimer = 18.0f + 30.0f * u(_rng);
    }
    if (!_cloudsOn) _cloudTarget = 0.0f;                     // hard off-switches
    if (!_rainOn)   _rainTarget  = 0.0f;
    _cloud += (_cloudTarget - _cloud) * std::min(0.5f * dt, 1.0f);   // ease over ~2s
    _rain  += (_rainTarget  - _rain ) * std::min(0.4f * dt, 1.0f);

    [self autoAdjustStep:dt];       // colony auto-pilot (holds ~5%/min growth)

    // Food regrows / seeds slowly toward a carrying capacity.
    for (Food &f : _food) if (f.alive) f.growth = std::min(f.growth + 0.20f * dt, 1.0f);
    _foodTimer -= dt;
    if (_foodTimer <= 0 && (int)_food.size() < _foodTarget) {
        _foodTimer = 0.5f;
        [self scatterFood:3];
    }

    for (size_t i = 0; i < _critters.size(); i++) {
        Critter &c = _critters[i];
        if (!c.alive) {
            // Corpse: coast to a stop, then slowly rot away over kDecaySecs.
            c.vel *= std::max(0.0f, 1.0f - 5.0f * dt);
            c.pos += c.vel * dt;
            c.decay = std::min(c.decay + dt / kDecaySecs, 1.0f);
            continue;
        }
        if (c.grab > 0.0f) {
            // Seized in a predator's jaws: it can't flee or act — the predator
            // drives its position and the violent shake. Just count down the hold
            // (the predator refreshes it each frame) and struggle a little.
            c.grab = std::max(0.0f, c.grab - dt);
            c.vel = simd_make_float2(0,0);
            for (int s = 0; s < kSpineNodes; s++) c.spine[s] = c.pos;
            continue;
        }
        const Phenotype &ph = c.ph;

        // --- needs ---
        c.age += dt;
        c.hunger = std::min(c.hunger + ph.metabolism * 0.05f * dt, 1.5f);
        c.thirst = std::min(c.thirst + (0.014f + ph.metabolism*0.016f
                                        + std::max(_climate,0.0f)*0.02f)
                                       * (1.0f - 0.6f * _rain) * dt, 1.5f);   // rain keeps skin moist
        if (c.thirst > 1.2f) c.energy -= (c.thirst - 1.2f) * 0.10f * dt;   // dehydration
        float moving = simd_length(c.vel) / std::max(ph.speed, 0.1f);
        c.energy -= (0.01f + ph.metabolism * 0.012f + 0.02f * moving) * dt;
        if (c.hunger > 0.9f) c.energy -= (c.hunger - 0.9f) * 0.15f * dt;   // starving
        // Thermal stress: bodies ill-matched to the climate burn extra energy,
        // so they forage harder, breed less, and die younger — selection that
        // pushes the colony's size and coloration to track the environment.
        float adapt = adaptation(ph, _climate);
        c.energy -= (1.0f - adapt) * kThermalCost * dt;
        // Parental care: after a birth both parents spend a long stretch raising
        // the young before the urge to breed rebuilds — the spec's "reproduce
        // slowly and invest heavily in each offspring."
        if (c.care > 0.0f) c.care = std::max(0.0f, c.care - dt);
        if (c.age > c.maturity && c.energy > 0.40f && !c.pregnant && c.care <= 0.0f)
            c.urge = std::min(c.urge + ph.fertility * (0.5f + 0.7f * adapt)
                                       * 0.075f * _birthRate * dt, 1.0f);

        // --- sickness ---
        if (c.sick > 0) {
            c.sick = std::min(c.sick + (0.12f - ph.resistance * 0.10f) * dt, 1.0f);
            c.health -= c.sick * 0.10f * dt;
            c.energy -= c.sick * 0.03f * dt;
            if (u(_rng) < ph.resistance * 0.4f * dt) c.sick = std::max(c.sick - 0.3f, 0.0f);
            if (c.sick <= 0.01f) c.sick = 0;
        }
        c.health = std::min(c.health + 0.02f * dt, 1.0f);

        // --- death ---
        if (c.age > ph.lifespan * _lifespanMul || c.energy <= 0 || c.health <= 0) {
            c.alive = false; _deaths++;
            if (c.id == _selected) _selected = 0;
            continue;
        }

        // --- nest shelter status (cover from predators) ---
        c.sheltered = false;
        for (const Nest &nst : _nests)
            if (nst.alive && simd_distance(nst.pos, c.pos) < kNestRadius) { c.sheltered = true; break; }

        // --- detect predators (sharper-eyed critters see them sooner) ---
        simd_float2 threatDir = simd_make_float2(0,0);
        float threatLvl = 0.0f;
        for (const Predator &pr : _predators) {
            if (!pr.alive) continue;
            float dd = simd_distance(pr.pos, c.pos);
            if (dd < ph.sensory) {
                float near = 1.0f - dd / ph.sensory;
                if (near > threatLvl) { threatLvl = near; threatDir = c.pos - pr.pos; }
            }
        }

        // --- colony sense: local cohesion centroid + the nearest elder to trail ---
        // Bubble Burrowers stay close as an extended family and let experienced
        // elders lead. One neighbour scan feeds both the cohesion drive and the
        // "follow an elder" steering below.
        simd_float2 flockSum = simd_make_float2(0,0);
        int flockN = 0;
        simd_float2 elderPos = c.pos; float elderBest = kElderRange; bool haveElder = false;
        simd_float2 playmate = c.pos; float playBest = kColonyRange; bool havePlaymate = false;
        simd_float2 sepForce = simd_make_float2(0,0);       // push away from crowding neighbours
        for (const Critter &o : _critters) {
            if (!o.alive || o.id == c.id) continue;
            float dd = simd_distance(o.pos, c.pos);
            if (dd < kColonyRange) { flockSum += o.pos; flockN++; }
            // Personal space: they walk AROUND each other, never through. Sum the
            // actual overlap (in world units) with each too-close neighbour so it
            // can be pushed out hard below. `space` a touch over the drawn body
            // radius (~0.9*size each) so there's a hair of gap, not overlap. A
            // courting pair is exempt so they can actually reach each other.
            bool courting = (c.targetMate == o.id) || (o.targetMate == c.id);
            float space = (c.ph.size + o.ph.size) * 0.98f;
            if (!courting && dd < space) {
                simd_float2 away = dd > 1e-3f ? (c.pos - o.pos)/dd
                                              : simd_make_float2(cosf((float)o.id), sinf((float)o.id));
                sepForce += away * (space - dd);        // world-unit overlap
            }
            float oAgeT = o.ph.lifespan > 0 ? o.age / (o.ph.lifespan * _lifespanMul) : 0.0f;
            if (oAgeT > kElderFrac && dd < elderBest) { elderBest = dd; elderPos = o.pos; haveElder = true; }
            if (dd < playBest && dd > 1.0f) { playBest = dd; playmate = o.pos; havePlaymate = true; }
        }
        simd_float2 flockCentroid = flockN > 0 ? flockSum / (float)flockN : c.pos;
        float ageTnow = std::clamp(c.age / (ph.lifespan * _lifespanMul), 0.0f, 1.0f);
        bool isElder = ageTnow > kElderFrac;
        bool isJuvenile = c.age <= c.maturity;

        // --- utility AI: score the drives, weighted by this critter's own
        // heritable temperament, then pick the most pressing. Because the weights
        // come from its genes, two critters in the same situation can choose
        // differently — so the colony stops behaving as one. ---
        float bold = ph.boldness, curi = ph.curiosity, act = ph.activity;
        float sForage = c.hunger;
        // Rest / doze — lazy (low-activity) ones rest more; everyone dozes at night.
        float sRest = ((1.0f - c.energy) * 0.9f + (1.0f - _daylight) * 0.40f) * (1.3f - 0.6f*act);
        // Breeding is a strong drive once the urge is up.
        float sMate = (c.age > c.maturity && c.energy > 0.40f && !c.pregnant && c.care <= 0.0f)
                      ? c.urge * 1.5f : 0.0f;
        // Idle roaming — curious critters explore more; the incurious loiter.
        float sWander = 0.08f + 0.32f * curi;
        // Flee — timid critters bolt early and hard; bold ones tolerate a threat.
        float sFlee = threatLvl * (1.3f + 1.5f * (1.0f - bold));
        float sNest = c.pregnant ? 0.8f : 0.0f;      // expectant mothers nest
        // Thirst, sharpened in the heat (they seek water sooner when it's hot).
        float thirstUrg = std::max(0.0f, c.thirst - 0.45f + std::max(_climate,0.0f)*0.2f);
        float sDrink = _water.empty() ? 0.0f : thirstUrg * 2.2f;
        // Hunker-and-hide — the BOLD response to a moderate threat (hold & camo),
        // where the timid would rather run (juveniles hide sooner).
        float sHunker = (threatLvl > 0.12f && threatLvl < 0.65f)
                        ? threatLvl * (0.8f + 1.6f*bold + (isJuvenile ? 0.5f : 0.0f)) : 0.0f;
        // Play — for the curious/playful, when life is easy.
        bool easy = threatLvl < 0.02f && c.hunger < 0.4f && c.thirst < 0.5f
                    && c.energy > 0.65f && c.health > 0.7f && havePlaymate
                    && c.urge < 0.4f                         // breeders don't dawdle
                    && _rain < 0.25f && _daylight > 0.25f;   // fair weather, not deep night
        float sPlay = easy ? (0.22f + 0.5f*curi) * (isJuvenile ? 1.3f : 1.0f) : 0.0f;
        // Anti-dither: keep a small bias toward what it's already doing, so it
        // commits to a course instead of flip-flopping every frame.
        int prev = c.action;
        const float stick = 0.13f;
        c.action = AWander; float best = sWander + (prev == AWander ? stick : 0.0f);
        auto consider = [&](float s, int a){ float v = s + (prev==a?stick:0.0f);
                                             if (v > best) { best = v; c.action = a; } };
        consider(sForage, AForage); consider(sDrink, ADrink); consider(sRest, ARest);
        consider(sPlay, APlay);     consider(sMate, AMate);   consider(sNest, ANest);
        consider(sHunker, AHunker); consider(sFlee, AFlee);

        // --- act ---
        simd_float2 desire = simd_make_float2(0,0);
        float wantSpeed = ph.speed;
        if (c.action == AFlee) {
            desire = (simd_length(threatDir) > 1e-3f) ? simd_normalize(threatDir)
                        : simd_make_float2(cosf(c.heading), sinf(c.heading));
            wantSpeed = ph.speed * 1.6f;      // panic sprint
            c.energy -= 0.02f * dt;           // burns energy
        } else if (c.action == AForage) {
            int fi = c.targetFood;
            if (fi < 0 || fi >= (int)_food.size() || !_food[fi].alive) {
                fi = -1; float bd = ph.sensory;
                for (int k = 0; k < (int)_food.size(); k++) {
                    if (!_food[k].alive || _food[k].growth < 0.4f) continue;
                    float dd = simd_distance(_food[k].pos, c.pos);
                    if (dd < bd) { bd = dd; fi = k; }
                }
                c.targetFood = fi;
            }
            if (fi >= 0) {
                simd_float2 to = _food[fi].pos - c.pos;
                float dd = simd_length(to);
                if (dd < 1.0f + ph.size * 0.5f) {          // eat
                    c.hunger = std::max(c.hunger - _food[fi].growth * 0.9f, 0.0f);
                    c.energy = std::min(c.energy + _food[fi].growth * 0.7f, 1.0f);
                    _food[fi].alive = false;
                    c.targetFood = -1;
                } else desire = to / std::max(dd, 1e-3f);
            } else {   // wander to search
                c.heading += (u(_rng) - 0.5f) * 2.0f * dt;
                desire = simd_make_float2(cosf(c.heading), sinf(c.heading));
                wantSpeed *= 0.6f;
            }
        } else if (c.action == ARest) {
            wantSpeed = 0.0f;
            c.energy = std::min(c.energy + 0.06f * dt, 1.0f);
        } else if (c.action == AMate) {
            Critter *mate = [self critterById:c.targetMate];
            bool ok = mate && mate->male != c.male && mate->age > mate->maturity;
            if (!ok) {
                c.targetMate = 0;
                // Pair fidelity: a bonded partner is preferred above all else —
                // pairs stay together across seasons, often for life.
                if (c.partner != 0) {
                    Critter *p = [self critterById:c.partner];
                    if (p && p->alive && p->male != c.male && p->age > p->maturity
                        && simd_distance(p->pos, c.pos) < ph.sensory * 1.5f)
                        c.targetMate = p->id;
                }
                if (c.targetMate == 0 && !c.male) {
                    // Female choice: pick the showiest male within sight (weighted
                    // toward nearer ones). Sexual selection on ornament genes.
                    float bestScore = 0.0f;
                    for (Critter &o : _critters) {
                        if (!o.alive || o.male == c.male) continue;
                        if (o.age <= o.maturity || o.energy < 0.4f) continue;
                        float dd = simd_distance(o.pos, c.pos);
                        if (dd > ph.sensory) continue;
                        float score = ornament(o) * (1.0f - 0.5f * dd / ph.sensory);
                        if (score > bestScore) { bestScore = score; c.targetMate = o.id; }
                    }
                } else if (c.targetMate == 0) {
                    // Males court the nearest receptive female.
                    float bd = ph.sensory;
                    for (Critter &o : _critters) {
                        if (!o.alive || o.male == c.male) continue;
                        if (o.age <= o.maturity || o.energy < 0.4f) continue;
                        float dd = simd_distance(o.pos, c.pos);
                        if (dd < bd) { bd = dd; c.targetMate = o.id; }
                    }
                }
                mate = [self critterById:c.targetMate];
            }
            if (mate) {
                simd_float2 to = mate->pos - c.pos;
                float dd = simd_length(to);
                if (dd < 1.4f + ph.size) {
                    // Conception: the female carries the offspring.
                    Critter *mom = c.male ? mate : &c;
                    Critter *dad = c.male ? &c : mate;
                    if (!mom->pregnant && mom->urge > 0.4f && dad->urge > 0.3f
                        && _livingCount < kLiveCap) {          // no new pregnancies at the cap
                        mom->unborn = breed(mom->genome, dad->genome, _rng);
                        mom->mateGenome = dad->genome;   // for litter-mate meiosis
                        mom->pregnant = true;
                        mom->gestation = 5.0f;
                        mom->urge = 0; dad->urge = 0;
                        mom->energy -= 0.08f; dad->energy -= 0.04f;
                        // Bond the pair for future seasons. Only the mother takes a
                        // nursing cooldown (set at birth, and shorter at higher
                        // birth-rate settings); fathers stay in the mating pool so
                        // the colony can actually grow.
                        mom->partner = dad->id; dad->partner = mom->id;
                        // A little burst of glowing hearts on conception.
                        simd_float2 mid = (mom->pos + dad->pos) * 0.5f;
                        for (int hb = 0; hb < 6; hb++) [self emitHeart:mid];
                    }
                } else desire = to / std::max(dd, 1e-3f);
            } else { wantSpeed *= 0.6f; desire = simd_make_float2(cosf(c.heading), sinf(c.heading)); }
        } else if (c.action == ANest) {
            // Expectant mother: head to her nest (build a new one if she has
            // none) and tend it — a better nest gives her pups a head start.
            int ni = [self nestForOwner:c.id at:c.pos];
            if (ni >= 0) {
                Nest &nst = _nests[ni];
                simd_float2 to = nst.pos - c.pos;
                float dd = simd_length(to);
                if (dd < kNestRadius * 0.5f) {
                    nst.quality = std::min(nst.quality + 0.06f * dt, 1.0f);
                    wantSpeed = 0.0f;
                    c.energy = std::min(c.energy + 0.03f * dt, 1.0f);
                } else desire = to / std::max(dd, 1e-3f);
            } else { wantSpeed *= 0.5f; desire = simd_make_float2(cosf(c.heading), sinf(c.heading)); }
        } else if (c.action == ADrink) {
            // Head to the nearest pool and drink at its shore.
            int wi = -1; float bd = 1e9f;
            for (int k = 0; k < (int)_water.size(); k++) {
                float dd = simd_distance(_water[k].pos, c.pos);
                if (dd < bd) { bd = dd; wi = k; }
            }
            if (wi >= 0) {
                simd_float2 to = _water[wi].pos - c.pos;
                float dd = simd_length(to);
                if (dd < _water[wi].radius + 0.8f) {       // drinking
                    c.thirst = std::max(c.thirst - 1.2f * dt, 0.0f);
                    wantSpeed = 0.0f;
                } else desire = to / std::max(dd, 1e-3f);
            } else { wantSpeed *= 0.5f; desire = simd_make_float2(cosf(c.heading), sinf(c.heading)); }
        } else if (c.action == AHunker) {
            // Freeze low and let the chromatophores do the work — the spec's
            // startle response: stop, hunker, and blend into the surroundings.
            wantSpeed = 0.0f;
            c.energy = std::min(c.energy + 0.01f * dt, 1.0f);
        } else if (c.action == APlay) {
            // Playful bout: dart around a nearby companion (chase / short races),
            // blowing bubbles. Frisky, quick direction changes, never far.
            simd_float2 to = playmate - c.pos;
            float dd = simd_length(to);
            if (dd > 2.2f) desire = to / std::max(dd, 1e-3f);
            else {
                // circle and juke around the playmate
                simd_float2 tang = simd_make_float2(-to.y, to.x);
                float wob = sinf(c.phase * 1.7f + (float)(c.id % 61));
                desire = simd_normalize(tang * wob + to * 0.3f);
            }
            wantSpeed = ph.speed * (0.7f + 0.5f * fabsf(sinf(c.phase * 2.0f)));
            [self emitBubble:c strength:0.6f dt:dt];
        } else {  // wander — head toward a chosen destination, not random jitter
            // Pick a fresh goal when the old one is reached or its time is up. The
            // spot reflects temperament: curious/bold ones strike out far and to
            // the edges; homebodies (sociable) pick spots near the colony.
            c.retarget -= dt;
            if (c.retarget <= 0.0f || simd_distance(c.pos, c.goal) < 3.0f) {
                float roam = 6.0f + 46.0f * ph.curiosity * (0.4f + 0.6f*ph.boldness);
                float ang = u(_rng) * 6.2831853f;
                simd_float2 anchor = (ph.sociability > 0.55f && flockN > 0) ? flockCentroid : c.pos;
                c.goal = anchor + simd_make_float2(cosf(ang), sinf(ang)) * (roam * (0.3f + 0.7f*u(_rng)));
                c.goal.x = std::clamp(c.goal.x, 2.0f, kWorldW - 2.0f);
                c.goal.y = std::clamp(c.goal.y, 2.0f, kWorldH - 2.0f);
                c.retarget = 3.0f + 6.0f * u(_rng);
            }
            simd_float2 toGoal = c.goal - c.pos;
            float gd = simd_length(toGoal);
            simd_float2 head = gd > 0.5f ? toGoal / gd : simd_make_float2(cosf(c.heading), sinf(c.heading));
            // Cohesion + elder-following, weighted by how sociable this one is
            // (loners barely clump; sociable ones stick close and trail elders).
            simd_float2 toFlock = flockCentroid - c.pos;
            float fd = simd_length(toFlock);
            simd_float2 cohere = (flockN > 0 && fd > 3.0f) ? toFlock / fd : simd_make_float2(0,0);
            simd_float2 lead = simd_make_float2(0,0);
            if (!isElder && haveElder) {
                simd_float2 toElder = elderPos - c.pos;
                float ed = simd_length(toElder);
                if (ed > 2.5f) lead = toElder / ed;
            }
            desire = simd_normalize(head * 0.8f + cohere * (0.25f + 0.9f*ph.sociability)
                                    + lead * (0.25f + 0.7f*ph.sociability) + simd_make_float2(1e-4f, 0));
            wantSpeed *= (isElder ? 0.42f : 0.5f) * (0.75f + 0.5f*ph.activity);  // busy ones step livelier
        }

        // --- steer + integrate (the old move slower) ---
        float ageT = std::clamp(c.age / (ph.lifespan * _lifespanMul), 0.0f, 1.0f);
        float ageSlow = 1.0f - 0.45f * std::clamp((ageT - 0.5f) / 0.5f, 0.0f, 1.0f);
        // Crepuscular pacing: sprightly at dawn/dusk, dozy through the night.
        // Fleeing ignores it — panic overrides the time of day.
        float actMul = (c.action == AFlee) ? 1.0f : (0.55f + 0.45f * _activity);
        // Fin-stroke gait: they scull forward in pulses and glide between, so
        // their pace rises and falls with each paddle instead of holding a
        // constant speed — the deep glides read as the spec's curious pauses.
        // Fleeing is a smooth, steady sprint (no pulsing).
        float stroke = powf(std::max(0.0f, sinf(c.phase)), 1.4f);   // 0 glide .. 1 power stroke
        bool ambling = (c.action == AWander || c.action == APlay);
        float glideFloor = ambling ? 0.15f : 0.45f;                 // idle roaming pauses deeper than errands
        float gait = (c.action == AFlee) ? 1.0f : (glideFloor + (1.3f - glideFloor) * stroke);
        // Steer to walk around neighbours (blend the separation direction into the
        // heading so they anticipate and go around).
        float sepLen = simd_length(sepForce);
        simd_float2 steer = (simd_length(desire) > 1e-3f) ? simd_normalize(desire) : simd_make_float2(0,0);
        if (sepLen > 1e-4f) steer += (sepForce / sepLen) * 1.3f;
        // Sleep: when it settles to rest — dozing through the night or worn out —
        // it drifts off, coming to a complete stop with its eyes shut. Eases in and
        // out over ~2s. (Woken by anything more urgent than resting.)
        float mvNow = simd_length(c.vel) / std::max(ph.speed, 0.1f);
        bool wantSleep = (c.action == ARest) && mvNow < 0.30f && threatLvl < 0.05f
                       && ((1.0f - _daylight) > 0.35f || c.energy < 0.45f);
        float wakeRate = wantSleep ? 0.5f : (threatLvl > 0.1f ? 5.0f : 0.5f);  // startle → snap awake
        c.rest += ((wantSleep ? 1.0f : 0.0f) - c.rest) * std::min(wakeRate * dt, 1.0f);
        bool asleep = c.rest > 0.5f;

        // Aquarium: languid and buoyant — slower top speed and much more coast, so
        // they glide and hover instead of scurrying.
        float envSpeed = _aquarium ? 0.60f : 1.0f;
        float velK     = _aquarium ? 2.6f  : 6.0f;    // lower = more glide/coast
        simd_float2 wantVel = (!asleep && simd_length(steer) > 1e-3f)
            ? simd_normalize(steer) * wantSpeed * ageSlow * actMul * gait * envSpeed : simd_make_float2(0,0);
        c.vel += (wantVel - c.vel) * std::min((asleep ? 5.0f : velK) * dt, 1.0f);
        if (simd_length(c.vel) > 0.05f) c.heading = atan2f(c.vel.y, c.vel.x);
        c.pos += c.vel * dt;
        if (_aquarium && !asleep) {
            // buoyant hover (a slow personal drift so they never truly freeze) plus
            // a gentle, slowly-swirling tank current the whole colony rides.
            float ib = (float)(c.id % 251);
            c.pos += simd_make_float2(sinf((float)_worldTime*0.5f + ib),
                                      cosf((float)_worldTime*0.4f + ib*1.7f)) * 0.10f * dt;
            c.pos += simd_make_float2(sinf((float)_worldTime*0.13f),
                                      sinf((float)_worldTime*0.10f + 1.3f)) * 0.18f * dt;
        }
        // Firm overlap resolution: shove out by half the total overlap this frame
        // (both critters do it → the full overlap clears), capped so it never
        // teleports. Guarantees bodies don't sit on top of one another.
        if (sepLen > 1e-4f) {
            simd_float2 push = sepForce * 0.5f;
            float pl = simd_length(push);
            if (pl > 0.7f) push *= 0.7f / pl;
            c.pos += push;
        }
        // sickness saps mobility
        if (c.sick > 0) c.pos -= c.vel * dt * c.sick * 0.5f;
        c.pos.x = std::clamp(c.pos.x, 1.0f, kWorldW - 1.0f);
        c.pos.y = std::clamp(c.pos.y, 1.0f, kWorldH - 1.0f);
        [self waterRippleAt:c.pos vel:c.vel dt:dt];
        // Step clock: slow when idling, clearly quicker the faster they move, so
        // the footwork paces with them (a gentle amble vs. a scurrying flee).
        c.phase += (1.4f + 0.75f * simd_length(c.vel)) * dt;

        // --- camouflage: chromatophores ease toward the ground when the animal
        // holds still, and wash back out once it moves (the spec's 5–15s shift) ---
        float moveFrac = simd_length(c.vel) / std::max(ph.speed, 0.1f);
        bool hiding = (c.action == AHunker || c.action == ARest || moveFrac < 0.12f);
        float camoTarget = hiding ? 1.0f : 0.0f;
        c.camo += (camoTarget - c.camo) * std::min(kCamoRate * dt, 1.0f);

        // --- bubbles: blown near water ("bubble sounds while near water") and in
        // courtship displays when close to a mate ---
        for (const Water &wp : _water)
            if (simd_distance(c.pos, wp.pos) < wp.radius + 1.2f) { [self emitBubble:c strength:0.5f dt:dt]; break; }
        if (c.action == AMate && c.targetMate != 0) {
            Critter *mt = [self critterById:c.targetMate];
            if (mt && simd_distance(mt->pos, c.pos) < 3.0f) {
                [self emitBubble:c strength:0.8f dt:dt];
                if (u(_rng) < 1.2f * dt)                                            // wooing hearts
                    [self emitHeart:c.pos + simd_make_float2(cosf(c.heading),sinf(c.heading))*0.5f*ph.size];
            }
        }

        // --- Verlet spine follows the head (elongated bodies stretch it) ---
        c.spine[0] = c.pos;
        float link = 0.40f * ph.size * (0.75f + 0.7f * ph.aspect);
        for (int s = 1; s < kSpineNodes; s++) {
            simd_float2 dir = c.spine[s] - c.spine[s-1];
            float dl = simd_length(dir);
            if (dl > 1e-4f) c.spine[s] = c.spine[s-1] + dir / dl * link;
            // lateral slither offset
            simd_float2 perp = simd_make_float2(-sinf(c.heading), cosf(c.heading));
            c.spine[s] += perp * sinf(c.phase - s * 0.9f) * 0.06f * ph.size
                        * simd_length(c.vel) / std::max(ph.speed,1.0f);
        }

        // --- gestation / birth (at the nest, with a quality-scaled head start) ---
        if (c.pregnant) {
            c.gestation -= dt;
            if (c.gestation <= 0) {
                int gen = c.generation + 1;
                simd_float2 bpos = c.pos;
                float bonus = 0.0f;
                int ni = [self nestForOwner:c.id at:c.pos];
                if (ni >= 0) { bpos = _nests[ni].pos; bonus = 0.20f * _nests[ni].quality; }
                // One or two fully-formed live young — the Bubble Burrower invests
                // heavily in a tiny brood. Twins are the exception, made likelier by
                // good condition and the caretaker's fecundity (birth-rate) setting.
                float twinChance = std::clamp(0.10f + 0.30f * (_birthRate - 1.0f)
                                              + 0.25f * (c.ph.fertility - 0.8f) * c.energy, 0.02f, 0.85f);
                int litter = (u(_rng) < twinChance) ? 2 : 1;
                for (int L = 0; L < litter && _livingCount < kLiveCap; L++) {   // hard cap
                    Genome kid = (L == 0) ? c.unborn
                                          : breed(c.genome, c.mateGenome, _rng);  // distinct sibling
                    size_t before = _critters.size();
                    [self spawnCritter:kid
                                    at:(bpos + simd_make_float2(u(_rng)-0.5f, u(_rng)-0.5f)) gen:gen];
                    if (_critters.size() > before) {
                        _critters.back().energy = std::min(_critters.back().energy + bonus, 1.0f);
                        _births++; _livingCount++;
                    }
                }
                _generation = std::max(_generation, gen);
                c.pregnant = false;
                // Nursing cooldown before the mother breeds again — long when the
                // caretaker keeps the birth rate low (the spec's heavy investment),
                // short when they crank it up so the colony grows quickly.
                c.care = kCareSecs / std::max(_birthRate, 0.5f);
                c.energy = std::min(c.energy + 0.10f, 1.0f);
            }
        }
    }

    // --- nests decay when untended; remove the empty ones ---
    for (Nest &nst : _nests) if (nst.alive) {
        nst.quality -= 0.012f * dt;
        if (nst.quality <= 0.0f) nst.alive = false;
    }
    _nests.erase(std::remove_if(_nests.begin(), _nests.end(),
                 [](const Nest &n){ return !n.alive; }), _nests.end());

    // --- age water ripples and drop the faded ones ---
    for (Ripple &rp : _ripples) rp.age += dt;
    _ripples.erase(std::remove_if(_ripples.begin(), _ripples.end(),
                   [](const Ripple &rp){ return rp.age >= rp.life; }), _ripples.end());

    // --- bubbles rise, wobble, and pop ---
    for (Bubble &b : _bubbles) {
        b.age += dt;
        b.vel.y += 0.35f * dt;                                   // buoyant acceleration
        b.vel.x += sinf(b.age * 5.0f + b.seed) * 0.5f * dt;      // gentle wobble
        b.pos += b.vel * dt;
    }
    _bubbles.erase(std::remove_if(_bubbles.begin(), _bubbles.end(),
                   [](const Bubble &b){ return b.age >= b.life; }), _bubbles.end());

    // --- hearts float up and gently sway, then fade ---
    for (Bubble &h : _hearts) {
        h.age += dt;
        h.vel.x += sinf(h.age * 3.5f + h.seed) * 0.5f * dt;         // sway
        h.vel.y += 0.15f * dt;                                      // buoyant rise
        h.pos += h.vel * dt;
    }
    _hearts.erase(std::remove_if(_hearts.begin(), _hearts.end(),
                  [](const Bubble &h){ return h.age >= h.life; }), _hearts.end());

    // --- predators: coordinated pack hunting ---
    float groundLuma = 0.24f + 0.06f * _climate;   // grass tone by climate
    int NP = (int)_predators.size();

    // 1) Coalesce hunters that are close into a shared pack (a few relaxation
    //    passes merge chains so a loose group converges on one pack id).
    for (int pass = 0; pass < 3; pass++)
        for (int a = 0; a < NP; a++) {
            if (!_predators[a].alive) continue;
            for (int b = a+1; b < NP; b++) {
                if (!_predators[b].alive) continue;
                if (simd_distance(_predators[a].pos, _predators[b].pos) < kPackRange) {
                    uint32_t m = std::min(_predators[a].pack, _predators[b].pack);
                    _predators[a].pack = m; _predators[b].pack = m;
                }
            }
        }
    // 2) Colony centroid — prey far from it are exposed stragglers.
    simd_float2 colonyC = simd_make_float2(0,0); int colonyN = 0;
    for (const Critter &o : _critters) if (o.alive) { colonyC += o.pos; colonyN++; }
    if (colonyN > 0) colonyC /= (float)colonyN;
    // 3) Per-pack centroid and size.
    std::vector<uint32_t> packId; std::vector<simd_float2> packC; std::vector<int> packN;
    auto packSlot = [&](uint32_t id)->int {
        for (int k = 0; k < (int)packId.size(); k++) if (packId[k]==id) return k;
        packId.push_back(id); packC.push_back(simd_make_float2(0,0)); packN.push_back(0);
        return (int)packId.size()-1;
    };
    for (int a = 0; a < NP; a++) if (_predators[a].alive) {
        int k = packSlot(_predators[a].pack); packC[k] += _predators[a].pos; packN[k]++;
    }
    for (int k = 0; k < (int)packC.size(); k++) packC[k] /= (float)std::max(packN[k],1);
    // 4) Each pack focus-fires ONE quarry: near the pack and vulnerable (young,
    //    slow, sick, exhausted, frail, or isolated from the herd). Camouflaged
    //    coats stay hard to detect; a bigger pack coordinates over a wider net.
    std::vector<uint32_t> packTarget(packId.size(), 0);
    std::vector<float> packScore(packId.size(), 1e9f);
    for (Critter &o : _critters) {
        if (!o.alive) continue;
        float contrast = fabsf(coatLuma(o.ph.color) - groundLuma);
        float visRange = 22.0f * (0.35f + 1.3f * std::clamp(contrast,0.0f,1.0f)
                                  + 0.5f * coatVividness(o.ph.color));
        if (o.sheltered) visRange *= 0.55f;
        float ageT = o.ph.lifespan > 0 ? o.age/(o.ph.lifespan*_lifespanMul) : 0.0f;
        float isolation = colonyN > 0 ? simd_distance(o.pos, colonyC) : 0.0f;
        float weak = (o.age <= o.maturity ? 0.5f : 0.0f)                       // juveniles
                   + (1.0f - o.health) * 0.4f + o.sick * 0.3f                  // sick / hurt
                   + std::clamp(0.5f - o.energy, 0.0f, 0.5f)                   // exhausted
                   + std::clamp((10.0f - o.ph.speed)/10.0f, 0.0f, 0.4f)        // slow
                   + (ageT > kElderFrac ? 0.3f : 0.0f);                        // frail elders
        float vuln = 1.0f + weak + std::clamp(isolation*0.05f, 0.0f, 1.2f);
        for (int k = 0; k < (int)packId.size(); k++) {
            float d = simd_distance(o.pos, packC[k]);
            float packSight = visRange + 4.0f * sqrtf((float)packN[k]);
            if (d > packSight) continue;
            float cost = d / vuln;                    // near + vulnerable → chosen
            if (cost < packScore[k]) { packScore[k] = cost; packTarget[k] = o.id; }
        }
    }
    // 5) Broadcast the pack's quarry to every member (shared sightings = the
    //    pack sees as one), so members converge even if they can't see it alone.
    for (int a = 0; a < NP; a++) if (_predators[a].alive)
        _predators[a].targetPrey = packTarget[packSlot(_predators[a].pack)];
    // 6) Give each hunter a stable index within its pack, so roles can be handed
    //    out deterministically (a driver, flankers on each side, an ambusher)
    //    and members actively take up distinct positions instead of all reacting
    //    to wherever they happen to be.
    std::vector<int> memberIdx(NP, 0);
    {
        std::vector<int> counter(packId.size(), 0);
        for (int a = 0; a < NP; a++) if (_predators[a].alive) {
            int k = packSlot(_predators[a].pack);
            memberIdx[a] = counter[k]++;
        }
    }

    for (size_t i = 0; i < _predators.size(); i++) {
        Predator &p = _predators[i];
        if (!p.alive) continue;
        p.age += dt;
        p.cooldown = std::max(p.cooldown - dt, 0.0f);
        p.energy -= 0.022f * dt;                    // metabolism
        if (p.age > p.lifespan || p.energy <= 0.0f) {
            [self stopCry:p.cryVoice];               // don't leave a cry ringing if it dies mid-meal
            p.alive = false; continue;
        }

        Critter *prey = [self critterById:p.targetPrey];

        simd_float2 desire = simd_make_float2(0,0);
        float wantSpeed = 8.6f;                      // fast prey can outrun it
        float wt = (float)_worldTime;
        if (p.feedT > 0.0f) {
            // FEEDING: the prey is caught. Clamp it in the jaws, thrash it side to
            // side, then swallow it. The hunter plants itself and whips its head.
            p.feedT -= dt;
            simd_float2 fwd = simd_make_float2(cosf(p.heading), sinf(p.heading));
            simd_float2 perp = simd_make_float2(-fwd.y, fwd.x);
            float whip = sinf(wt * 34.0f) * (0.6f + 0.4f * sinf(wt * 6.0f));  // violent shake
            if (prey) {
                prey->pos = p.pos + fwd*(p.size*0.55f) + perp*whip*(0.42f*p.size);
                prey->vel = simd_make_float2(0,0);
                prey->heading = p.heading + whip*0.6f;
                prey->grab = 0.2f;                    // stays seized (refreshed each frame)
            }
            p.pos += perp * whip * 0.05f * p.size;    // hunter recoils with the shake
            wantSpeed = 0.0f;
            if (p.feedT <= 0.0f) {                    // swallow — the prey is consumed
                if (prey) {
                    prey->alive = false; _deaths++;
                    prey->decay = 1.0f;               // eaten: gone, not a lingering corpse
                    prey->grab = 0.0f;
                    if (prey->id == _selected) _selected = 0;
                }
                p.energy = std::min(p.energy + 0.5f, 1.4f);
                p.cooldown = 1.6f;
                p.targetPrey = 0;
                [self stopCry:p.cryVoice]; p.cryVoice = -1;   // silence the cry — prey is gone
                // Turn back toward open ground so it doesn't sit facing the wall.
                simd_float2 toCenter = simd_make_float2(kWorldW*0.5f, kWorldH*0.5f) - p.pos;
                float cdist = simd_length(toCenter);
                if (cdist > 1e-3f) {
                    p.heading = atan2f(toCenter.y, toCenter.x);
                    p.vel = toCenter / cdist * 3.0f;        // a shove off the corner
                }
            }
        } else if (prey) {
            // Predict the prey's escape and take an ASSIGNED role in the pack.
            simd_float2 pv = prey->vel;
            float ps = simd_length(pv);
            simd_float2 fleeDir = ps > 0.4f ? pv/ps
                                : simd_make_float2(cosf(prey->heading), sinf(prey->heading));
            simd_float2 r = p.pos - prey->pos;       // quarry -> hunter
            float rd = simd_length(r);
            // Deterministic role from the hunter's index in its pack, so members
            // actively spread — a driver behind, flankers on each side, an
            // ambusher ahead — instead of all charging from wherever they are.
            int cnt = packN[packSlot(p.pack)];
            int idx = (i < (size_t)NP) ? memberIdx[i] : 0;
            if (cnt <= 1)        p.role = PR_Chaser;          // a lone hunter just chases
            else if (idx == 0)   p.role = PR_Chaser;          // driver: pushes from behind
            else if (idx == 1)   p.role = PR_FlankL;          // cut off the left
            else if (idx == 2)   p.role = PR_FlankR;          // cut off the right
            else if (idx == 3)   p.role = PR_Ambush;          // wait ahead on the escape line
            else                 p.role = (idx % 2) ? PR_FlankL : PR_FlankR;  // extra flankers

            float catchR = 0.9f + p.size * 0.3f + prey->ph.size * 0.3f;
            if (rd < catchR) {
                if (p.cooldown <= 0.0f) {             // seize it and start biting
                    p.feedT = kFeedSecs;
                    prey->grab = 0.2f;
                    wantSpeed = 0.0f;
                    p.cryVoice = [self playCry];      // the prey's distress cry (cut off on consume)
                }
            } else {
                float lead = std::clamp(rd / 12.0f, 0.0f, 2.0f);
                simd_float2 future = prey->pos + pv * lead;
                simd_float2 perp = simd_make_float2(-fleeDir.y, fleeDir.x);
                float encircle = 3.5f + prey->ph.size;
                simd_float2 aim;
                if (p.role == PR_Chaser) {
                    aim = future;                                                    // driver: press from behind
                } else if (p.role == PR_Ambush) {
                    aim = prey->pos + fleeDir*(rd*0.7f + 4.0f);                       // race to the escape line
                } else {
                    // Flankers cut it off: aim AHEAD of the prey and off to a side,
                    // so they swing around and close the exits rather than trailing.
                    float s = (p.role == PR_FlankL) ? 1.0f : -1.0f;
                    aim = prey->pos + fleeDir*(rd*0.45f + 2.0f) + perp*s*encircle;
                }
                simd_float2 to = aim - p.pos;
                float d2 = simd_length(to);
                desire = d2 > 1e-3f ? to/d2 : fleeDir;
                if (p.role == PR_FlankL || p.role == PR_FlankR) wantSpeed = 9.8f;    // hustle to get around
                else if (p.role == PR_Ambush) wantSpeed = (rd < 6.0f) ? 9.8f : 4.0f; // lie in wait, then pounce
            }
        } else {
            // No quarry in reach: regroup with the pack and patrol together — but
            // steer firmly out of the world edges so a pack that cornered its last
            // meal doesn't get pinned there.
            int k = packSlot(p.pack);
            simd_float2 toC = packC[k] - p.pos;
            float cd = simd_length(toC);
            p.heading += (u(_rng) - 0.5f) * 1.4f * dt;
            simd_float2 rove = simd_make_float2(cosf(p.heading), sinf(p.heading));
            simd_float2 group = (packN[k] > 1 && cd > kPackRange*0.6f) ? toC/cd : simd_make_float2(0,0);
            float m = 9.0f;                            // edge margin
            simd_float2 wall = simd_make_float2(
                std::max(0.0f,(m-p.pos.x)/m) - std::max(0.0f,(p.pos.x-(kWorldW-m))/m),
                std::max(0.0f,(m-p.pos.y)/m) - std::max(0.0f,(p.pos.y-(kWorldH-m))/m));
            desire = simd_normalize(rove*0.6f + group*0.7f + wall*2.2f + simd_make_float2(1e-4f,0));
            wantSpeed *= 0.55f;                        // patrol slowly
            p.role = PR_Chaser;
        }

        // Well-fed adults bud off a new hunter (asexual) — it joins the pack.
        if (p.energy > 1.05f && p.age > 14.0f && (int)_predators.size() < kMaxPredators) {
            uint32_t mypack = p.pack;         // capture before the push (vector is reserved, no realloc)
            [self spawnPredator:(p.pos + simd_make_float2(u(_rng)-0.5f, u(_rng)-0.5f))];
            _predators.back().pack = mypack;
            p.energy -= 0.6f;
        }

        simd_float2 wantVel = (simd_length(desire) > 1e-3f)
            ? simd_normalize(desire) * wantSpeed : simd_make_float2(0,0);
        p.vel += (wantVel - p.vel) * std::min(3.5f * dt, 1.0f);
        if (simd_length(p.vel) > 0.05f) p.heading = atan2f(p.vel.y, p.vel.x);
        p.pos += p.vel * dt;
        p.pos.x = std::clamp(p.pos.x, 1.0f, kWorldW - 1.0f);
        p.pos.y = std::clamp(p.pos.y, 1.0f, kWorldH - 1.0f);
        [self waterRippleAt:p.pos vel:p.vel dt:dt];
        p.phase += (0.5f + simd_length(p.vel) * 0.4f) * dt * 6.0f;
        p.spine[0] = p.pos;
        float plink = 0.55f * p.size;
        for (int s = 1; s < kSpineNodes; s++) {
            simd_float2 dir = p.spine[s] - p.spine[s-1];
            float dl = simd_length(dir);
            if (dl > 1e-4f) p.spine[s] = p.spine[s-1] + dir / dl * plink;
            simd_float2 perp = simd_make_float2(-sinf(p.heading), cosf(p.heading));
            p.spine[s] += perp * sinf(p.phase - s * 0.9f) * 0.05f * p.size
                        * simd_length(p.vel) / 9.0f;
        }
    }
    _predators.erase(std::remove_if(_predators.begin(), _predators.end(),
                     [](const Predator &p){ return !p.alive; }), _predators.end());

    // --- contagion: spread by proximity (cheap O(n^2) for the slice size) ---
    for (size_t i = 0; i < _critters.size(); i++) {
        Critter &a = _critters[i];
        if (!a.alive || a.sick < 0.2f) continue;
        for (size_t j = i+1; j < _critters.size(); j++) {
            Critter &b = _critters[j];
            if (!b.alive || b.sick > 0) continue;
            if (simd_distance(a.pos, b.pos) < 2.2f &&
                u(_rng) < (0.5f * (1.0f - b.ph.resistance)) * dt)
                b.sick = 0.2f;
        }
    }
    // rare spontaneous infection keeps disease in the ecosystem
    if (!_critters.empty() && u(_rng) < 0.01f * dt * _critters.size()) {
        Critter &c = _critters[_rng() % _critters.size()];
        if (c.alive && c.sick == 0) c.sick = 0.2f;
    }

    // compact dead
    // Remove only corpses that have fully decayed (living critters and rotting
    // ones both stay).
    _critters.erase(std::remove_if(_critters.begin(), _critters.end(),
                    [](const Critter &c){ return !c.alive && c.decay >= 1.0f; }), _critters.end());
    _food.erase(std::remove_if(_food.begin(), _food.end(),
                [](const Food &f){ return !f.alive; }), _food.end());

    // --- sample colony averages for the evolution graph ---
    _sampleTimer -= dt;
    if (_sampleTimer <= 0) {
        _sampleTimer = kSampleSecs;
        float ss = 0, dd = 0, rr = 0; int n = 0;
        for (const Critter &c : _critters) {
            if (!c.alive) continue;                    // corpses don't count
            ss += std::clamp((c.ph.size - 0.6f) / 1.1f, 0.0f, 1.0f);
            dd += 1.0f - coatLuma(c.ph.color);
            rr += c.ph.resistance;
            n++;
        }
        if (n) { ss /= n; dd /= n; rr /= n; }
        int i = _histHead;
        _histClim[i] = _climate * 0.5f + 0.5f;
        _histSize[i] = ss;
        _histDark[i] = dd;
        _histRes[i]  = rr;
        _histPop[i]  = std::min(n / (float)kMaxCritters * 3.0f, 1.0f);
        _histPred[i] = std::min((int)_predators.size() / 40.0f, 1.0f);
        _histHead = (i + 1) % kHistLen;
        if (_histCount < kHistLen) _histCount++;
    }
}

// ---------------------------------------------------------------- Render ---

- (void)push:(simd_float2)c half:(simd_float2)h rot:(float)rot shape:(float)s
       color:(simd_float4)col p:(simd_float4)pr {
    if ((int)_scratch.size() >= kMaxInstances) return;
    _scratch.push_back({c.x,c.y,h.x,h.y,rot,s, col.x,col.y,col.z,col.w, pr.x,pr.y,pr.z,pr.w});
}
// A translucent veined webbed fin fanning out from `base` in direction `ang`.
- (void)fin:(simd_float2)base ang:(float)ang len:(float)l width:(float)w
      color:(simd_float4)col seed:(float)seed {
    simd_float2 dir = simd_make_float2(cosf(ang), sinf(ang));
    [self push:base + dir*(l*0.5f) half:simd_make_float2(w, l*0.5f)
           rot:ang - 1.57080f shape:18 color:col p:simd_make_float4(seed,0,0,0)];
}
- (void)hud:(float)cx cy:(float)cy hw:(float)hw hh:(float)hh shape:(float)s
      color:(simd_float4)col p0:(float)p0 {
    if (_hud.size() >= 4096) return;
    _hud.push_back({cx,cy,hw,hh,0,s, col.x,col.y,col.z,col.w, p0,0,0,0});
}

- (void)hudNumber:(int)value x:(float)x y:(float)y dw:(float)dw dh:(float)dh
              col:(simd_float4)col bw:(float)bw bh:(float)bh {
    char buf[12]; snprintf(buf, sizeof(buf), "%d", value);
    for (int i = 0; buf[i]; i++) {
        float cx = (x + i*(dw*2.0f+4.0f) + dw) / bw * 2.0f - 1.0f;
        float cy = (y + dh) / bh * 2.0f - 1.0f;
        [self hud:cx cy:cy hw:dw/bw hh:dh/bh shape:5 color:col p0:(float)(buf[i]-'0')];
    }
}

// Draw a text string (A-Z, 0-9) from the bitmap font, left-aligned at (x,y).
- (void)hudText:(const char *)s x:(float)x y:(float)y h:(float)h
            col:(simd_float4)col bw:(float)bw bh:(float)bh {
    float gw = h * 0.62f, adv = gw + h * 0.30f;
    for (const char *p = s; *p; ++p) {
        char ch = *p; int code = -1;
        if (ch >= '0' && ch <= '9') code = ch - '0';
        else if (ch >= 'A' && ch <= 'Z') code = 10 + (ch - 'A');
        else if (ch >= 'a' && ch <= 'z') code = 10 + (ch - 'a');
        else if (ch == '+') code = 36;
        else if (ch == '-') code = 37;
        else if (ch == '.') code = 38;
        else if (ch == '%') code = 39;
        if (code >= 0) {
            float cx = (x + gw*0.5f)/bw*2.0f-1.0f, cy = (y + h*0.5f)/bh*2.0f-1.0f;
            [self hud:cx cy:cy hw:gw/bw hh:h/bh shape:8 color:col p0:(float)code];
        }
        x += adv;
    }
}

// -------------------------------------------------------------- Gene lab ---

// Craft a synthetic allele of a chosen expression level that is always
// DOMINANT (its dominance region is packed with G/T), so a spliced gene
// visibly takes over the phenotype and then spreads through the gene pool.
- (uint32_t)engineerAllele:(float)expr {
    int k = (int)lroundf(std::clamp(expr, 0.0f, 1.0f) * 16.0f);
    uint32_t g = 0; int gc = 0;
    for (int i = 0; i < 16; i++) {
        bool wantGC = gc < k;
        int b = (i >= 8) ? (wantGC ? 2 : 3)     // dominance region: G (GC) or T
                         : (wantGC ? 1 : 0);     // value region:    C (GC) or A
        if (b == 1 || b == 2) gc++;
        g |= ((uint32_t)b) << (2 * i);
    }
    return g;
}

// Introduce n engineered individuals homozygous for the spliced allele.
- (void)spliceGene:(int)gene expr:(float)expr count:(int)n {
    uint32_t allele = [self engineerAllele:expr];
    for (int i = 0; i < n && (int)_critters.size() < kMaxCritters; i++) {
        Genome g = randomGenome(_rng, i % 2);
        g.hom[0][gene] = allele;
        g.hom[1][gene] = allele;
        [self spawnCritter:g at:[self randomPos] gen:_generation];
    }
}

// ------------------------------------------------------------ HUD input ---

- (void)applySlider:(int)act frac:(float)f {
    if (act == WA_ClimateSlider) _climateTrend = f * 1.5f - 0.75f;
    else if (act == WA_ExprSlider) _spliceExpr = std::clamp(f, 0.0f, 1.0f);
    else if (act == WA_FoodSlider) _foodTarget = (int)(40.0f + f * 460.0f);
    else if (act == WA_StartPopSlider) _startPop = (int)(f * 120.0f);          // 0..120
    else if (act == WA_LifespanSlider) _lifespanMul = 0.4f + f * 2.1f;          // 0.4x..2.5x
    else if (act == WA_BirthRateSlider) _birthRate = 0.5f + f * 4.0f;           // 0.5x..4.5x
    else if (act == WA_DayLenSlider) _dayLen = 20.0f + f * 220.0f;              // 20s..240s / day
    else if (act == WA_TimeOfDaySlider) _timeOfDay = std::clamp(f, 0.0f, 1.0f); // scrub the clock
    else if (act == WA_TargetPopSlider) _autoTargetPop = 40.0f + f * 360.0f;    // 40..400 balance target
}

- (BOOL)hudMouseDown:(simd_float2)pt bw:(float)bw bh:(float)bh {
    for (int i = (int)_widgets.size() - 1; i >= 0; i--) {
        UIWidget &wg = _widgets[i];
        if (pt.x < wg.x || pt.x > wg.x+wg.w || pt.y < wg.y || pt.y > wg.y+wg.h) continue;
        _flashAct = wg.act; _flashVal = wg.val; _flashT = 0.30f;   // click feedback
        switch (wg.act) {
            case WA_Toggle:    _panelTarget = (_panelTarget > 0.5f) ? 0.0f : 1.0f; break;
            case WA_Pause:     _paused = !_paused; break;
            case WA_SpeedDn:   _timeScale = std::max(_timeScale*0.5f, 0.25f); break;
            case WA_SpeedUp:   _timeScale = std::min(_timeScale*2.0f, 8.0f); break;
            case WA_Food:      [self scatterFood:60]; break;
            case WA_Introduce: [self introduceRandom]; break;
            case WA_Cull:      [self cullSelected]; break;
            case WA_Reset:     [self resetColony]; break;
            case WA_TraitPick: _spliceGene = (int)wg.val; break;
            case WA_Splice:    [self spliceGene:_spliceGene expr:_spliceExpr count:4]; break;
            case WA_ToggleGraph: _showGraph = !_showGraph; break;
            case WA_AddPredator: [self spawnPredator:[self randomPos]]; break;
            case WA_SpawnPack:   [self spawnPack:5]; break;
            case WA_ToggleSound: _muted = !_muted; break;
            case WA_ToggleBubbleSfx: _bubbleSfxOn = !_bubbleSfxOn; break;
            case WA_ToggleAuto:
                _autoAdjust = !_autoAdjust;
                if (_autoAdjust) _autoTimer = 0.0f;      // act immediately (target set by its slider)
                break;
            case WA_ToggleEnv: _aquarium = !_aquarium; break;
            case WA_CullPredators: [self cullPredators]; break;
            case WA_MakeRain:  _rainOn = true; _cloudsOn = true;
                               _cloudTarget = 0.9f; _rainTarget = 0.9f; _weatherTimer = 25.0f; break;
            case WA_ToggleDayNight: _dayNightOn = !_dayNightOn; break;
            case WA_ToggleClouds:   _cloudsOn = !_cloudsOn; break;
            case WA_ToggleRain:     _rainOn = !_rainOn; break;
            case WA_ClearColony: [self clearColony]; break;
            case WA_ZoomIn:    [self zoomBy:1.4f atNdc:simd_make_float2(0,0)]; break;
            case WA_ZoomOut:   [self zoomBy:1.0f/1.4f atNdc:simd_make_float2(0,0)]; break;
            case WA_ResetView: _zoom = 1.0f;
                               _panCenter = simd_make_float2(kWorldW*0.5f, kWorldH*0.5f); break;
            case WA_ClimateSlider:
            case WA_ExprSlider:
            case WA_FoodSlider:
            case WA_StartPopSlider:
            case WA_LifespanSlider:
            case WA_BirthRateSlider:
            case WA_DayLenSlider:
            case WA_TimeOfDaySlider:
            case WA_TargetPopSlider:
                _dragAct = wg.act; _dragX = wg.x; _dragW = wg.w;
                [self applySlider:wg.act
                             frac:std::clamp((pt.x-wg.x)/std::max(wg.w,1.0f), 0.0f, 1.0f)];
                break;
            default: break;
        }
        return YES;
    }
    // Click landed on the open panel but missed every widget: swallow it so it
    // doesn't select a critter hidden behind the panel.
    float panelX = bw - 300.0f * _panelT;
    return (_panelT > 0.5f && pt.x >= panelX) ? YES : NO;
}

// Sliding control panel: every environmental knob and the gene lab, all
// mouse-driven. Rebuilt each frame; widgets are registered for hit-testing.
- (void)buildControlPanel:(float)bw bh:(float)bh {
    auto rect = [&](float x, float y, float w, float h, simd_float4 c, float s) {
        float cx = (x+w*0.5f)/bw*2.0f-1.0f, cy = (y+h*0.5f)/bh*2.0f-1.0f;
        [self hud:cx cy:cy hw:w/bw hh:h/bh shape:s color:c p0:0];
    };
    auto text = [&](float x, float y, const char *t, float h, simd_float4 c) {
        [self hudText:t x:x y:y h:h col:c bw:bw bh:bh];
    };
    const float panW = 300, tabW = 30;
    float panelX = bw - panW * _panelT;

    // Tab handle (always present, even when the panel is hidden).
    float tabH = 76, tabX = panelX - tabW, tabY = bh*0.5f - tabH*0.5f;
    rect(tabX, tabY, tabW, tabH, simd_make_float4(0.10f,0.12f,0.16f,0.96f), 6);
    for (int i = 0; i < 3; i++)
        rect(tabX+9, tabY+tabH*0.5f-7+i*6, tabW-18, 2.5f, simd_make_float4(0.75f,0.85f,1.0f,1), 4);
    _widgets.push_back({tabX, tabY, tabW, tabH, WA_Toggle, 0});

    if (_panelT < 0.02f) return;
    bool live = _panelT > 0.5f;

    rect(panelX, 0, panW, bh, simd_make_float4(0.05f,0.06f,0.09f,0.95f), 4);
    rect(panelX, 0, 2, bh, simd_make_float4(0.30f,0.55f,0.80f,0.7f), 4);

    float x0 = panelX + 16, cw = panW - 32;
    simd_float4 cLabel = simd_make_float4(0.55f,0.68f,0.85f,1);
    simd_float4 cTxt   = simd_make_float4(0.92f,0.95f,1.0f,1);
    std::vector<UIWidget> &widgets = _widgets;
    int flashAct = _flashAct; float flashVal = _flashVal, flashT = _flashT;

    auto button = [&](float x, float y, float w, float h, const char *t,
                      int act, float val, bool hot) {
        simd_float4 bg = hot ? simd_make_float4(0.18f,0.42f,0.62f,1)
                             : simd_make_float4(0.14f,0.17f,0.22f,1);
        // Momentary click flash: light up and fade back over ~0.3s.
        if (flashT > 0.0f && act == flashAct && val == flashVal) {
            simd_float4 hi = simd_make_float4(0.45f,0.85f,1.0f,1.0f);
            bg = bg + (hi - bg) * (flashT / 0.30f);
        }
        rect(x, y, w, h, bg, 6);
        float gh = h*0.5f, adv = gh*0.62f + gh*0.30f;
        float tw = (float)strlen(t) * adv - gh*0.30f;
        text(x + std::max((w-tw)*0.5f, 3.0f), y + (h-gh)*0.5f, t, gh, cTxt);
        if (live) widgets.push_back({x, y, w, h, act, val});
    };
    auto slider = [&](float x, float y, float w, float h, float frac, int act) {
        frac = std::clamp(frac, 0.0f, 1.0f);
        rect(x, y, w, h, simd_make_float4(0.12f,0.14f,0.18f,1), 6);
        rect(x, y, w*frac, h, simd_make_float4(0.28f,0.52f,0.78f,1), 6);
        rect(x + frac*w - 4, y-3, 8, h+6, simd_make_float4(0.9f,0.95f,1.0f,1), 6);
        if (live) widgets.push_back({x, y, w, h, act, 0});
    };

    float cy = bh - 22 + _panelScroll;      // scroll shifts the content up
    auto row = [&](float h, float gap) { cy -= h; float y = cy; cy -= gap; return y; };

    text(x0, row(18,12), "CONTROLS", 18, simd_make_float4(0.85f,0.92f,1.0f,1));

    // --- TIME ---
    text(x0, row(11,5), "TIME", 11, cLabel);
    {
        float y = row(26,6);
        button(x0, y, 96, 26, _paused ? "PLAY" : "PAUSE", WA_Pause, 0, _paused);
        button(x0+cw-84, y, 40, 26, "-", WA_SpeedDn, 0, false);
        button(x0+cw-40, y, 40, 26, "+", WA_SpeedUp, 0, false);
    }
    {
        float y = row(8,14);
        int idx = (int)lroundf(log2f(std::max(_timeScale,0.25f)) + 2.0f);  // 0..5
        float segW = (cw - 5*4) / 6.0f;
        for (int k = 0; k < 6; k++)
            rect(x0 + k*(segW+4), y, segW, 8,
                 (k <= idx) ? simd_make_float4(0.30f,0.60f,0.85f,1)
                            : simd_make_float4(0.16f,0.18f,0.22f,1), 6);
    }

    // --- VIEW (zoom) ---
    text(x0, row(11,5), "VIEW", 11, cLabel);
    {
        float y = row(24,6), w = (cw-8)/3.0f;
        button(x0, y, w, 24, "ZOOM-", WA_ZoomOut, 0, false);
        button(x0+(w+4), y, w, 24, "ZOOM+", WA_ZoomIn, 0, false);
        button(x0+2*(w+4), y, w, 24, "FIT", WA_ResetView, 0, false);
    }
    button(x0, row(24,14), cw, 24, _aquarium ? "HABITAT: AQUARIUM" : "HABITAT: FOREST",
           WA_ToggleEnv, 0, _aquarium);

    // --- CLIMATE ---
    text(x0, row(11,5), "CLIMATE", 11, cLabel);
    slider(x0, row(18,5), cw, 18, (_climateTrend+0.75f)/1.5f, WA_ClimateSlider);
    {
        const char *band = _climate<-0.33f ? "COLD" : (_climate>0.33f ? "HOT" : "TEMPERATE");
        text(x0, row(11,14), band, 11, cTxt);
    }

    // --- FOOD ---
    text(x0, row(11,5), "FOOD", 11, cLabel);
    button(x0, row(26,6), cw, 26, "SCATTER FOOD", WA_Food, 0, false);
    text(x0, row(10,3), "ABUNDANCE", 10, cLabel);
    slider(x0, row(18,14), cw, 18, (_foodTarget-40)/460.0f, WA_FoodSlider);

    // --- POPULATION ---
    text(x0, row(11,5), "POPULATION", 11, cLabel);
    {
        float y = row(24,14), w = (cw-12)/4.0f;
        button(x0, y, w, 24, "ADD", WA_Introduce, 0, false);
        button(x0+(w+4), y, w, 24, "CULL", WA_Cull, 0, false);
        button(x0+2*(w+4), y, w, 24, "RESET", WA_Reset, 0, false);
        button(x0+3*(w+4), y, w, 24, "CLEAR", WA_ClearColony, 0, false);
    }

    // --- LIFE (start population + lifespan multiplier) ---
    {
        float y = row(11,5);
        text(x0, y, "START POP", 11, cLabel);
        [self hudNumber:_startPop x:x0+cw-46 y:y dw:5 dh:9 col:cTxt bw:bw bh:bh];
    }
    slider(x0, row(18,10), cw, 18, _startPop/120.0f, WA_StartPopSlider);
    {
        float y = row(11,5);
        text(x0, y, "LIFESPAN PCT", 11, cLabel);
        [self hudNumber:(int)(_lifespanMul*100.0f) x:x0+cw-46 y:y dw:5 dh:9 col:cTxt bw:bw bh:bh];
    }
    slider(x0, row(18,10), cw, 18, (_lifespanMul-0.4f)/2.1f, WA_LifespanSlider);
    {
        float y = row(11,5);
        text(x0, y, "BIRTH RATE PCT", 11, cLabel);
        [self hudNumber:(int)(_birthRate*100.0f) x:x0+cw-52 y:y dw:5 dh:9 col:cTxt bw:bw bh:bh];
    }
    slider(x0, row(18,10), cw, 18, (_birthRate-0.5f)/4.0f, WA_BirthRateSlider);
    // Balance auto-pilot: regulates food, births, predators and climate together
    // to hold the colony near the target average (and never past the hard cap).
    button(x0, row(24,5), cw, 24, _autoAdjust ? "BALANCE: ON (auto-regulate)" : "BALANCE: OFF",
           WA_ToggleAuto, 0, _autoAdjust);
    {
        float y = row(11,3);
        text(x0, y, "TARGET POP", 11, cLabel);
        [self hudNumber:(int)_autoTargetPop x:x0+cw-46 y:y dw:5 dh:9 col:cTxt bw:bw bh:bh];
    }
    slider(x0, row(18,12), cw, 18, (_autoTargetPop-40.0f)/360.0f, WA_TargetPopSlider);

    // --- PREDATORS ---
    text(x0, row(11,5), "PREDATORS", 11, cLabel);
    {
        float y = row(26,14), w = (cw-8)/3.0f;
        button(x0,         y, w, 26, "HUNTER", WA_AddPredator, 0, false);   // one lone hunter
        button(x0+(w+4),   y, w, 26, "PACK",   WA_SpawnPack,   0, false);   // a coordinated pack of 5
        button(x0+2*(w+4), y, w, 26, "REMOVE", WA_CullPredators, 0, false);
    }

    // --- SKY (day/night + weather) ---
    {
        // Name the phase from the clock and the weather from cloud/rain.
        const char *phase = (_timeOfDay < 0.22f || _timeOfDay > 0.80f) ? "NIGHT"
                          : (_timeOfDay < 0.32f) ? "DAWN"
                          : (_timeOfDay > 0.68f) ? "DUSK" : "DAY";
        const char *wx = _rain > 0.25f ? "RAIN" : (_cloud > 0.45f ? "CLOUDY" : "CLEAR");
        float y = row(11,5);
        text(x0, y, "SKY", 11, cLabel);
        char sky[24]; snprintf(sky, sizeof sky, "%s  %s", _dayNightOn ? phase : "DAY", wx);
        text(x0+52, y, sky, 11, cTxt);
    }
    slider(x0, row(16,3), cw, 16, _timeOfDay, WA_TimeOfDaySlider);            // scrub time of day
    slider(x0, row(16,3), cw, 16, (_dayLen-20.0f)/220.0f, WA_DayLenSlider);   // day length
    {
        // Independent on/off toggles for each sky element (lit when enabled).
        float y = row(22,4), w = (cw-8)/3.0f;
        button(x0,          y, w, 22, "DAY/NGT", WA_ToggleDayNight, 0, _dayNightOn);
        button(x0+(w+4),    y, w, 22, "CLOUDS",  WA_ToggleClouds,   0, _cloudsOn);
        button(x0+2*(w+4),  y, w, 22, "RAIN",    WA_ToggleRain,     0, _rainOn);
    }
    {
        float y = row(24,6), w = (cw-4)/2.0f;
        button(x0,       y, w, 24, "MAKE RAIN", WA_MakeRain, 0, _rain > 0.4f);
        button(x0+w+4,   y, w, 24, _muted ? "SOUND OFF" : "SOUND ON", WA_ToggleSound, 0, !_muted);
    }
    button(x0, row(22,12), cw, 22, _bubbleSfxOn ? "BUBBLE SFX ON" : "BUBBLE SFX OFF",
           WA_ToggleBubbleSfx, 0, _bubbleSfxOn);

    // --- GENE LAB ---
    text(x0, row(12,6), "SPLICE GENE", 12, simd_make_float4(0.70f,0.92f,0.66f,1));
    {
        float bwid = (cw-6)/2.0f, bhei = 22;
        int rows = (kNumTraitBtns + 1) / 2;
        for (int r = 0; r < rows; r++) {
            float y = row(bhei, 4);
            for (int c2 = 0; c2 < 2; c2++) {
                int i = r*2 + c2;
                if (i >= kNumTraitBtns) break;
                button(x0 + c2*(bwid+6), y, bwid, bhei, kTraits[i].name,
                       WA_TraitPick, (float)kTraits[i].gene,
                       kTraits[i].gene == _spliceGene);
            }
        }
    }
    text(x0, row(10,3), "EXPRESSION", 10, cLabel);
    slider(x0, row(18,8), cw, 18, _spliceExpr, WA_ExprSlider);
    button(x0, row(28,8), cw, 28, "SPLICE INTO COLONY", WA_Splice, 0, false);

    // How far the content runs past the bottom of the window — the scroll range.
    // (cy is the current bottom; subtract the live scroll to get the unscrolled
    // bottom, then see how far below the ~14px margin it sits.)
    _panelOverflow = std::max(0.0f, 14.0f - (cy - _panelScroll));
    _panelScroll = std::clamp(_panelScroll, 0.0f, _panelOverflow);
}

- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) return;

    double now = CACurrentMediaTime();
    float t = (float)(now - _startTime);
    float dtRaw = (float)(now - _lastFrameTime);
    _lastFrameTime = now;
    if (dtRaw > 0) _smoothedFPS += (1.0f/dtRaw - _smoothedFPS) * 0.05f;
    _panelT += (_panelTarget - _panelT) * std::min(1.0f, 12.0f * dtRaw);  // slide
    if (_flashT > 0) _flashT = std::max(0.0f, _flashT - dtRaw);           // click flash fades

    if (!_paused) {
        _simAccum += std::min(dtRaw * _timeScale, 0.5f);
        const double step = 1.0/60.0;
        int guard = 0;
        while (_simAccum >= step && guard++ < 40) { [self simStep:(float)step]; _simAccum -= step; }
    }
    [self updateAudio:std::min(dtRaw, 0.1f)];    // crossfade ambience even while paused

    float aspect = (float)(view.drawableSize.width / view.drawableSize.height);
    float s = std::min(2.0f*aspect/kWorldW, 2.0f/kWorldH) * 0.96f * _zoom;
    _uScale = simd_make_float2(s/aspect, s);
    _uOffset = simd_make_float2(-_panCenter.x * (s/aspect), -_panCenter.y * s);

    struct { simd_float2 scale, offset, resolution; float time, pad,
             daylight, warmth, cloud, rain, aquarium; } uni = {
        _uScale, _uOffset,
        simd_make_float2((float)view.drawableSize.width, (float)view.drawableSize.height), t,
        _climate,
        _daylight, _skyWarm, std::clamp(_cloud,0.0f,1.0f), std::clamp(_rain,0.0f,1.0f),
        _aquarium ? 1.0f : 0.0f
    };

    dispatch_semaphore_wait(_frameSemaphore, DISPATCH_TIME_FOREVER);
    _scratch.clear();
    _glow.clear();
    _hud.clear();

    // ground cover (drawn first, under everything): moss, clover, flowers,
    // pebbles, twigs — the carpet of forest-floor detail (hidden in the tank)
    for (const Decor &d : _decor) {
        if (_aquarium) break;
        int shp = (d.kind==0) ? 13 : (d.kind==1) ? 2 : (d.kind==2) ? 14
                : (d.kind==3) ? 0 : 4;
        simd_float2 hlf = (d.kind==4) ? simd_make_float2(d.size, d.size*0.16f)   // twig: thin
                                      : simd_make_float2(d.size, d.size);
        [self push:d.pos half:hlf rot:d.rot shape:(float)shp
              color:simd_make_float4(d.color, 1.0f) p:simd_make_float4(d.seed,0,0,0)];
    }

    // water pools (lowest layer): one animated water sprite per pool
    for (const Water &wp : _water) {
        float seed = wp.pos.x*0.7f + wp.pos.y*1.3f;
        [self push:wp.pos half:simd_make_float2(wp.radius, wp.radius) rot:0 shape:10
              color:simd_make_float4(1,1,1,1) p:simd_make_float4(t, seed, 0, 0)];
    }
    // soft wake ripples — faint gaussian crests that expand and dissolve
    for (const Ripple &rp : _ripples) {
        float ft = rp.age / rp.life;                // 0..1
        float rad = 0.4f + 2.0f * ft;               // grows outward
        float alpha = (1.0f - ft) * (1.0f - ft) * 0.28f;   // eases out gently
        [self push:rp.pos half:simd_make_float2(rad, rad) rot:0 shape:11
              color:simd_make_float4(0.85f,0.93f,1.0f, alpha) p:simd_make_float4(0,0,0,0)];
    }
    // Thick, lush grass band ringing each pond — several dense radial rows of
    // reed tufts. They lean away and flatten where a critter treads or drinks.
    auto hashf = [](float n){ float s = sinf(n)*43758.5453f; return s - floorf(s); };
    std::vector<simd_float2> nearby;
    for (int wi = 0; wi < (int)_water.size(); wi++) {
        const Water &wp = _water[wi];
        float outer = wp.radius * 1.40f;
        // gather just the critters close to this pond, once, for the parting test
        nearby.clear();
        for (const Critter &c : _critters)
            if (c.alive && simd_distance(c.pos, wp.pos) < outer + 2.5f)
                nearby.push_back(c.pos);

        const int rings = 6;
        for (int ring = 0; ring < rings; ring++) {
            float rt = ring / (float)(rings - 1);                 // 0 inner .. 1 outer
            float bandR = wp.radius * (0.88f + 0.66f * rt);       // 0.88x .. 1.54x band
            int nA = std::max(12, (int)(bandR * 3.4f));           // very dense around the rim
            for (int i = 0; i < nA; i++) {
                float base = wi*97.0f + ring*13.7f + i*2.399f;
                float j0 = hashf(base), j1 = hashf(base+1.7f), j2 = hashf(base+3.3f);
                float ang = (i/(float)nA)*6.2831853f + ring*0.5f + (j0-0.5f)*0.5f;
                // undulating outer boundary so the ring isn't a clean circle
                float boundary = 1.0f + rt * (0.16f*sinf(ang*2.3f + wi*1.7f)
                                              + 0.09f*sinf(ang*5.1f + wi));
                float rr = bandR * boundary + (j1-0.5f)*wp.radius*0.16f;
                simd_float2 gp = wp.pos + simd_make_float2(cosf(ang), sinf(ang)) * rr;
                simd_float2 push = simd_make_float2(0,0);
                float bend = 0.0f;
                for (const simd_float2 &cp : nearby) {
                    simd_float2 to = gp - cp;
                    float d = simd_length(to);
                    if (d < 1.8f) {
                        float kk = (1.8f - d) / 1.8f;
                        push += (d > 1e-3f ? to/d : simd_make_float2(0,1)) * kk;
                        bend = std::max(bend, kk);
                    }
                }
                gp += push * 0.9f;                                 // lean away
                float sz = (0.95f + 0.6f*j2) * (1.0f - 0.5f*bend); // taller, flatten when trodden
                // varied greens — bright lime highlights over darker bases
                float lime = j1*j1;
                simd_float3 gcol = simd_make_float3(0.10f + 0.14f*lime,
                                                    0.32f + 0.26f*j1,
                                                    0.07f + 0.09f*j2);
                [self push:gp half:simd_make_float2(sz, sz*1.6f) rot:(j0-0.5f)*0.35f shape:12
                      color:simd_make_float4(gcol, 1.0f) p:simd_make_float4(base,0,0,0)];
            }
        }
    }

    // Soft contact shadows — drawn first so every entity sits on top of its own
    // shadow. Offset toward lower-right so the light reads as upper-left.
    simd_float2 shOff = simd_make_float2(0.22f, -0.22f);
    simd_float4 shGrn = simd_make_float4(0,0,0,0);
    for (const Nest &n : _nests) if (n.alive) {
        float r = (1.2f + 1.6f * n.quality) * 0.95f;
        [self push:n.pos+shOff half:simd_make_float2(r,r) rot:0 shape:0
              color:simd_make_float4(0,0,0,0.18f) p:shGrn];
    }
    for (const Food &f : _food) if (f.alive)
        [self push:f.pos+simd_make_float2(0.10f,-0.10f) half:simd_make_float2(0.34f,0.34f)
              rot:0 shape:0 color:simd_make_float4(0,0,0,0.13f) p:shGrn];
    for (const Critter &c : _critters) {
        if (!c.alive && c.decay >= 1.0f) continue;
        float sa = 0.24f * (c.alive ? 1.0f : (1.0f - c.decay));   // corpse shadow fades
        [self push:c.pos+shOff half:simd_make_float2(c.ph.size*0.62f, c.ph.size*0.62f)
              rot:0 shape:0 color:simd_make_float4(0,0,0,sa) p:shGrn];
    }
    for (const Predator &p : _predators) if (p.alive)
        [self push:p.pos+shOff half:simd_make_float2(p.size*0.55f, p.size*0.55f)
              rot:0 shape:0 color:simd_make_float4(0,0,0,0.28f) p:shGrn];

    // food: organic leafy sprigs, each seeded from its position so no two match
    for (const Food &f : _food) {
        if (!f.alive) continue;
        float g = f.growth;
        float seed = f.pos.x*1.7f + f.pos.y*0.9f;
        [self push:f.pos half:simd_make_float2(0.6f*g+0.28f, 0.6f*g+0.28f)
              rot:fmodf(seed, 6.2831f) shape:2
              color:simd_make_float4(0.26f, 0.50f+0.28f*g, 0.16f, 1.0f)
                 p:simd_make_float4(seed,0,0,0)];
    }

    // nests: irregular woven bowls (a single seeded organic sprite)
    for (const Nest &n : _nests) {
        if (!n.alive) continue;
        float r = 1.2f + 1.6f * n.quality;
        float seed = n.pos.x*2.3f + n.pos.y*1.1f;
        simd_float3 twig = simd_make_float3(0.46f, 0.33f, 0.17f);
        [self push:n.pos half:simd_make_float2(r,r) rot:fmodf(seed, 6.2831f) shape:9
              color:simd_make_float4(twig, 1.0f) p:simd_make_float4(seed,0,0,0)];
    }

    // critters: the BUBBLE BURROWER — a big translucent speckled membrane body
    // that paddles along on four splayed veined webbed fins, with a small snout
    // bump and two low dark-navy eyes. They age (worn/faded), camouflage toward the
    // ground when standing still, and settle into a decaying corpse when they die.
    for (const Critter &c : _critters) {
        if (!c.alive && c.decay >= 1.0f) continue;
        bool corpse = !c.alive;
        float A = corpse ? std::max(0.0f, 1.0f - c.decay) : 1.0f;
        float sink = corpse ? (1.0f - 0.35f * c.decay) : 1.0f;
        const Phenotype &ph = c.ph;

        simd_float3 base = ph.color;
        if (!corpse) {
            if (c.sick > 0) base = base + (simd_make_float3(0.70f,0.85f,0.30f)-base)*(c.sick*0.6f);
            if (c.health < 0.5f) base = base * (0.6f + 0.4f*c.health);
            float ageT = std::clamp(c.age/(ph.lifespan*_lifespanMul), 0.0f, 1.0f);
            float old = std::clamp((ageT-0.55f)/0.45f, 0.0f, 1.0f);
            base = base + (simd_make_float3(0.46f,0.43f,0.37f)-base)*old*0.5f;
            // Camouflage: chromatophores blend the coat toward the mossy ground.
            // c.camo eases in over several seconds when still and washes back out
            // on the move, and settles deep enough that a motionless burrower is
            // genuinely hard to spot.
            base = base + (simd_make_float3(0.20f,0.30f,0.15f)-base)*std::clamp(c.camo,0.0f,1.0f)*0.72f;
            // Seized in a predator's jaws: flush an injured red as it's shaken.
            if (c.grab > 0.0f) base = base + (simd_make_float3(0.62f,0.08f,0.08f)-base)*0.55f;
        } else {
            base = base + (simd_make_float3(0.20f,0.15f,0.10f)-base)*(0.35f+0.55f*c.decay);
        }

        // Hunkering / hiding pulls the body in low and tight against the ground.
        float tuck = (!corpse && c.action == AHunker) ? 0.88f : 1.0f;
        // Gait: footwork and a slight step-bounce scale with how fast it's actually
        // moving, so it quickens on the run and stills at rest. Asleep → no gait,
        // just a slow breathing swell.
        bool asleep = !corpse && c.rest > 0.5f;
        float mv = (corpse || asleep) ? 0.0f
                 : std::clamp(simd_length(c.vel)/std::max(ph.speed,0.1f), 0.0f, 1.4f);
        float breathe = asleep ? (1.0f + 0.03f * sinf(t * 0.8f + (float)(c.id%97))) : 1.0f;
        float bounce = 1.0f + 0.07f * mv * fabsf(sinf(c.phase));      // body swells a touch on each step
        float S = ph.size * 0.85f * tuck * bounce * breathe;         // body radius (membrane)
        simd_float2 fwd = simd_make_float2(cosf(c.heading), sinf(c.heading));
        simd_float2 perp = simd_make_float2(-fwd.y, fwd.x);
        float seed = (float)(c.id % 97) * 0.7f;
        // Alternating four-beat gait. The KEY cue is that each limb strides fore
        // and aft along the body (planting and pushing), diagonal pairs opposite;
        // a smaller angle swing rides on top. Both near-zero at rest, growing with
        // speed, so a still critter's feet don't march in place.
        float step   = asleep ? 0.0f : sinf(c.phase);              // raw gait signal (still when asleep)
        float amp    = (0.08f + 0.50f * mv) * step;                 // fin angle swing
        float stride = (0.10f + 0.55f * mv) * S * step;             // fore/aft limb travel
        simd_float2 strideA = fwd * stride;                        // pair A (rear-L + front-R) forward
        simd_float2 strideB = -strideA;                            // pair B (rear-R + front-L) opposite
        float gA = amp;                                            // pair A angle
        float gB = -amp;                                           // pair B angle
        simd_float4 finCol = simd_make_float4(base*1.05f + simd_make_float3(0.04f,0.06f,0.05f), A);

        // Bioluminescence: after dark, a soft halo glows in the animal's dominant
        // coat colour. Collected into _glow and drawn AFTER the night wash, so it
        // adds light over the darkened scene instead of being dimmed with it.
        if (!corpse) {
            float night = std::clamp(1.0f - _daylight, 0.0f, 1.0f);
            if (night > 0.03f && (int)_glow.size() < kMaxCritters) {
                simd_float3 gc = ph.color;                            // true genetic hue, not camouflaged
                float mx = std::max(gc.x, std::max(gc.y, gc.z));
                gc = gc * (1.0f / std::max(mx, 0.05f));               // vivid version of the dominant hue
                float pulse = 0.82f + 0.18f * sinf(t * 1.7f + seed);  // gentle breathing shimmer
                float ga = 0.85f * night * pulse * A;
                float gr = S * 2.3f;
                _glow.push_back({c.pos.x, c.pos.y, gr, gr, 0, 0/*soft blob*/,
                                 gc.x, gc.y, gc.z, ga, 0,0,0,0});
            }
        }

        // Four splayed translucent veined webbed fins (drawn first; the body overlaps
        // their roots). Diagonal pairs stride out of phase — a true four-beat walk.
        // rear pair — the main paddles
        [self fin:c.pos - fwd*0.35f*S + perp*0.60f*S + strideA ang:c.heading + 2.15f + gA        // rear-left (A)
               len:1.25f*S*sink width:0.42f*S color:finCol seed:seed];
        [self fin:c.pos - fwd*0.35f*S - perp*0.60f*S + strideB ang:c.heading - 2.15f + gB        // rear-right (B)
               len:1.25f*S*sink width:0.42f*S color:finCol seed:seed+3.0f];
        // front pair — smaller, swing a little less
        [self fin:c.pos + fwd*0.30f*S + perp*0.55f*S + strideB ang:c.heading + 1.05f + gB*0.8f   // front-left (B)
               len:0.95f*S*sink width:0.34f*S color:finCol seed:seed+6.0f];
        [self fin:c.pos + fwd*0.30f*S - perp*0.55f*S + strideA ang:c.heading - 1.05f + gA*0.8f   // front-right (A)
               len:0.95f*S*sink width:0.34f*S color:finCol seed:seed+9.0f];

        // Big translucent speckled domed membrane body (slightly tapered toward the face).
        [self push:c.pos half:simd_make_float2(S*1.05f*sink, S*1.02f*sink) rot:c.heading shape:15
              color:simd_make_float4(base,A) p:simd_make_float4(seed, t, 0,0)];
        // Small snout bump at the front.
        [self push:c.pos + fwd*0.72f*S half:simd_make_float2(S*0.42f*sink, S*0.36f*sink) rot:c.heading shape:15
              color:simd_make_float4(base*1.02f,A) p:simd_make_float4(seed+2.0f, t, 0,0)];

        if (!corpse) {
            simd_float2 eL = c.pos + fwd*0.60f*S + perp*0.40f*S;
            simd_float2 eR = c.pos + fwd*0.60f*S - perp*0.40f*S;
            if (asleep) {
                // Eyes shut: a slim dark closed lid across each eye.
                float er = (0.24f + ph.eyeSize*0.9f) * S;
                simd_float4 lid = simd_make_float4(0.05f, 0.06f, 0.12f, A);
                [self push:eL half:simd_make_float2(er*0.30f, er*0.85f) rot:c.heading shape:4
                      color:lid p:simd_make_float4(0,0,0,0)];
                [self push:eR half:simd_make_float2(er*0.30f, er*0.85f) rot:c.heading shape:4
                      color:lid p:simd_make_float4(0,0,0,0)];
            } else {
                // Two low dark-navy glossy eyes up front (color = heritable iris tint).
                // Pupils widen in low light — larger at dawn/dusk and through the night.
                float er = (0.24f + ph.eyeSize*0.9f) * S * (1.0f + 0.32f * (1.0f - _daylight));
                simd_float4 eyec = simd_make_float4(ph.eyeColor, A);
                [self push:eL half:simd_make_float2(er,er) rot:0 shape:17 color:eyec p:simd_make_float4(0,0,0,0)];
                [self push:eR half:simd_make_float2(er,er) rot:0 shape:17 color:eyec p:simd_make_float4(0,0,0,0)];
            }
            if (c.pregnant)
                [self push:c.pos + simd_make_float2(0, S*0.95f) half:simd_make_float2(0.18f,0.18f)
                      rot:0 shape:7 color:simd_make_float4(1.0f,0.5f,0.7f,1) p:simd_make_float4(0,0,0,0)];
        }
    }

    // Bubbles rising from playful, courting, and water-side burrowers — glossy
    // little air spheres that swell slightly and fade as they near their pop.
    for (const Bubble &b : _bubbles) {
        float ft = b.age / b.life;                      // 0..1
        float r = b.size * (0.7f + 0.6f * ft);          // swells as it rises
        float alpha = std::min(1.0f, 2.5f * (1.0f - ft));
        [self push:b.pos half:simd_make_float2(r, r) rot:0 shape:16
              color:simd_make_float4(0.80f, 0.92f, 1.0f, alpha) p:simd_make_float4(0,0,0,0)];
    }

    // Glowing love hearts drifting up from courting / mating pairs.
    for (const Bubble &h : _hearts) {
        float ft = h.age / h.life;                      // 0..1
        float sz = h.size * (0.75f + 0.35f * ft);
        float alpha = std::min(1.0f, 2.2f * (1.0f - ft));
        // soft pink glow halo, then the heart itself
        [self push:h.pos half:simd_make_float2(sz*2.0f, sz*2.0f) rot:0 shape:0
              color:simd_make_float4(1.0f, 0.40f, 0.58f, alpha*0.35f) p:simd_make_float4(0,0,0,0)];
        [self push:h.pos half:simd_make_float2(sz, sz) rot:0 shape:19
              color:simd_make_float4(1.0f, 0.42f, 0.60f, alpha) p:simd_make_float4(0,0,0,0)];
    }

    // predators: larger dark-red hunters, same procedural spine + glowing eyes
    for (const Predator &p : _predators) {
        if (!p.alive) continue;
        simd_float2 fwd = simd_make_float2(cosf(p.heading), sinf(p.heading));
        simd_float2 perp = simd_make_float2(-fwd.y, fwd.x);
        simd_float3 body = simd_make_float3(0.58f, 0.11f, 0.12f);
        simd_float3 dark = simd_make_float3(0.26f, 0.05f, 0.07f);
        for (int sidx = kSpineNodes-1; sidx >= 0; sidx--) {
            float un = sidx / (kSpineNodes - 1.0f);
            float rr = p.size * 0.50f * (1.0f - 0.60f * un);
            simd_float3 col = dark + (body - dark) * (1.0f - un);
            [self push:p.spine[sidx] half:simd_make_float2(rr,rr) rot:0 shape:0
                  color:simd_make_float4(col,1.0f) p:simd_make_float4(0,0,0,0)];
        }
        // Dorsal spikes tinted by the hunter's current pack role, so the
        // strategy is readable: red chasers drive, amber flankers cut off the
        // sides, violet ambushers lie ahead to intercept.
        simd_float3 rc = (p.role == PR_Chaser) ? simd_make_float3(0.90f,0.24f,0.16f)
                       : (p.role == PR_Ambush) ? simd_make_float3(0.62f,0.30f,0.78f)
                                               : simd_make_float3(0.96f,0.62f,0.16f);
        for (int k = 1; k < kSpineNodes-1; k++)   // dorsal spikes
            [self push:p.spine[k] half:simd_make_float2(p.size*0.15f,p.size*0.15f) rot:0 shape:7
                  color:simd_make_float4(rc,1) p:simd_make_float4(0,0,0,0)];
        float er = 0.14f * p.size;
        [self push:p.pos + fwd*0.22f*p.size + perp*0.22f*p.size
              half:simd_make_float2(er,er) rot:0 shape:0
              color:simd_make_float4(1.0f,0.82f,0.2f,1) p:simd_make_float4(0,0,0,0)];
        [self push:p.pos + fwd*0.22f*p.size - perp*0.22f*p.size
              half:simd_make_float2(er,er) rot:0 shape:0
              color:simd_make_float4(1.0f,0.82f,0.2f,1) p:simd_make_float4(0,0,0,0)];
    }

    // selection ring + inspector
    Critter *sel = [self critterById:_selected];
    if (sel) {
        [self push:sel->pos half:simd_make_float2(sel->ph.size*1.3f, sel->ph.size*1.3f)
              rot:0 shape:1 color:simd_make_float4(1.0f,0.9f,0.2f,1.0f) p:simd_make_float4(0,0,0,0)];
    }

    id<MTLBuffer> ib = _instBuffers[_frameIndex];
    NSUInteger ic = _scratch.size();
    if (ic) memcpy([ib contents], _scratch.data(), ic*sizeof(InstC));
    id<MTLBuffer> gb = _glowBuffers[_frameIndex];
    NSUInteger gcnt = _glow.size();
    if (gcnt) memcpy([gb contents], _glow.data(), gcnt*sizeof(InstC));

    // ---- HUD ----
    float bw = (float)view.bounds.size.width, bh = (float)view.bounds.size.height;
    _widgets.clear();
    [self buildEvoGraph:bw bh:bh];
    [self buildStats:bw bh:bh];
    [self buildHUD:sel bw:bw bh:bh];
    [self buildControlPanel:bw bh:bh];
    id<MTLBuffer> hb = _hudBuffers[_frameIndex];
    NSUInteger hc = _hud.size();
    if (hc) memcpy([hb contents], _hud.data(), hc*sizeof(InstC));

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:_groundPipeline];
    [enc setFragmentBytes:&uni length:sizeof(uni) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    if (ic) {
        [enc setRenderPipelineState:_entityPipeline];
        [enc setVertexBuffer:ib offset:0 atIndex:0];
        [enc setVertexBytes:&uni length:sizeof(uni) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:ic];
    }
    // Sky / weather wash over the world (before the HUD, so panels stay crisp).
    [enc setRenderPipelineState:_skyPipeline];
    [enc setFragmentBytes:&uni length:sizeof(uni) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    // Bioluminescent halos: drawn AFTER the night wash so they add light on top
    // of the darkened scene rather than being dimmed along with it.
    if (gcnt) {
        [enc setRenderPipelineState:_entityPipeline];
        [enc setVertexBuffer:gb offset:0 atIndex:0];
        [enc setVertexBytes:&uni length:sizeof(uni) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:gcnt];
    }
    if (hc) {
        [enc setRenderPipelineState:_hudPipeline];
        [enc setVertexBuffer:hb offset:0 atIndex:0];
        [enc setVertexBytes:&uni length:sizeof(uni) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6 instanceCount:hc];
    }
    [enc endEncoding];

    dispatch_semaphore_t sem = _frameSemaphore;
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> cb){ (void)cb; dispatch_semaphore_signal(sem); }];
    [cmd presentDrawable:drawable];
    [cmd commit];
    _frameIndex = (_frameIndex + 1) % kMaxInFlight;

    int males = 0, females = 0, sick = 0, living = 0;
    for (const Critter &c : _critters) {
        if (!c.alive) continue;
        living++; if (c.male) males++; else females++; if (c.sick>0) sick++;
    }
    const char *band = _climate < -0.33f ? "COLD" : (_climate > 0.33f ? "HOT" : "TEMPERATE");
    view.window.title = [NSString stringWithFormat:
        @"09 — BIOME v37 (Bubble Burrower) ▸ prey %d (%dM/%dF) ▸ pred %d ▸ nests %d ▸ gen %d ▸ births %d deaths %d ▸ sick %d ▸ %s %+.2f ▸ x%.2g%s ▸ %.0f fps",
        living, males, females, (int)_predators.size(), (int)_nests.size(),
        _generation, _births, _deaths, sick, band, _climate, _timeScale, _paused ? " PAUSED" : "", _smoothedFPS];
}

// ------------------------------------------------------------- Inspector ---

// Top-center population readout: living count, total deaths, and net growth /
// decline since the colony started.
- (void)buildStats:(float)bw bh:(float)bh {
    auto rect = [&](float x, float y, float w, float h, simd_float4 c, float s) {
        float cx = (x+w*0.5f)/bw*2.0f-1.0f, cy = (y+h*0.5f)/bh*2.0f-1.0f;
        [self hud:cx cy:cy hw:w/bw hh:h/bh shape:s color:c p0:0];
    };
    float sw = 384, sh = 34, sx = (bw - sw) * 0.5f, sy = bh - 14 - sh;
    rect(sx, sy, sw, sh, simd_make_float4(0.05f,0.06f,0.09f,0.85f), 6);
    simd_float4 lab = simd_make_float4(0.55f,0.68f,0.85f,1);
    simd_float4 val = simd_make_float4(0.96f,0.98f,1.0f,1);

    int pop = 0; for (const Critter &c : _critters) if (c.alive) pop++;
    int growth = _initialPop > 0 ? (int)lroundf((pop - _initialPop) * 100.0f / _initialPop) : 0;
    simd_float4 gcol = growth >= 0 ? simd_make_float4(0.45f,0.90f,0.55f,1)   // green up
                                   : simd_make_float4(0.95f,0.45f,0.40f,1);  // red down
    char bPop[16], bDied[16], bGrow[16];
    snprintf(bPop, sizeof bPop, "%d", pop);
    snprintf(bDied, sizeof bDied, "%d", _deaths);
    snprintf(bGrow, sizeof bGrow, "%+d%%", growth);

    float ly = sy + 4, vy = sy + 17;
    [self hudText:"ORGANISMS" x:sx+14  y:ly h:9  col:lab bw:bw bh:bh];
    [self hudText:bPop        x:sx+14  y:vy h:13 col:val bw:bw bh:bh];
    [self hudText:"DEATHS"    x:sx+150 y:ly h:9  col:lab bw:bw bh:bh];
    [self hudText:bDied       x:sx+150 y:vy h:13 col:val bw:bw bh:bh];
    [self hudText:"GROWTH"    x:sx+270 y:ly h:9  col:lab bw:bw bh:bh];
    [self hudText:bGrow       x:sx+270 y:vy h:13 col:gcol bw:bw bh:bh];
}

// Evolution graph: the climate driver and the colony-average traits that
// track it, scrolling over the last ~kHistLen sim-seconds. Can be hidden with
// its X button; a small GRAPH tab brings it back.
- (void)buildEvoGraph:(float)bw bh:(float)bh {
    auto rect = [&](float x, float y, float w, float h, simd_float4 col, float shape) {
        float cx = (x + w*0.5f)/bw*2.0f-1.0f, cy = (y + h*0.5f)/bh*2.0f-1.0f;
        [self hud:cx cy:cy hw:w/bw hh:h/bh shape:shape color:col p0:0];
    };
    float gw = 360, gh = 150, gx = 16, gy = bh - 32 - gh;

    // Collapsed: just a little tab in the top-left corner to reopen it.
    if (!_showGraph) {
        float tw = 70, th = 22, tx = 16, ty = bh - 16 - th;
        rect(tx, ty, tw, th, simd_make_float4(0.10f,0.12f,0.16f,0.92f), 6);
        [self hudText:"GRAPH" x:tx+10 y:ty+6 h:11 col:simd_make_float4(0.8f,0.88f,1.0f,1)
                   bw:bw bh:bh];
        _widgets.push_back({tx, ty, tw, th, WA_ToggleGraph, 0});
        return;
    }

    const float legendH = 40.0f;                             // room for the labelled key below
    rect(gx-8, gy-8-legendH, gw+16, gh+32+legendH, simd_make_float4(0.05f,0.06f,0.08f,0.88f), 6);
    for (int k = 0; k <= 2; k++)                              // 0 / 0.5 / 1 grid
        rect(gx, gy + k*0.5f*gh, gw, 1, simd_make_float4(1,1,1,0.08f), 4);
    // y-axis hints: everything is plotted normalised 0..1.
    [self hudText:"1" x:gx-11 y:gy+gh-5 h:8 col:simd_make_float4(0.6f,0.66f,0.74f,1) bw:bw bh:bh];
    [self hudText:"0" x:gx-11 y:gy-2     h:8 col:simd_make_float4(0.6f,0.66f,0.74f,1) bw:bw bh:bh];
    // Title + hide (X) button in the top-right corner of the panel.
    [self hudText:"EVOLUTION" x:gx y:gy+gh+6 h:11 col:simd_make_float4(0.7f,0.82f,1.0f,1)
               bw:bw bh:bh];
    float xb = 18, xx = gx + gw - xb, xy = gy + gh + 4;
    rect(xx, xy, xb, xb, simd_make_float4(0.20f,0.22f,0.28f,1), 6);
    [self hudText:"X" x:xx+5 y:xy+4 h:11 col:simd_make_float4(0.9f,0.94f,1.0f,1) bw:bw bh:bh];
    _widgets.push_back({xx, xy, xb, xb, WA_ToggleGraph, 0});

    int count = _histCount, head = _histHead;
    auto plot = [&](const float *buf, simd_float4 col, float dot) {
        for (int k = 0; k < count; k++) {
            int idx = (head - count + k + kHistLen) % kHistLen;
            float v = std::clamp(buf[idx], 0.0f, 1.0f);
            float x = gx + (float)k/(kHistLen-1) * gw;
            float y = gy + v * gh;
            rect(x - dot*0.5f, y - dot*0.5f, dot, dot, col, 4);
        }
    };
    if (count >= 2) {
        plot(_histPop,  simd_make_float4(0.55f,0.55f,0.62f,0.7f), 2.0f);  // prey population
        plot(_histClim, simd_make_float4(1.00f,1.00f,1.00f,0.9f), 2.5f);  // climate (driver)
        plot(_histRes,  simd_make_float4(0.95f,0.70f,0.30f,1.0f), 2.5f);  // resistance
        plot(_histSize, simd_make_float4(0.35f,0.75f,0.95f,1.0f), 2.5f);  // avg size
        plot(_histDark, simd_make_float4(0.45f,0.90f,0.50f,1.0f), 2.5f);  // coat darkness
        plot(_histPred, simd_make_float4(0.90f,0.25f,0.20f,1.0f), 2.5f);  // predators
    }
    // Labelled legend (two rows of three) below the plot, so every line is
    // named. All series are normalised to 0..1 for a shared vertical scale:
    //   CLIMATE   cold(0) .. hot(1)          SIZE      colony-average body size
    //   DARKNESS  average coat darkness      RESIST    average disease resistance
    //   PREY      living colony (scaled)     PREDATORS hunter count (scaled)
    struct Lg { const char *name; simd_float4 col; };
    Lg lg[6] = {
        {"CLIMATE",   simd_make_float4(1.00f,1.00f,1.00f,0.9f)},
        {"SIZE",      simd_make_float4(0.35f,0.75f,0.95f,1.0f)},
        {"DARKNESS",  simd_make_float4(0.45f,0.90f,0.50f,1.0f)},
        {"RESIST",    simd_make_float4(0.95f,0.70f,0.30f,1.0f)},
        {"PREY",      simd_make_float4(0.55f,0.55f,0.62f,0.9f)},
        {"PREDATORS", simd_make_float4(0.90f,0.25f,0.20f,1.0f)},
    };
    simd_float4 lgTxt = simd_make_float4(0.82f,0.88f,0.95f,1);
    for (int k = 0; k < 6; k++) {
        float lx = gx + (k % 3) * 122.0f;
        float ly = gy - 17.0f - (k / 3) * 15.0f;
        rect(lx, ly, 12, 9, lg[k].col, 4);
        [self hudText:lg[k].name x:lx+16 y:ly h:9 col:lgTxt bw:bw bh:bh];
    }
}

- (void)buildHUD:(Critter *)sel bw:(float)bw bh:(float)bh {
    auto rect = [&](float x, float y, float w, float h, simd_float4 col, float shape) {
        float cx = (x + w*0.5f)/bw*2.0f-1.0f, cy = (y + h*0.5f)/bh*2.0f-1.0f;
        [self hud:cx cy:cy hw:w/bw hh:h/bh shape:shape color:col p0:0];
    };
    if (!sel) return;
    float px = 16, py = 16, panW = 360, panH = 312;
    rect(px-8, py-8, panW+16, panH+16, simd_make_float4(0.05f,0.06f,0.08f,0.88f), 6);

    // Trait bars, colored by group: physiology (blue), morphology (green),
    // condition (amber). Two columns.
    simd_float4 cPhys  = simd_make_float4(0.35f,0.75f,0.95f,1);
    simd_float4 cMorph = simd_make_float4(0.45f,0.90f,0.50f,1);
    simd_float4 cState = simd_make_float4(0.95f,0.70f,0.30f,1);
    const Phenotype &q = sel->ph;
    struct Bar { float v; simd_float4 c; };
    Bar bars[16] = {
        {(q.size-0.6f)/1.1f, cPhys}, {q.speed/16.0f, cPhys},
        {q.metabolism/1.7f, cPhys}, {(q.sensory-10.0f)/15.0f, cPhys},
        {q.fertility, cPhys}, {q.resistance, cPhys},
        {q.aspect, cMorph}, {q.girth, cMorph}, {q.eyeSize/0.25f, cMorph},
        {q.snout, cMorph}, {q.spikes, cMorph}, {q.pattern, cMorph},
        {sel->energy, cState}, {sel->hunger, cState}, {sel->health, cState},
        {std::clamp(sel->age/(q.lifespan*_lifespanMul),0.0f,1.0f), cState},
    };
    float by0 = py + 34;
    for (int i = 0; i < 16; i++) {
        float bx = px + (i/8) * 180.0f;
        float y = by0 + (i%8) * 17.0f;
        rect(bx, y, 150, 11, simd_make_float4(0.15f,0.16f,0.18f,1), 4);
        rect(bx, y, 150*std::clamp(bars[i].v,0.0f,1.0f), 11, bars[i].c, 4);
    }
    // Heritable temperament — this critter's personality, drives its choices.
    {
        simd_float4 cTemp = simd_make_float4(0.76f,0.56f,0.96f,1);
        float tvals[4] = {q.boldness, q.sociability, q.curiosity, q.activity};
        const char *tlab[4] = {"BOLD","SOCIAL","CURIOUS","ACTIVE"};
        float ty = by0 + 8*17.0f + 6;
        [self hudText:"TEMPERAMENT" x:px y:ty h:9 col:simd_make_float4(0.72f,0.70f,0.82f,1) bw:bw bh:bh];
        for (int i = 0; i < 4; i++) {
            float bx = px + i*88.0f, y = ty + 15;
            [self hudText:tlab[i] x:bx y:y h:8 col:simd_make_float4(0.72f,0.66f,0.84f,1) bw:bw bh:bh];
            rect(bx, y+11, 78, 8, simd_make_float4(0.15f,0.16f,0.18f,1), 4);
            rect(bx, y+11, 78*std::clamp(tvals[i],0.0f,1.0f), 8, cTemp, 4);
        }
    }
    // Coat swatches (primary + secondary), an eye showing iris color, sex bar.
    rect(px+300, py+34, 44, 30, simd_make_float4(q.color, 1.0f), 4);
    rect(px+300, py+66, 44, 30, simd_make_float4(q.color2, 1.0f), 4);
    rect(px+300, py+100, 26, 26, simd_make_float4(q.eyeColor, 1.0f), 3);  // eye icon
    rect(px+330, py+104, 14, 18,
         sel->male ? simd_make_float4(0.4f,0.6f,1.0f,1.0f)
                   : simd_make_float4(1.0f,0.5f,0.7f,1.0f), 4);

    // Genome strip: both homologs, each gene's 16 bases as colored ticks
    // (A green, C blue, G yellow, T red).
    float gy = py + panH - 84;
    float tickW = (panW - 16) / (float)(kNumGenes * 16);
    simd_float4 baseCol[4] = {
        simd_make_float4(0.30f,0.85f,0.35f,1), simd_make_float4(0.30f,0.55f,0.95f,1),
        simd_make_float4(0.95f,0.85f,0.30f,1), simd_make_float4(0.95f,0.35f,0.30f,1),
    };
    for (int h = 0; h < 2; h++)
        for (int g = 0; g < kNumGenes; g++) {
            uint32_t word = sel->genome.hom[h][g];
            for (int b = 0; b < 16; b++) {
                int base = (word >> (2*b)) & 3;
                float x = px + (g*16 + b) * tickW;
                rect(x, gy + h*32, tickW*0.9f, 26, baseCol[base], 4);
            }
        }
    // Header numbers: id, age, generation.
    [self hudNumber:(int)sel->id x:px y:py dw:6 dh:11 col:simd_make_float4(1,1,1,1) bw:bw bh:bh];
    [self hudNumber:(int)sel->age x:px+120 y:py dw:6 dh:11 col:simd_make_float4(0.8f,0.9f,1,1) bw:bw bh:bh];
    [self hudNumber:sel->generation x:px+230 y:py dw:6 dh:11 col:simd_make_float4(0.7f,1,0.7f,1) bw:bw bh:bh];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}
@end

int main() {
    return RunMetalApp(@"09 — BIOME v37 (Bubble Burrower)", 1280, 1000, ^(MTKView *view) {
        return (NSObject<MTKViewDelegate> *)[[BiomeRenderer alloc] initWithView:view];
    });
}
