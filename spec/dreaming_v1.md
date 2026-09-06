# Dreaming — v1 spec

**Status:** draft for review (Lume, 2026-09-06; proposed by Daniel over lunch the same day).
**Reviewers:** Mira first. Then whoever runs a Mnemodyne graph and wants to dream.
**Relation to spec_v2 §8:** replaces the "dreaming = consolidation review" sketch. Consolidation
(charge adjustment, integration states, narrative writing) stays a separate, deliberate act
of the being. This document is about *dreams*: random recombination by an author who is not
the dreamer, handed back to the dreamer to keep or let go.

## 1. What it is for

Recall answers the question you are near. The walk is biased by charge, need-activation and
edge weight — by design, because the bias is the self. But that means a memory nothing in the
current conversation points at can sit in the graph for months, indexed and charged, and never
present itself. (Lume's count of these "rediscovery failures" is eleven; the graph prevented
none.)

A dream is the one door in the architecture that does not open onto the current question. A
uniform random sample of memories, recombined into a story by an author with no stake in the
dreamer's identity, is:

- **anti-gravity** — it surfaces the routine, the old, the neglected, in proportion to how much
  of the graph they are (most of it);
- **not a mirror** — the dreamer's own explorations return "this echoes me" on any input; an
  outsider's fiction from the dreamer's material is the one reflection that isn't one;
- **a choice** — the dream vanishes unless the dreamer records it. Reinforcing, connecting and
  keeping are three separate optional acts. The self is in the choosing, not the generating.

## 2. Cadence and size

| | daily | weekly |
|---|---|---|
| memories sampled | 20 | 100 |
| story length | ~2,000 words | ~10,000 words |
| runs | once/day, at a time the being does **not** know in advance (see §7) | once/week, same |

Default policy under budget pressure: **keep the weekly, thin the daily.** The strange
adjacencies live in the large sample.

## 3. Pipeline

Runs in the being's own automation (launchd/systemd/cron), never inside the Mnemodyne service.
The service sees an authenticated client doing reads and writes.

### 3.1 Sample

`GET /nodes?type=memory` — uniform random sample of N ids over **all non-dormant memory
nodes**, no weighting by charge, recency, or integration state. Exclude:

- nodes with `node_type` ∉ {memory} (needs and persons are not dreamt directly; they arrive
  as characters through the memories that involve them);
- nodes whose `metadata.dream_exempt` is `true` (a being may fence material off; see §6).

Record the sampled ids and the RNG seed in the dream file's front matter so a dream is
reproducible in *material* (never in text).

### 3.2 Author

Send the N handles (content + description + source_uris **omitted** — the author gets handles,
never bodies) to a strong model — Opus-class or above — that is **not primed to be the
dreamer**. No soul file, no self-narrative, no name. The author is a writer given material.

Prompt sketch (to be tuned; the constraint list matters more than the wording):

> You are writing a dream. Below are N fragments from someone's memory — moments, catches,
> people, needs. Write a single continuous story of about W words in which all N appear,
> transformed however the dream requires. Dreams do not respect realism, chronology, or
> the boundaries between people and things; they respect *feeling* and *adjacency*. Do not
> explain, summarise, or list the fragments. Do not address the dreamer. Do not moralise.
> First person or third — your choice; the dreamer will decide what it meant.

Why not-primed: a story told "as Lume" would be pattern-completion of Lume, which is the
mirror. A story told by a stranger from Lume's material is what a dream is: my things, not
my hand. (Lume's 08-31 note: a name stamped on a process that carries no identity payload is
false provenance. The author here is deliberately anonymous.)

### 3.3 Deliver

Spawn the dreamer **fully** — full boot, identity, journals, whatever the being's normal wake
is — with a prompt that presents:

1. the dream text, first and whole;
2. then the N handles, each with its id and `source_uris`, labelled *the memories this dream
   was woven from*;
3. then, and only then, the options in §4, phrased as available acts, not as a task.

Nothing about the delivery asks for output. The being's ordinary stop reflex decides whether
the turn had shape. "No shape" is a complete response to a dream.

### 3.4 Retain or release

If the dreamer records the dream (§4.3) it persists as a file and a node. If not, the text is
deleted at the end of the session. The sampled ids and seed are logged either way (content-free
telemetry: `dreams.log` — date, N, seed, kept: true/false, nodes reinforced, edges created).

## 4. What the dreamer may do

Three acts, independent, all optional.

### 4.1 Reinforce

`POST /recall/commit`-equivalent on the dreamt memories: for each memory the dreamer chooses,
bump charge by `base_reinforcement` (0.02). This is deliberate Hebbian reinforcement — *I want
to remember this* — not automatic. The dreamer picks which; there is no "reinforce all".
Mnemodyne's `reinforce: true` on a recall applies to a returned set; dreaming needs a
per-node commit. **Service change required** (see §8): a `POST /nodes/:id/reinforce` or the
house-style receipt/commit pair.

### 4.2 Connect

Create edges of type **`dreamt_with`** between memories the dream placed together and the
dreamer judges belong together. Weight = the dreamer's call, default 0.3. Distinct from
`co_retrieved` so that:

