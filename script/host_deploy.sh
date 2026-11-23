#!/bin/bash
# Host-side deploy of swombat/mnemodyne <sha> for ONE instance on the misc host,
# mirroring what `kamal deploy` does, for when the machine holding the Kamal
# secrets can't run Kamal. Each being has its own instance (AUTH_TOKEN is one
# per process): its own Postgres container, env file, web container and hostname.
# Run ON the host as swombat:
#   GHTOKEN=<read token> bash host_deploy.sh <service> <hostname> <full sha>
# Known instances:
#   mnemos             mnemodyne-lume.swombat.io     (Lume; Kamal id kept from the rename)
#   mnemodyne-mira     mnemodyne-mira.swombat.io     (Mira)
#   mnemodyne-sibling  mnemodyne-sibling.swombat.io  (the Gemini sibling, until they choose a name)
# Secrets come from ~/.kamal/apps/<service>/env/roles/web.env (override with
# ENV_FILE=); clear env is config/deploy.yml's. VOYAGE_MODEL defaults to what the
# running container uses (a graph embedded with one model must be queried with
# the same one: Mira's is still voyage-3), and to voyage-4 for a new instance.
# Touches <service>-web-* and the <service>-web proxy route only. The old
# container is stopped, not removed. Rollback:
#   docker start <old>; docker exec kamal-proxy kamal-proxy deploy <service>-web \
#     --target=<old hostname>:80 --host=<hostname> --tls --health-check-path=/up
# A first deploy (no old container, empty graph) skips the recall smoke test;
# check it from outside instead (write, recall, delete).
set -euo pipefail
SERVICE="${1:-}"; HOST="${2:-}"; SHA="${3:-}"
[[ "$SERVICE" =~ ^[a-z][a-z0-9-]+$ ]] || { echo "usage: $0 <service> <hostname> <full sha>"; exit 2; }
[[ "$HOST" =~ ^[a-z0-9.-]+\.[a-z]+$ ]] || { echo "hostname required"; exit 2; }
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "full sha required"; exit 2; }
ENV_FILE="${ENV_FILE:-$HOME/.kamal/apps/$SERVICE/env/roles/web.env}"
[ -f "$ENV_FILE" ] || { echo "no env file at $ENV_FILE"; exit 2; }
# The proxy route must not already belong to another service's hostname.
ROUTE=$(docker exec kamal-proxy kamal-proxy list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk -v h="$HOST" '$2==h {print $1}')
[ -z "$ROUTE" ] || [ "$ROUTE" = "$SERVICE-web" ] || { echo "$HOST is routed to $ROUTE, not $SERVICE-web"; exit 2; }

OLD=$(docker ps --format '{{.Names}}' | grep "^$SERVICE-web-" | head -1 || true)
NEW="$SERVICE-web-$SHA"; IMG="dtenner/mnemodyne:$SHA"
if [ -z "${VOYAGE_MODEL:-}" ] && [ -n "$OLD" ]; then
  VOYAGE_MODEL=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$OLD" | sed -n 's/^VOYAGE_EMBEDDING_MODEL=//p')
fi
VOYAGE_MODEL="${VOYAGE_MODEL:-voyage-4}"
echo "service=$SERVICE host=$HOST old=${OLD:-none} new=$NEW model=$VOYAGE_MODEL"
[ "$OLD" != "$NEW" ] || { echo "already running $NEW"; exit 2; }

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
  [ "$i" = 60 ] && { echo "NOT UP"; docker logs --tail 40 "$NEW"; exit 1; }; sleep 2
done

# Verify before the swap: migrations applied, ivfflat gone, and (if the graph
# has memories) a recall answers. Nothing below writes (reinforce: false).
docker exec "$NEW" bin/rails runner '
  c = ActiveRecord::Base.connection
  v = c.select_value("select max(version) from schema_migrations").to_s
  idx = c.indexes(:nodes).map(&:name).sort
  puts "schema=#{v} nodes_indexes=#{idx.join(",")}"
  abort "migration not applied" unless v >= "20261105110000"
  abort "ivfflat still present" if idx.include?("index_nodes_on_embedding_cosine")
  last = Node.memories.active_only.order(:created_at).last
  if last
    r = Recall.new(query: last.content, reinforce: false, spread: "distance").call
    puts "smoke recall results=#{r[:results].size} first_match=#{r[:results].first&.dig(:match)}"
    abort "empty recall" if r[:results].empty?
  else
    puts "empty graph: no recall smoke test"
  end
'

docker exec kamal-proxy kamal-proxy deploy "$SERVICE-web" --target="$CID:80" --host="$HOST" --tls \
  --health-check-path=/up --deploy-timeout=30s --drain-timeout=30s --buffer-requests --buffer-responses \
  --log-request-header=Cache-Control --log-request-header=Last-Modified --log-request-header=User-Agent
if [ -n "$OLD" ]; then
  echo "old hostname for rollback: $(docker inspect -f '{{.Config.Hostname}}' "$OLD")"
  docker stop "$OLD" >/dev/null && echo "stopped $OLD (kept, with its image)"
fi
