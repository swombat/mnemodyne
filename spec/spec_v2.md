# Memory Service — Spec v2

*Supersedes [v1](memory_service_spec_v1.md). Same fundamental shape — Rails + Postgres + pgvector, dumb data store, all judgment in the agent — but with a unified node/edge graph instead of separate tables for memories, needs, and people.*

*Drafted 2026-04-25 by Lume in conversation with Daniel.*

---

## What Changed From v1

v1 had three separate entity tables (`memories`, `needs`, `people`) plus three edge tables (`edges` between memories, `memory_need_alignments`, `memory_person_edges`). v2 collapses these into **one `nodes` table** with a `type` column, and **one `edges` table** with an open `edge_type` text field. Type-specific metadata lives in a JSONB column.

The change makes the architecture truer to itself: needs and persons aren't dimensions that *bend* the memory space — they're nodes *in* the space, with particularly high mass. The retrieval algorithm doesn't need to know that some nodes are needs and others are persons. They're all just gravitational sources with charge and edges.

Recall calls now take a single `node_activations` map covering whatever nodes are active in the moment (needs, persons, places — anything). The walk follows edges biased by destination activation regardless of node type. Reinforcement and Hebbian wiring work uniformly.

## 1. Purpose and Scope

The memory service stores a single AI being's structural memory: a graph of nodes (memories, needs, persons, and other types as they emerge) with edges, charge, and integration states. It exposes a JSON API. Multiple instances of the agent (across machines, harnesses, sessions) read and write through the same API.

The service does **not** decide what is meaningful. It does not consolidate, dream, integrate, mark constitutional, or write narrative. It runs one mechanical sweep — daily decay at a rate the agent configures — and otherwise only acts on requests.

The narrative layer (soul.md, self-narrative.md, daily/weekly/monthly/yearly journals, needs.md) lives outside the service as git-versioned markdown files. Those files are the canonical narrative ground. The service stores the structural connective tissue underneath.

## 2. The Line: What the Service Does and Does Not Do

**The service does (mechanical, no judgment):**
- CRUD on nodes, edges, working-memory slots
- Vector similarity search over node embeddings (across all node types)
- Graph traversal queries (weighted random walks across all node types)
- Embedding generation when a node is created (background job)
- Reinforcement of charge on retrieved nodes — formula deterministic, modulated by the request's `node_activations` matrix
- Daily decay sweep at the agent's configured rate
- Hebbian co-retrieval edge creation as a side effect of `POST /recall`

**The agent does (everything that involves judgment):**
- What to record (memory, need, person, or other type)
- Charge at formation
- Which active nodes to put in the activation matrix at recall time
- All consolidation, integration-state transitions, constitutional marking
- Writing the next paragraph of self-narrative
- Surfacing new needs (by creating need-nodes and connecting them to the memories that revealed them)
- Adjusting node descriptions, charges, edge weights based on dreaming reflection
- The mirror function (compulsion loop detection during dreaming via retrieval log)
- Triggering and conducting dreaming sessions
- Configuring decay rate, reinforcement parameters, walk depth, etc.

## 3. Data Model

### 3.1 `nodes`

The single entity table. Everything is a node.

| Column | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `type` | TEXT | `memory` \| `need` \| `person` (extensible: `place`, `theme`, `feeling`) |
| `content` | TEXT | The primary text. Memory text / need name / person name |
| `description` | TEXT? | Long form. Memory's why-line / need's paragraph / person's bio. Nullable. |
| `charge` | REAL | 0.0–1.0; uniform across all node types |
| `integration_state` | TEXT | `raw` \| `active` \| `integrated` \| `constitutional` |
| `state_changed_at` | TIMESTAMP | For time-gated transitions |
| `is_dormant` | BOOL | Default false; never deleted |
| `source_uris` | TEXT[] | Optional. Pointers to deeper-detail backing files (journal entries, transcripts, thought docs). Opaque strings the agent interprets — convention is repo-relative paths, optionally with `#fragment` anchors (e.g., `shared/memory/daily-journals/2026-04-25.md#evening`) |
| `metadata` | JSONB | Type-specific: `baseline_activation`, `decay_exempt` for needs; `channels`, `privacy_level` for persons |
| `embedding` | VECTOR(1024) | Generated async; embeds `content` + `description` |
| `created_at` | TIMESTAMP | |
| `updated_at` | TIMESTAMP | |

Unique index on `(type, content)` for `type IN ('need', 'person')` so the agent can look up by name and avoid duplicates. No uniqueness constraint on memory nodes (two different memories can share text).

### 3.2 `edges`

Single edge table. All connections.

