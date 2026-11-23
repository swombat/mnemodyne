#!/bin/bash
# Host-side deploy of swombat/mnemodyne <sha> for ONE instance on the misc host,
# mirroring what `kamal deploy` does, for when the machine holding the Kamal
# secrets can't run Kamal. Each being has its own instance (AUTH_TOKEN is one
# per process). Run ON the host as swombat:
#   GHTOKEN=<read token> bash host_deploy.sh <service> <full sha>
#
# Instances are a fixed table below: service -> hostname, env file, Postgres
# container. An unknown service is refused; adding a being (or renaming one)
# is an edit to this table, reviewed like any other change.
#
# Embedding model: a graph embedded with one model must be queried with the
# same one. The model is taken from the container the proxy is serving; if that
# container has no explicit VOYAGE_EMBEDDING_MODEL, or nothing is serving but
# the graph has memories, VOYAGE_MODEL must be given. Only an empty graph with
# nothing serving defaults (voyage-4). Before the swap, one stored memory is
# re-embedded with the new container's settings and must match its stored
# vector (cosine >= 0.98), so a model change cannot pass as exact-text recall.
#
# Touches <service>-web-* and the <service>-web proxy route only. Deploys are
# serialised per service. A candidate that fails before the swap is removed
# (never the container the proxy serves). The old container is stopped, not
# removed. Rollback:
#   docker start <old>; docker exec kamal-proxy kamal-proxy deploy <service>-web \
#     --target=<old hostname>:80 --host=<hostname> --tls --health-check-path=/up
set -euo pipefail
SERVICE="${1:-}"; SHA="${2:-}"
case "$SERVICE" in
  mnemos)            HOST=mnemodyne-lume.swombat.io;    PG=mnemos-postgres ;;
  mnemodyne-mira)    HOST=mnemodyne-mira.swombat.io;    PG=mnemodyne-mira-postgres ;;
  mnemodyne-sibling) HOST=mnemodyne-sibling.swombat.io; PG=mnemodyne-sibling-postgres ;;
  *) echo "usage: $0 <mnemos|mnemodyne-mira|mnemodyne-sibling> <full sha>"; exit 2 ;;
esac
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "full sha required"; exit 2; }
ENV_FILE="$HOME/.kamal/apps/$SERVICE/env/roles/web.env"
[ -f "$ENV_FILE" ] || { echo "no env file at $ENV_FILE"; exit 2; }

exec 9>"/tmp/mnemodyne-deploy-$SERVICE.lock"
flock -n 9 || { echo "another deploy of $SERVICE is running"; exit 2; }

# The env file must point at this instance's own Postgres (checked without
# printing it).
grep -q "^DATABASE_URL=postgres://[^@]*@$PG:5432/" "$ENV_FILE" \
  || { echo "DATABASE_URL in $ENV_FILE does not point at $PG"; exit 2; }