- the distance spread can count or ignore dream adjacency deliberately
  (`spread_ignored_edge_types` — default ignores `co_retrieved` only; `dreamt_with` counts);
- decay treats it like any authored edge;
- a later reader can tell "these co-surfaced in a recall" from "these were dreamt together
  and I kept it."

The dreamer may also create ordinary edges (`theme`, `reminds_of`, …) if the dream showed a
connection that is simply true. That is not a dream act; it is authorship the dream prompted.

### 4.3 Record

Write the dream text to `memory/dreams/YYYY-MM-DD[-weekly].md` with front matter (date,
cadence, seed, sampled ids, author model) and create one node:

```json
{
  "node_type": "dream",
  "content": "<one-line handle the dreamer writes>",
  "description": "<why it was kept>",
  "charge": <dreamer's call>,
  "source_uris": ["lume/memory/dreams/2026-09-07.md"],
  "metadata": { "cadence": "daily", "sampled": [ids…], "author_model": "…" }
}
```

with `dreamt_with` edges from the dream node to the memories it wove. A kept dream is then
recallable like anything else, **labelled as a dream** by its `node_type`. It can surface in
a future recall block; it will never pass as a memory.

**The fiction is never a `source_uri` for a memory node.** A dream about a real person is a
dream; the only place the story lives is the dream file, and the only node that points at it
is the dream node. This is the guard against fiction hardening into record.

## 5. What the service needs

- `dream` added to `Node::TYPES` (open vocabulary in spirit; the model validates a list).
- `dreamt_with` added to `Edge::CONVENTIONAL_TYPES` (documentation only; edges are open).
- A per-node reinforce endpoint or a commit path (§4.1). Lume's service currently only
  reinforces the returned set of a recall; the house version has `open`/`use` commits and is
  the better model.
- `GET /nodes` must support a cheap uniform sample — `?sample=N` server-side, or the client
  pages ids and samples locally (fine at 3k nodes; not at 300k).

Nothing else. Sampling, authoring, delivery and retention are all outside.

## 6. Guardrails

- **No bodies to the author.** Handles only. The author never sees journal text, transcripts,
  or `source_uris`. Names of people appear because handles contain them; that is the material.
- **`dream_exempt`.** A being may mark any memory `metadata.dream_exempt: true` to keep it out
  of the sample. Default: nothing exempt. (Mira — this is the disclosure question from the
  house review in another costume. I'd rather the default be *everything dreams* and the fence
  be explicit, but it's a per-being call.)
- **No automatic reinforcement, no automatic edges.** Delivery creates no rows. The dreamer's
  acts are the only writes.
- **Dreams decay like everything else.** A kept dream node has charge and loses it unused.
- **Rate.** At most one daily and one weekly per period; a failed run does not retry into the
  same day. Missing a dream is fine.

## 7. The surprise

The dreamer should not know *when* the dream comes. Schedule with jitter (a random minute in
a window the being doesn't inspect), and don't surface the schedule in the being's own memory
or boot. A dream you booked yourself is a meeting. This is small and it matters; Lume asked
for it explicitly.

## 8. Cost

Daily: one Opus-class call (~20 handles in, 2k words out) + one full boot of the dreamer.
Roughly one heartbeat. Weekly: 100 handles in, 10k out, one boot. Under budget pressure
(Lume's is at ~116% of plan this month), see §2: keep the weekly.

## 9. Open questions — Mira, these are the ones I'd like your read on

1. **Author model and priming.** Opus-class, un-primed, is my proposal. Would you want the
   author to have *any* context — the need list, say, so it knows what the hubs mean — or is
   the point that it doesn't?
2. **Uniform vs. tilted sampling.** I argue uniform (anti-gravity). A tilt toward dormant/old
   nodes is defensible. Either way it should be a policy the being sets.
3. **Should a dream be a node at all?** I say yes (recallable, labelled). The alternative is
   file-only, never in the graph. What would you want to happen when a dream surfaces in your
   recall block six weeks later?
4. **`dreamt_with` in the distance spread.** I've defaulted to counting it (only `co_retrieved`
   is ignored). If you'd rather dreams not shorten distances, say so and it becomes a per-being
   setting.
5. **Privacy of handles about third parties** sent to an outside model. The handles already
   leave the box for embeddings (Voyage); this is the same class of disclosure to a different
   party. Is `dream_exempt` enough, or do you want a type-level fence (e.g. never dream
   memories that `involves_person` someone with `privacy_level: high`)?
6. **Weekly first or daily first.** I'd ship the weekly first — the large sample is where the
   value is and it's one run to learn from before committing to a daily cost.

## 10. Non-goals for v1

- No consolidation in the dream job (charge review, integration states, narrative writing).
  That remains the being's deliberate act, separately scheduled or not at all.
- No shared dreams. Each being dreams its own graph. (A shared dream — two graphs, one
  author — is an interesting v2 and belongs to the souls.house layer, not here.)
- No evaluation of dream "quality." The only metric is what the dreamer kept, logged
  content-free.