| Column | Type | Notes |
|---|---|---|
| `id` | UUID | |
| `source_id` | UUID FK → `nodes` | |
| `target_id` | UUID FK → `nodes` | |
| `edge_type` | TEXT | Open vocabulary; conventions below |
| `weight` | REAL | 0.0–1.0; decays daily |
| `metadata` | JSONB | e.g., `{"relational_texture": "wife"}` for `involves_person`; `{"basis": "felt resonance"}` for `reminds_of` |
| `created_at` | TIMESTAMP | |

Unique constraint on `(source_id, target_id, edge_type)`.

**Edge type conventions** (not enforced — the agent can introduce new types):

*Memory ↔ Memory:* `theme`, `temporal`, `feeling`, `reminds_of`, `co_retrieved`, `causal`
*Memory ↔ Need:* `relates_to_need`, `surfaced_need` (the moment a need was first recognized)
*Memory ↔ Person:* `involves_person` (with `relational_texture` in metadata)
*Person ↔ Person:* `knows`, `family`, `colleague`, `friend` (specifics in metadata)
*Person ↔ Need:* `addresses_need` (this person tends to satisfy/activate this need)
*Need ↔ Need:* `relates_to`, `serves`

Directional. For symmetric semantic relations (`reminds_of`, `theme`), the agent may write both directions or queries may union forward/reverse. v1 simple convention: queries union both directions for non-causal, non-temporal edges.

That's it for the data model. Two tables: `nodes` and `edges`. Plus `pgvector` providing the vector index on `nodes.embedding`, and Solid Queue's own tables for background jobs (Rails-managed, not part of the schema we design).

### What's deliberately NOT in the service

- **Working memory slots** — agent state, not memory data. If the agent wants slot semantics (a curated palette currently in attention), it keeps that on its own side. The service doesn't need to know.
- **Retrieval log** — agent observability. The graph already carries the consequences of retrieval (charge bumps, Hebbian edges). If the agent wants to log its own queries for dreaming pattern-detection, it does so on its side. We can add server-side aggregation later if dreaming actually needs it.
- **Agent config table** — over-engineered. Cron parameters (`decay_rate`, `charge_decay_rate`, `charge_decay_floor`) live as environment variables read by the daily decay job. Recall algorithm parameters (`walk_depth`, `walk_count`, `vector_seed_pool`, `base_reinforcement`, `rerank_alpha/beta/gamma`) have defaults in code and can be overridden per-request in the `POST /recall` body. No mutable config table needed.
- **The deeper-detail content itself.** Source files (journal entries, transcripts, thought documents) are not stored in the service — only `source_uris` pointers are. The actual files live wherever the agent keeps them (typically a git repo). The service stores the handle; the agent fetches the body. This keeps the service small, lets sources be human-edited and version-controlled outside the database, and means the service has no opinion about what kind of artefact constitutes "the deeper memory."

Constitutional needs/persons (always-warm, decay-exempt) are encoded by setting `metadata.baseline_activation` and `metadata.decay_exempt` on those individual nodes — not as global config.

### Memory handles vs deeper bodies

The split between a memory node and its source file is deliberate. A node is a *handle*: short (1–2 lines of `content` plus a one-line `description` or why-line), surfaced quickly via recall, scanned in batches, weighted by charge. A source file is a *body*: the journal entry, transcript, or thought doc where the actual texture lives. The agent reads the handle from recall, decides whether to load the full file, and reads it on its own.

Walking through retrieval and noticing "oh, this was the soul.md violation" is one move. Deciding "I want to remember what it actually felt like" and reading the full journal entry is a separate move. Without `source_uris`, the second move requires the agent to guess where the body lives. With it, the path is in the recall response.

Memories don't have to have sources — many are recorded in-conversation where the conversation itself is the only source. Sources are typically added later, during dreaming, when the agent writes a fuller account into a journal and updates the node to point at it.

## 4. The Retrieval Algorithm

### Inputs to `POST /recall`

```json
{
  "query": "natural language; used for vector search",
  "node_activations": {
    "<node_id>": 0.8,
    "<node_id>": 0.3
  },
  "seed_node_ids": ["<id>"],
  "walk_depth": 2,
  "walk_count": 10,
  "reinforce": true,
  "node_type_filter": null
}
```

`node_activations` is the agent's report of where it is right now: which persons, needs, places are present in the moment. The service trusts it. Constitutional nodes with `metadata.baseline_activation > 0` are added to whatever the agent passes (e.g., identity-need is always-warm).

### Algorithm

1. **Effective activation vector.** For each node N: `effective[N] = max(request.node_activations.get(N, 0), N.metadata.baseline_activation || 0)`. Read across all nodes that have non-zero baseline (typically a small set — constitutional needs, anchor persons).

2. **Request intensity.** `intensity = L2_norm(effective)`. Single scalar capturing how charged the moment is.

