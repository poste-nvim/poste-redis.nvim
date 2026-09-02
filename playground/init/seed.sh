#!/bin/sh
# Redis playground seed — fills every value type with enough data to demo
# the result-panel table grids + pagination (page_size 50 → 3 pages per
# collection). Idempotent: deletes the demo keys first, so re-running (on a
# fresh `docker compose up`, or by hand against a running container) is safe.
#
#   inside redis container:  REDIS_HOST=127.0.0.1 REDIS_PORT=6379 sh seed.sh
#   from the host:           sh seed.sh        (defaults to the mapped port 16479)
#
# Values are batched into a handful of MULTI-arg commands (one redis-cli call
# per collection) so seeding finishes in ~1s, not ~8s of per-item calls.
set -e

TARGET_HOST="${REDIS_HOST:-127.0.0.1}"
TARGET_PORT="${REDIS_PORT:-16479}"
R="redis-cli -h $TARGET_HOST -p $TARGET_PORT"

echo "Seeding demo data into redis://$TARGET_HOST:$TARGET_PORT ..."

# ---- idempotent cleanup (missing keys are a no-op) ----
$R DEL \
  demo:string demo:json demo:list demo:set demo:hash demo:zset demo:stream \
  demo:list:page demo:set:page demo:hash:page demo:zset:page >/dev/null 2>&1 || true

# ---- String ----
$R SET demo:string "Hello from PosteRedis!" >/dev/null
$R SET demo:json '{"name":"Alice","role":"admin","active":true}' >/dev/null

# Build the paginated payloads as whitespace-separated arg streams.
i=1; list_args=""   # 150 list items
while [ "$i" -le 150 ]; do list_args="$list_args item-$i"; i=$((i + 1)); done
i=1; set_args=""    # 150 set members
while [ "$i" -le 150 ]; do set_args="$set_args member-$i"; i=$((i + 1)); done
i=1; hash_args=""   # 120 field/value pairs
while [ "$i" -le 120 ]; do hash_args="$hash_args field-$i value-$i"; i=$((i + 1)); done
i=1; zset_args=""   # 120 score/member pairs
while [ "$i" -le 120 ]; do zset_args="$zset_args $i member-$i"; i=$((i + 1)); done

# ---- List (classic + 150 items -> 3 pages at page_size 50) ----
$R RPUSH demo:list job-1 job-2 job-3 >/dev/null
# shellcheck disable=SC2086  # word-splitting is intended
$R RPUSH demo:list:page $list_args >/dev/null

# ---- Set (few + 150 members -> pages) ----
$R SADD demo:set vim lua redis postgres >/dev/null
$R SADD demo:set:page $set_args >/dev/null

# ---- Hash (few + 120 fields -> pages) ----
$R HSET demo:hash name Alice email alice@example.com age 30 >/dev/null
$R HSET demo:hash:page $hash_args >/dev/null

# ---- ZSet (few + 120 members, score right-aligned -> pages) ----
$R ZADD demo:zset 99 alice 87 bob 75 carol >/dev/null
$R ZADD demo:zset:page $zset_args >/dev/null

# ---- Stream ----
$R XADD demo:stream "*" to a@b.c from poste >/dev/null
$R XADD demo:stream "*" to c@d.e from redis >/dev/null

echo "Seeded. Try in poste-redis (connection 'local' -> 127.0.0.1:16479):"
echo "  GET demo:string"
echo "  LRANGE demo:list:page 0 -1      # 3 pages of data in the result grid"
echo "  SMEMBERS demo:set:page          # paginated table"
echo "  HGETALL demo:hash:page          # paginated field/value table"
echo "  ZRANGE demo:zset:page 0 -1 WITHSCORES   # member/score, score right-aligned"
echo "  XRANGE demo:stream - +"