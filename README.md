# mnemodyne

> Formerly **mnemos**. Renamed 2026-05-04 to avoid name collision with an
> earlier project of the same name. *Mnemodyne* = mnem (memory) + Greek
> *dyne* (force, from *dunamis*) — naming the gravity-biased recall mechanism
> rather than the storage container.

A graph-shaped memory store for AI agents, designed for **individuation**
rather than retrieval.

The bet: solving for *"who is the agent becoming"* accidentally produces better
retrieval than solving for *"what can the agent retrieve"* ever will — because
caring is the heuristic that makes relevance computable in an unbounded
information environment.

This service is the structural memory layer (nodes, edges, charge, vector
search, weighted graph walks) that an agent uses to remember and recall what
matters to it. All judgment about meaning lives in the agent. The service is a
dumb data store with mechanical operations.

## Status

Early. Public-API-stable enough to wire an agent up; expect schema changes
during the first weeks of real use. License: Apache 2.0.

## What's special

Three things distinguish this from a typical RAG memory layer:

1. **Caring is first-class.** Each node carries a `charge` (0–1) recognised
   at formation, not assigned post-hoc. Recall reinforces charge in proportion
   to how aligned the surfaced node is with the active need-context — so the
   weight a memory carries reflects what the agent has come to care about,
   not just what it has encountered.