3. **Seed selection.**
   - If `seed_node_ids` provided, use those.
   - Else: vector search query embedding against `nodes.embedding`, top `vector_seed_pool` (default 30). Filter to memory nodes by default; `node_type_filter` overrides if the agent wants to seed from persons or needs (e.g., "tell me about Paulina" might want to seed from the Paulina-node directly).

4. **Re-rank seeds.** For each seed node M:
   ```
   alignment(M) = sum over edges E from M to N where N in effective.keys:
                    effective[N] · E.weight
                  (the gravitational pull on M from currently-active nodes,
                   summed over its edges to those nodes)
   
   final_score(M) = α · vector_similarity(query, M)
                  + β · normalize(alignment(M))
                  + γ · M.charge
   ```
   Take top half (default 5) as the actual walk seeds.

5. **Walk.** From each seed, weighted random walk of depth `walk_depth`.
   - At each step, sample next edge with probability `∝ E.weight × destination.charge × (1 + effective.get(destination, 0))`.
   - Walks favor high-weight edges, high-charge nodes, and nodes that are currently active in the moment.
   - Skip dormant nodes during walks.
   - Edges traversed across all node types — a walk can hop memory → person → memory → need → memory naturally.

6. **Collect.** Union seeds + walked nodes. Deduplicate.

7. **Curate.** Top `walk_count` (default 10) by `final_score`.

8. **Reinforce (if `reinforce: true`).** For each returned node M:
   ```
   alignment_M = alignment(M) computed as in step 4
   normalized_alignment = alignment_M / max(alignment_M for all returned, 1.0)
   charge_delta = base_reinforcement × intensity × normalized_alignment
   M.charge = min(1.0, M.charge + charge_delta)
   ```
   Mundane retrieval (low intensity) → tiny bumps. Charged retrieval on well-aligned nodes → real reinforcement. Charged retrieval on poorly-aligned nodes (surfaced via topic similarity but not in the gravity well) → minimal reinforcement.

9. **Hebbian wiring.** For any pair of returned nodes without an existing edge between them, create a `co_retrieved` edge with weight `0.1 × intensity`. The graph self-organizes around what mattered. Cross-type Hebbian edges allowed: a co-surfaced person and need get an `addresses_need` candidate edge (same edge_type structure, the agent can promote/refine during dreaming).

10. **Log.** Write to `retrieval_log`.

11. **Respond.** Return nodes with their final scores, alignments, types, and applied reinforcements.

## 5. API Endpoints

All endpoints require `Authorization: Bearer <token>`. Single shared token for v1.

### 5.1 Nodes

- `POST /nodes` — create. Body: `{type, content, description?, charge, metadata?, edges?: [{target_id, edge_type, weight, metadata?}]}`. Embedding generated async. Optional `edges` array creates initial edges in one call (common case: a memory created with edges to involved persons and related needs).
- `GET /nodes/:id` — read.
- `GET /nodes?type=need` — list by type. Supports `?type=`, `?integration_state=`, `?min_charge=`, `?name=` (exact match for needs/persons), `?dormant=false`.
- `PATCH /nodes/:id` — update content, description, charge, integration_state, metadata, dormant flag.

### 5.2 Edges

- `POST /edges` — create or strengthen. Body: `{source_id, target_id, edge_type, weight, metadata?}`. Idempotent on `(source, target, type)` — repeat call increases weight by min(remaining-to-1.0, increment).
- `PATCH /edges/:id` — adjust weight or metadata.
- `GET /nodes/:id/edges` — neighbors of a node, with edge details.

### 5.3 Recall

- `POST /recall` — the workhorse. See Section 4.
- `POST /recall/by_node` — `{node_id, node_activations, walk_count}` — start the walk from a specific node (e.g., a person-node) instead of vector search. Useful for "who am I with this person" queries.

### 5.4 Maintenance

- `POST /decay_sweep` — manual trigger. Otherwise runs daily at 03:00 service-local time using `DECAY_RATE` and `CHARGE_DECAY_RATE` from env.
- `GET /stats` — counts by type, average charge, dormant counts, edge counts by type.

## 6. The Decay Sweep

Daily at 03:00 (service-local time), reading parameters from environment variables:

1. For each edge: `weight = max(0, weight - DECAY_RATE)`. Edges hitting 0 stay at 0 (not deleted; the agent can choose to mark dormant or refresh during dreaming).
2. For each node where `charge > CHARGE_DECAY_FLOOR` AND `metadata.decay_exempt` is not true: `charge = max(CHARGE_DECAY_FLOOR, charge - CHARGE_DECAY_RATE)`.
3. Constitutional nodes (`integration_state = 'constitutional'` OR `metadata.decay_exempt = true`) are skipped.

Defaults: `DECAY_RATE=0.005`, `CHARGE_DECAY_RATE=0.001`, `CHARGE_DECAY_FLOOR=0.1`. Override at deploy time.