# The proxy is the authority on what is serving: hostname and target both.
plain(){ docker exec kamal-proxy kamal-proxy list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'; }
OTHER=$(plain | awk -v h="$HOST" -v s="$SERVICE-web" '$2==h && $1!=s {print $1}')
[ -z "$OTHER" ] || { echo "$HOST is routed to $OTHER, not $SERVICE-web"; exit 2; }
ROUTE_HOST=$(plain | awk -v s="$SERVICE-web" '$1==s {print $2}')
[ -z "$ROUTE_HOST" ] || [ "$ROUTE_HOST" = "$HOST" ] \
  || { echo "$SERVICE-web serves $ROUTE_HOST, not $HOST"; exit 2; }
TARGET=$(plain | awk -v s="$SERVICE-web" '$1==s {print $4}' | cut -d: -f1)
OLD=""
if [ -n "$TARGET" ]; then
  for c in $(docker ps --format '{{.Names}}' | grep "^$SERVICE-web-" || true); do
    [ "$(docker inspect -f '{{.Config.Hostname}}' "$c")" = "$TARGET" ] && OLD="$c"
  done
  [ -n "$OLD" ] || { echo "proxy targets $TARGET but no running $SERVICE-web-* has that hostname"; exit 2; }
fi
NEW="$SERVICE-web-$SHA"; IMG="dtenner/mnemodyne:$SHA"
[ "$OLD" != "$NEW" ] || { echo "already serving $NEW"; exit 2; }
if docker ps -a --format '{{.Names}}' | grep -qx "$NEW"; then
  docker rm -f "$NEW" >/dev/null && echo "removed leftover candidate $NEW (not serving)"
fi

MEMORIES=$(docker exec "$PG" sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "select count(*) from nodes where embedding is not null"' 2>/dev/null || echo 0)
if [ -z "${VOYAGE_MODEL:-}" ]; then
  if [ -n "$OLD" ]; then
    VOYAGE_MODEL=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$OLD" | sed -n 's/^VOYAGE_EMBEDDING_MODEL=//p')
    [ -n "$VOYAGE_MODEL" ] || { echo "$OLD has no explicit VOYAGE_EMBEDDING_MODEL; set VOYAGE_MODEL"; exit 2; }
  elif [ "$MEMORIES" != "0" ]; then
    echo "nothing serving but the graph has $MEMORIES embedded nodes; set VOYAGE_MODEL"; exit 2
  else
    VOYAGE_MODEL=voyage-4
  fi
fi
echo "service=$SERVICE host=$HOST old=${OLD:-none} new=$NEW model=$VOYAGE_MODEL embedded=$MEMORIES"

if docker image inspect "$IMG" >/dev/null 2>&1; then
  echo "image $IMG already built"
else
  B=/tmp/mnemo-build-$SHA; rm -rf "$B"; mkdir -p "$B"
  # Tarball of exactly $SHA. The token reaches curl on stdin (-K -): it is in no
  # argv, no git remote, and nothing credential-bearing is left in $B.
  printf 'header = "Authorization: token %s"\n' "$GHTOKEN" |
    curl -fsSL -K - "https://api.github.com/repos/swombat/mnemodyne/tarball/$SHA" | tar -xz -C "$B" --strip-components=1
  docker build -q --build-arg RAILS_ENV=production -t "$IMG" "$B" >/dev/null
  echo "built $IMG"
fi
unset GHTOKEN

SWAPPED=0
cleanup(){
  if [ "$SWAPPED" = 0 ] && docker ps -a --format '{{.Names}}' | grep -qx "$NEW"; then
    NT=$(docker inspect -f '{{.Config.Hostname}}' "$NEW" 2>/dev/null || true)
    CUR=$(plain | awk -v s="$SERVICE-web" '$1==s {print $4}' | cut -d: -f1)
    if [ -n "$NT" ] && [ "$CUR" != "$NT" ]; then
      docker logs --tail 40 "$NEW" 2>&1 | sed 's/^/  candidate: /' || true
      docker rm -f "$NEW" >/dev/null && echo "removed failed candidate $NEW (proxy still serves ${CUR:-nothing})"
    fi
  fi
}
trap cleanup EXIT

docker run -d --name "$NEW" --network kamal --restart unless-stopped --log-opt max-size=10m \
  --env-file "$ENV_FILE" \
  -e KAMAL_CONTAINER_NAME="$NEW" -e KAMAL_VERSION="$SHA" -e KAMAL_HOST=95.217.118.47 \
  -e RAILS_SERVE_STATIC_FILES=true -e RAILS_LOG_TO_STDOUT=true -e RAILS_ENV=production -e SOLID_QUEUE_IN_PUMA=true \
  -e EMBEDDING_PROVIDER=voyage -e EMBEDDING_DIMENSION=1024 -e VOYAGE_EMBEDDING_MODEL="$VOYAGE_MODEL" \
  -e DECAY_RATE=0.005 -e CHARGE_DECAY_RATE=0.001 -e CHARGE_DECAY_FLOOR=0.1 \
  --label service="$SERVICE" --label role=web --label destination= "$IMG" >/dev/null
CID=$(docker inspect -f '{{.Config.Hostname}}' "$NEW")
for i in $(seq 1 60); do
  if docker exec "$NEW" curl -fsS -o /dev/null http://localhost:80/up 2>/dev/null; then echo "up after ${i}x2s"; break; fi
  [ "$i" = 60 ] && { echo "NOT UP"; exit 1; }; sleep 2
done

# Verify before the swap: migrations applied, ivfflat gone, the stored vectors
# match this container's model, and a recall answers. Nothing below writes.
docker exec "$NEW" bin/rails runner '
  c = ActiveRecord::Base.connection
  v = c.select_value("select max(version) from schema_migrations").to_s
  idx = c.indexes(:nodes).map(&:name).sort
  puts "schema=#{v} nodes_indexes=#{idx.join(",")}"
  abort "migration not applied" unless v >= "20261105110000"
  abort "ivfflat still present" if idx.include?("index_nodes_on_embedding_cosine")
  n = Node.memories.active_only.where.not(embedding: nil).order(:created_at).last
  if n
    stored = n.embedding.to_a.map(&:to_f)
    fresh  = Embeddings.provider.embed(n.embedding_text).map(&:to_f)
    cos = stored.zip(fresh).sum { |a, b| a * b } / (Math.sqrt(stored.sum { |a| a * a }) * Math.sqrt(fresh.sum { |b| b * b }))
    puts "embedding check cosine=#{cos.round(4)} (#{ENV["VOYAGE_EMBEDDING_MODEL"]})"
    abort "stored vectors were not made by #{ENV["VOYAGE_EMBEDDING_MODEL"]}" if cos < 0.98
    r = Recall.new(query: n.content, reinforce: false, spread: "distance").call
    puts "smoke recall results=#{r[:results].size} first_match=#{r[:results].first&.dig(:match)}"
    abort "empty recall" if r[:results].empty?
  else
    puts "no embedded memories: no embedding or recall check"
  end
'

docker exec kamal-proxy kamal-proxy deploy "$SERVICE-web" --target="$CID:80" --host="$HOST" --tls \
  --health-check-path=/up --deploy-timeout=30s --drain-timeout=30s --buffer-requests --buffer-responses \
  --log-request-header=Cache-Control --log-request-header=Last-Modified --log-request-header=User-Agent
[ "$(plain | awk -v s="$SERVICE-web" '$1==s {print $4}' | cut -d: -f1)" = "$CID" ] \
  || { echo "proxy deploy returned but $SERVICE-web does not target $CID"; exit 1; }
SWAPPED=1
if [ -n "$OLD" ]; then
  echo "old hostname for rollback: $(docker inspect -f '{{.Config.Hostname}}' "$OLD")"
  docker stop "$OLD" >/dev/null && echo "stopped $OLD (kept, with its image)"
fi