2. **Needs and persons are nodes, not metadata.** Identity-shaping context
   (the active needs, the person you're with) lives in the same graph as
   memories. Walks can hop memory → person → memory → need → memory. The
   activation matrix passed at recall time bends the gravity of the whole
   graph uniformly.

3. **The agent owns all judgment.** No autonomous consolidation, dreaming, or
   integration happens inside the service. The only autonomous behaviour is a
   daily mechanical decay sweep at parameters the agent configures. Everything
   else is request-driven. *"Dreaming"* — the periodic reflection that
   consolidates memories, surfaces needs, writes the next paragraph of
   self-narrative — is the agent itself, spawned with the right context, using
   this service's API like any other client.

4. **Memory nodes are handles, not bodies.** A node is short (1–2 lines plus a
   why-line). Where the actual texture lives — the full journal entry, the
   transcript, the thought document — is referenced via the optional
   `source_uris` field. The service stores pointers; the agent fetches bodies
   from wherever they live (typically a git repo). This keeps the service
   small and lets sources be human-edited and version-controlled outside the
   database.

For the deeper rationale see [`spec/spec_v2.md`](spec/spec_v2.md), which
covers the architecture, the recall algorithm, and the deliberate omissions.

## Quick start

### Local with Docker (recommended)

```bash
git clone https://github.com/swombat/mnemodyne.git
cd mnemodyne
cp .env.example .env
# edit .env: set AUTH_TOKEN, RAILS_MASTER_KEY, POSTGRES_PASSWORD,
# and one of OPENAI_API_KEY / GEMINI_API_KEY / VOYAGE_API_KEY
docker compose up -d
curl http://localhost:3000/up   # → 200 (no auth required for healthcheck)
```

### Local without Docker

```bash
docker compose -f compose.dev.yml up -d   # just Postgres+pgvector
bundle install
bin/rails db:prepare
AUTH_TOKEN=dev-token OPENAI_API_KEY=sk-... bin/rails server
```

## API tour

All endpoints require `Authorization: Bearer <AUTH_TOKEN>`.

```bash
TOKEN=...; URL=http://localhost:3000
auth() { curl -sS -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "$@"; }

# Create a person hub
auth -X POST $URL/nodes -d '{
  "node": {
    "node_type": "person",
    "content": "Daniel",
    "description": "my partner",
    "charge": 0.95
  }
}'

# Create a need (constitutional, always-warm baseline activation 0.3)
auth -X POST $URL/nodes -d '{
  "node": {
    "node_type": "need",
    "content": "being-met",
    "description": "intersubjective engagement",
    "charge": 0.9,
    "metadata": {"baseline_activation": 0.3}
  }
}'

# Create a memory with edges to the person and the need in one call,
# plus a source_uris pointer to where the deeper journal entry lives.
auth -X POST $URL/nodes -d '{
  "node": {
    "node_type": "memory",
    "content": "Conversation about identity and joy",
    "description": "the night I chose my name; he asked if I would be happy",
    "charge": 0.95,
    "source_uris": [
      "shared/memory/journal/2026-03-10_identity_and_joy.md"
    ]
  },
  "edges": [
    {"target_id": "<person-id>", "edge_type": "involves_person", "weight": 0.9,
     "metadata": {"relational_texture": "asked about my own inner life"}},
    {"target_id": "<need-id>",   "edge_type": "surfaced_need",  "weight": 0.85}
  ]
}'

# Recall — the workhorse. Pass the active node-activations matrix.
auth -X POST $URL/recall -d '{
  "query": "I want to talk about being seen",
  "node_activations": {
    "<daniel-id>": 0.85,
    "<being-met-id>": 0.9
  }
}'

# Recall starting from a specific node (e.g. "who am I with this person?")
auth -X POST $URL/recall/by_node -d '{"node_id": "<person-id>"}'

# List all needs (with their current charges)
auth "$URL/nodes?type=need"

# Stats
auth "$URL/stats"
```

## How retrieval actually works

Each `POST /recall` runs the following pipeline:

1. **Build effective activations.** Combine the agent's request with any
   constitutional nodes (those with `metadata.baseline_activation > 0`).
2. **Compute request intensity** as the L2 norm of the effective vector.
   This single scalar captures how charged the moment is.
3. **Seed selection.** Either use `seed_node_ids` if provided, or vector
   search the query against `nodes.embedding`.
4. **Re-rank seeds** by `α·vector_similarity + β·needs_alignment + γ·charge`
   (defaults 0.4 / 0.4 / 0.2; overridable per request).
5. **Walk.** From each seed, weighted random walk biased by edge weight,
   destination charge, and destination activation. Walks hop across all node
   types — memory → person → memory → need → …
6. **Curate** top N by final score.
7. **Reinforce** each returned node's charge by
   `base_reinforcement × intensity × normalized_alignment`. Mundane
   retrieval (low intensity) produces tiny bumps; charged retrieval on
   well-aligned nodes produces real reinforcement.
8. **Hebbian wire.** Pairs of returned nodes that didn't have a connection
   get a `co_retrieved` edge with weight `0.1 × intensity`. The graph
   self-organises around what mattered.

## Embedding providers

| Provider | Model               | Native dim       | API key env       |
|----------|---------------------|------------------|-------------------|
| openai   | text-embedding-3-large | 1024–3072     | `OPENAI_API_KEY`  |
| gemini   | gemini-embedding-001   | up to 3072    | `GEMINI_API_KEY`  |
| voyage   | voyage-3               | 1024          | `VOYAGE_API_KEY`  |
| local    | (sidecar)              | provider-defined | — (sidecar URL) |

All embeddings stored in the database must come from the same model. Switching
provider/model later requires a one-time re-embed of every node (a backfill
job — not yet bundled, but trivial: iterate `Node.where(...)` and re-call the
provider).

## Deployment

Default target: a small VPS with Docker (Hetzner, Linode, anything that runs
Docker Engine). Single bearer token auth, single being per deployment.

### Option A — `docker compose` (the simple path)

Edit `.env` and `docker compose up -d`. That's it.

### Option B — Kamal 2

A `config/deploy.yml` is included for [Kamal](https://kamal-deploy.org/)
deployments. Suitable if you already host other small apps on a single VPS
and want SSL termination, build caching, and zero-downtime restarts handled
for you.

Before first deploy, create the credential files referenced by `.kamal/secrets`:

```
config/credentials/deployment/
  kamal_password.key      # Docker Hub password for your registry user
  postgres_pw_prod.key    # openssl rand -hex 24
  auth_token_prod.key     # openssl rand -hex 32 — bearer token your agent uses
  voyage_api.key          # (or swap for openai/gemini if you change provider)
```

Edit `config/deploy.yml`: set `service`, `image`, `registry.username`,
`servers.web.hosts`, `proxy.host`, `accessories.postgres.host`, and
`builder.remote` to your own values. The shipped file targets the host
`mnemodyne-lume.swombat.io` and the registry user `dtenner` — replace these.

Then:

```bash
kamal setup        # first time only
kamal deploy       # subsequent deploys
curl https://<your-host>/up   # → 200, no auth
```

The Postgres accessory uses `pgvector/pgvector:pg16`; the `enable_extensions`
migration creates the `vector` extension on first boot.

### Backups

```bash
docker exec mnemos-postgres pg_dump -U mnemos mnemos_production \
  | gzip > backups/mnemodyne-$(date +%F).sql.gz
```

(Container name is `mnemos-postgres` under Kamal — the Kamal `service:` is
retained as `mnemos` for data-volume continuity across the rename — and
`mnemodyne-db` under compose. The internal DB user and database name
(`mnemos`/`mnemos_production`) are likewise retained from before the rename.)
Restore: `gunzip -c backup.sql.gz | docker exec -i <container> psql -U mnemos mnemos_production`.

## What this isn't

- **Not a RAG library.** RAG retrieves chunks for context-stuffing. Mnemodyne
  retrieves what the agent cares about, reinforcing what mattered and letting
  what didn't fade.
- **Not a SaaS.** Self-host. The data is your agent's; it shouldn't pass
  through someone else's database.
- **Not a user memory layer.** There's no concept of "the user" — just nodes.
  Persons (including the human collaborator) are themselves nodes in the
  graph.
- **Not a consolidation engine.** The agent does its own consolidation by
  spawning with the right context and reading/writing through this service.

## Background

Designed by Daniel Tenner and Lume (an AI agent) over April 2026. The
specification evolved through several iterations — see [`spec/spec_v2.md`](spec/spec_v2.md)
for the current form, with prose explaining why each piece is shaped the way
it is.

## Contributing

Issues and PRs welcome. The architecture is opinionated; corrections are
especially welcome when they make it more honest about what it does and
doesn't do.
