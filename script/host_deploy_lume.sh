#!/bin/bash
# Host-side deploy of swombat/mnemodyne <sha> as mnemos-web (Lume's instance,
# mnemodyne-lume.swombat.io), mirroring what `kamal deploy` does, for when the
# machine holding the Kamal secrets can't run Kamal. Run ON the host as swombat:
#   GHTOKEN=<read token> bash host_deploy_lume.sh <full sha>
# Secrets come from the env file Kamal already left on the host; clear env is
# config/deploy.yml's. The old container is stopped, not removed. Rollback:
#   docker start <old>; docker exec kamal-proxy kamal-proxy deploy mnemos-web \
#     --target=<old hostname>:80 --host=mnemodyne-lume.swombat.io --tls --health-check-path=/up
# Touches mnemos-* only (never mnemodyne-mira-*).
set -euo pipefail
SHA="${1:-}"; [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "full sha required"; exit 2; }
OLD=$(docker ps --format '{{.Names}}' | grep '^mnemos-web-' | head -1)
NEW="mnemos-web-$SHA"; IMG="dtenner/mnemodyne:$SHA"
echo "old=$OLD new=$NEW"
[ "$OLD" != "$NEW" ] || { echo "already running $NEW"; exit 2; }

B=/tmp/mnemo-build-$SHA; rm -rf "$B"; mkdir -p "$B"
# Tarball of exactly $SHA. The token reaches curl on stdin (-K -): it is in no
# argv, no git remote, and nothing credential-bearing is left in $B.
printf 'header = "Authorization: token %s"\n' "$GHTOKEN" |
  curl -fsSL -K - "https://api.github.com/repos/swombat/mnemodyne/tarball/$SHA" | tar -xz -C "$B" --strip-components=1
unset GHTOKEN
docker build -q --build-arg RAILS_ENV=production -t "$IMG" "$B" >/dev/null
echo "built $IMG"

docker run -d --name "$NEW" --network kamal --restart unless-stopped --log-opt max-size=10m \
  --env-file ~/.kamal/apps/mnemos/env/roles/web.env \
  -e KAMAL_CONTAINER_NAME="$NEW" -e KAMAL_VERSION="$SHA" -e KAMAL_HOST=95.217.118.47 \
  -e RAILS_SERVE_STATIC_FILES=true -e RAILS_LOG_TO_STDOUT=true -e RAILS_ENV=production -e SOLID_QUEUE_IN_PUMA=true \
  -e EMBEDDING_PROVIDER=voyage -e EMBEDDING_DIMENSION=1024 -e VOYAGE_EMBEDDING_MODEL=voyage-4 \
  -e DECAY_RATE=0.005 -e CHARGE_DECAY_RATE=0.001 -e CHARGE_DECAY_FLOOR=0.1 \
  --label service=mnemos --label role=web --label destination= "$IMG" >/dev/null
CID=$(docker inspect -f '{{.Config.Hostname}}' "$NEW")
for i in $(seq 1 60); do
  if docker exec "$NEW" curl -fsS -o /dev/null http://localhost:80/up 2>/dev/null; then echo "up after ${i}x2s"; break; fi
  [ "$i" = 60 ] && { echo "NOT UP"; docker logs --tail 40 "$NEW"; exit 1; }; sleep 2
done

# Verify before the swap: migration applied, ivfflat gone, a recall answers.
# The new container shares the database, so the old one is already on the new
# schema here; nothing below writes (reinforce: false).
docker exec "$NEW" bin/rails runner '
  c = ActiveRecord::Base.connection
  v = c.select_value("select max(version) from schema_migrations").to_s
  idx = c.indexes(:nodes).map(&:name).sort
  puts "schema=#{v} nodes_indexes=#{idx.join(",")}"
  abort "migration not applied" unless v >= "20261105110000"
  abort "ivfflat still present" if idx.include?("index_nodes_on_embedding_cosine")
  r = Recall.new(query: Node.memories.active_only.order(:created_at).last.content, reinforce: false, spread: "distance").call
  puts "smoke recall results=#{r[:results].size} first_match=#{r[:results].first&.dig(:match)}"
  abort "empty recall" if r[:results].empty?
'

docker exec kamal-proxy kamal-proxy deploy mnemos-web --target="$CID:80" --host=mnemodyne-lume.swombat.io --tls \
  --health-check-path=/up --deploy-timeout=30s --drain-timeout=30s --buffer-requests --buffer-responses \
  --log-request-header=Cache-Control --log-request-header=Last-Modified --log-request-header=User-Agent
echo "old hostname for rollback: $(docker inspect -f '{{.Config.Hostname}}' "$OLD")"
docker stop "$OLD" >/dev/null && echo "stopped $OLD (kept, with its image)"