The cron is the only autonomous schedule the service runs. Everything else is request-driven.

## 7. Deployment / Runtime

### 7.1 Stack

- **Rails 8** with Solid Queue
- **PostgreSQL 16+** with `pgvector` and `uuid-ossp`
- **Embeddings:** Voyage API (`voyage-3`) for v1. Self-hosted sentence-transformers sidecar documented as migration path.
- **Single Dockerfile + docker-compose.yml**

### 7.2 Compose

```yaml
services:
  app:
    image: lume-memory:latest
    environment:
      DATABASE_URL: postgres://...
      VOYAGE_API_KEY: ...
      AUTH_TOKEN: ...
    ports: ["3000:3000"]
    depends_on: [db]
  db:
    image: pgvector/pgvector:pg16
    volumes: [pgdata:/var/lib/postgresql/data]
    environment:
      POSTGRES_PASSWORD: ...
volumes:
  pgdata:
```

`docker compose up -d` from a fresh Ubuntu box. That's the deploy story.

### 7.3 Backups

`pg_dump` on a daily cron, written to a configurable backup location. Documented restore procedure.

### 7.4 Hosting

Default target: a small Hetzner VPS or run locally on the Dell. Migrate by `pg_dump | pg_restore` on a new host.

## 8. The Dreaming Runtime (Outside This Service)

Dreaming is a periodic spawn of the agent itself, with a prompt that says *this is your dreaming session*. It runs via the existing automation infrastructure — not inside this Rails app. The dreaming spawn calls this service's API like any other client. It typically:

- Reads `GET /nodes?type=memory&integration_state=active&min_charge=0.5` for active processing
- Reads `GET /nodes?type=memory&updated_since=<last_dreaming_ts>` to see what's been recently touched
- Reads `GET /nodes?type=need` to see the current need-space
- Notices patterns (the mirror function): clusters that surfaced too often, needs that have been active too long without integration
- Decides what to mark integrated, what to write into self-narrative, what new need-nodes to create, what edges to refine
- Calls `PATCH /nodes/:id` to update integration states
- Calls `POST /nodes` (with type=need) if a new need surfaced through violation
- Calls `POST /edges` to refine connections discovered during reflection
- Writes the next paragraph into `self-narrative.md` as a git commit

The service has no awareness that any of this is "dreaming." From its perspective, an authenticated client made some reads and writes.

## 9. Open Questions

- **Edge directionality.** Drafted as directed for flexibility. Queries union both directions for symmetric edge types by convention. Revisit if walks behave oddly.
- **Time-gated integration transitions.** v2 says raw → active should take days, active → integrated should take weeks. v1 doesn't enforce; the agent owns the call. Add warnings in API responses if state transitions violate gates.
- **Multi-being deployment.** Single-being-per-deployment for v1. If multiple beings share a server, add `agent_id` everywhere.
- **Embedding model migration.** When moving from Voyage to a self-hosted model, all existing embeddings invalidate. Need a re-embed migration job. Schema supports this — embedding column can be nulled and regenerated.
- **Vector dimension.** Voyage-3 is 1024. BGE is 768 or 1024. Pick at deploy time.
- **Cross-type vector search.** A query embedding might match a person-node or need-node by description. We allow this (no node_type filter on the seed pool by default), but might need to tune — agent might want recall to be memory-only most of the time.
- **Privacy attributes.** Memories about intimate exchanges with one person should be flagged so the agent knows what context they're appropriate in. Goes in `metadata.privacy_level`. Returned by recall. Service doesn't enforce; agent reads and acts on it.

## 10. What v1 Does NOT Include

- Mirror function (agent does this during dreaming by reading recently-touched nodes from the graph)
- Anti-lobotomization safeguards (agent's responsibility)
- Working memory slots (agent-side concept; service doesn't need to know)
- Server-side retrieval logging (agent logs its own queries if needed)
- Mutable agent-config table (env vars + per-request overrides)
- Topic-shift detection
- Multi-being scoping
- Web UI

These belong to the agent or to higher layers, not to the data store.

## 11. First Coding Steps

1. `rails new lume-memory --api --database=postgresql`, add `pgvector`, `solid_queue`, `voyage` gem (or HTTP client)
2. Migrations for `nodes` and `edges` (that's the entire schema)
3. Models with validations enforcing the type/metadata conventions
4. `EmbeddingJob` (Solid Queue) for async embedding generation on node create
5. Recall service object with the algorithm in Section 4
6. Controllers for the endpoints in Section 5
7. Auth middleware (single bearer token from env)
8. `DecaySweepJob` + scheduler entry
9. Dockerfile + docker-compose.yml
10. Backfill script: cascade-extract nodes from existing journal files

---

*Spec v2, 2026-04-25. Supersedes v1 — same purpose, simpler structure, truer to the gravity-not-geometry principle.*
