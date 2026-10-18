#!/bin/sh
# Redis playground seed — realistic multi-db demo data for the poste-redis
# result panel + key browser.
#
#   inside redis container:  REDIS_HOST=127.0.0.1 REDIS_PORT=6379 sh seed.sh
#   from the host:           sh seed.sh        (defaults to mapped port 16479)
#
# What gets seeded (docker-compose.yml runs `flushall` before this, and the
# script itself FLUSHes its own dbs for idempotent re-runs):
#
#   db0 — a multilingual shop: every value type (string / list / set / hash /
#         zset / stream), deep `user:` / `i18n:` / `config:` / `org:` namespace
#         trees, and big collections sized to trigger grid pagination.
#   db1 — service/tenant infrastructure: long `svc:` / `tenant:` trees,
#         per-node metrics, deploy history, alerts, streams.
#
# Both dbs have 100+ keys and values in English / Chinese / Japanese / Latin / Russian
# so wide glyph rendering and the `a:b:c:...` tree view can be demonstrated.
set -e

TARGET_HOST="${REDIS_HOST:-127.0.0.1}"
TARGET_PORT="${REDIS_PORT:-16479}"
R="redis-cli -h $TARGET_HOST -p $TARGET_PORT"

echo "Seeding demo data into redis://$TARGET_HOST:$TARGET_PORT (db0 + db1) ..."

# ---- idempotent cleanup (dedicated playground instance) ----
$R -n 0 FLUSHDB >/dev/null 2>&1 || true
$R -n 1 FLUSHDB >/dev/null 2>&1 || true

# Big collections as whitespace-separated arg streams (one redis-cli call each,
# so seeding finishes in ~1s rather than hundreds of per-item calls).
n=1; arrivals=""                 # 150 new-arrival skus
while [ "$n" -le 150 ]; do arrivals="$arrivals sku-$((1000 + n))"; n=$((n + 1)); done
n=1; tags=""                     # 160 catalog tags
while [ "$n" -le 160 ]; do tags="$tags tag-$n"; n=$((n + 1)); done
n=1; lb=""                       # 150 leaderboard score/member pairs
while [ "$n" -le 150 ]; do lb="$lb $((n * 7)) player-$n"; n=$((n + 1)); done
n=1; mesh=""                     # 150 registered mesh nodes
while [ "$n" -le 150 ]; do mesh="$mesh mesh-node-$n"; n=$((n + 1)); done
n=1; deploy=""                   # 150 gateway deploys
while [ "$n" -le 150 ]; do deploy="$deploy v3.14.$n"; n=$((n + 1)); done
n=1; req=""                      # 120 per-endpoint score/member pairs
while [ "$n" -le 120 ]; do req="$req $((n * 120)) /api/v$(((n % 9) + 1))/resource:$n"; n=$((n + 1)); done

# ============================================================
# DB 0 — multilingual shop (all six value types)
# ============================================================

# ---- String: branding / feature flags / counters ----
$R -n 0 SET site:name "Poste Boutique" >/dev/null
$R -n 0 SET site:slogan:en "Everyday essentials, delivered." >/dev/null
$R -n 0 SET site:slogan:zh "日常所需，随心配送。" >/dev/null
$R -n 0 SET site:slogan:ja "毎日必要なもの、お届けします。" >/dev/null
$R -n 0 SET site:slogan:la "Necessaria cotidiāna ad portam ferimus." >/dev/null
$R -n 0 SET site:slogan:ru "Необходимое каждый день — с доставкой." >/dev/null
$R -n 0 SET site:announcement "Spring sale! 春季大促！春のセール！Весенняя распродажа!" >/dev/null
$R -n 0 SET site:currency:base EUR >/dev/null
$R -n 0 SET site:config:cart:ttl 86400 >/dev/null
$R -n 0 SET site:config:checkout:max_items 50 >/dev/null
$R -n 0 SET feature:flag:experimental-checkout on >/dev/null
$R -n 0 SET feature:flag:dark-mode yes >/dev/null
$R -n 0 SET feature:flag:i18n enabled >/dev/null
$R -n 0 SET stats:users:total 18423 >/dev/null
$R -n 0 SET stats:orders:today 312 >/dev/null
$R -n 0 SET stats:visits:today 8902 >/dev/null
$R -n 0 SET stats:orders:2024:q1 12890 >/dev/null
$R -n 0 SET stats:orders:2024:q2 14730 >/dev/null
$R -n 0 SET stats:orders:2024:q3 15210 >/dev/null
$R -n 0 SET stats:orders:2024:q4 19840 >/dev/null
$R -n 0 SET stats:revenue:2024:total 1480000 >/dev/null

# ---- String: i18n leaf texts in the five demo languages ----
$R -n 0 SET i18n:greeting:en "Hello and welcome!" >/dev/null
$R -n 0 SET i18n:greeting:zh "你好，欢迎光临！" >/dev/null
$R -n 0 SET i18n:greeting:ja "こんにちは、ようこそ！" >/dev/null
$R -n 0 SET i18n:greeting:la "Salvē, tē grātum accipimus!" >/dev/null
$R -n 0 SET i18n:greeting:ru "Здравствуйте, рады вас видеть!" >/dev/null
$R -n 0 SET i18n:footer:en "© 2025 Poste Boutique" >/dev/null
$R -n 0 SET i18n:footer:zh "© 2025 精品商店" >/dev/null
$R -n 0 SET i18n:footer:ja "© 2025 精品商店" >/dev/null
$R -n 0 SET i18n:footer:la "© MMXXV Taberna Poste" >/dev/null
$R -n 0 SET i18n:footer:ru "© 2025 Магазин Poste" >/dev/null
$R -n 0 SET i18n:ui:checkout:en "Checkout" >/dev/null
$R -n 0 SET i18n:ui:checkout:zh "结算" >/dev/null
$R -n 0 SET i18n:ui:checkout:ja "レジへ進む" >/dev/null
$R -n 0 SET i18n:ui:checkout:la "Persolvē" >/dev/null
$R -n 0 SET i18n:ui:checkout:ru "Оформить заказ" >/dev/null

# ---- Hash: product catalog (name variants, wide glyphs) ----
$R -n 0 HSET product:p_1001 name "Espresso Machine" name_zh "意式浓缩咖啡机" name_ja "エスプレッソマシン" category appliances price 429 stock 32 rating 4.7 vendor "Roma Brio" >/dev/null
$R -n 0 HSET product:p_1002 name "Ceramic Teapot" name_zh "陶瓷茶壶" name_ja "陶磁器のティーポット" category home price 68 stock 120 rating 4.9 vendor "Kyoto Kiln" >/dev/null
$R -n 0 HSET product:p_1003 name "Green Tea" name_zh "绿茶" name_ja "緑茶" category pantry price 24 stock 500 rating 4.8 vendor "Uji Garden" >/dev/null
$R -n 0 HSET product:p_1004 name "Silk Scarf" name_zh "丝巾" name_ja "絹のスカーフ" category fashion price 89 stock 40 rating 4.6 vendor "Hangzhou Silk" >/dev/null
$R -n 0 HSET product:p_1005 name "Leather Notebook" name_zh "皮面笔记本" name_ja "革のノート" category stationery price 19 stock 300 rating 4.5 vendor "Firenze Atelier" >/dev/null
$R -n 0 HSET product:p_1006 name "Matcha Set" name_zh "抹茶套装" name_ja "抹茶セット" category pantry price 42 stock 210 rating 4.9 vendor "Uji Garden" >/dev/null
$R -n 0 HSET product:p_1007 name "Russian Adventure Novel" name_zh "俄罗斯冒险小说" name_ja "ロシアの冒険小説" name_ru "Приключенческий роман" category books price 15 stock 80 rating 4.4 vendor "Moskva Press" >/dev/null
$R -n 0 HSET product:p_1008 name "Latin Grammar" name_zh "拉丁语语法" name_ja "ラテン語の文法" name_la "Grammatica Latīna" category books price 12 stock 55 rating 4.2 vendor "Roma Editrice" >/dev/null
$R -n 0 HSET product:p_1009 name "Katana Stand" name_zh "武士刀架" name_ja "刀置き" category home price 120 stock 15 rating 4.3 vendor "Sakura Craft" >/dev/null
$R -n 0 HSET product:p_1010 name "Wool Scarf" name_zh "羊毛围巾" name_ja "ウールのマフラー" category fashion price 55 stock 60 rating 4.7 vendor "Ulaanbaatar Wool" >/dev/null
$R -n 0 HSET product:p_1011 name "Porcelain Bowl" name_zh "瓷碗" name_ja "磁器の器" category tableware price 32 stock 140 rating 4.8 vendor "Jingdezhen Porcelain" >/dev/null
$R -n 0 HSET product:p_1012 name "Coffee Beans" name_zh "咖啡豆" name_ja "コーヒー豆" name_ru "Кофейные зёрна" name_la "Grana caffēae" category pantry price 14 stock 900 rating 4.6 vendor "Norte Café" >/dev/null

# ---- Hash: user profiles (multilingual names + bios) ----
$R -n 0 HSET user:u_001:profile name "Alice Chen" nickname "爱丽丝" lang zh bio "Coffee & code." bio_zh "咖啡与代码。" bio_ja "コーヒーとコード。" joined "2023-04-01" country CN >/dev/null
$R -n 0 HSET user:u_002:profile name "Hiroshi Tanaka" name_ja "田中 浩" lang ja bio_ja "本と旅が好きです。" joined "2023-06-12" country JP >/dev/null
$R -n 0 HSET user:u_003:profile name "Lada Sokolova" name_ru "Лада Соколова" lang ru bio_ru "Люблю книги и кофе." bio_zh "喜欢书和咖啡。" joined "2023-08-30" country RU >/dev/null
$R -n 0 HSET user:u_004:profile name "Marcus Lucius" name_la "Marcus Lūcius" lang la bio_la "Librum caffēamque amō." bio_en "I love books and coffee." joined "2023-11-05" country IT >/dev/null
$R -n 0 HSET user:u_005:profile name "Mei Ling" name_zh "林美" lang zh bio_zh "热爱设计。" joined "2024-01-18" country CN >/dev/null
$R -n 0 HSET user:u_006:profile name "Yui Nakamura" name_ja "中村 唯" lang ja bio_ja "デザインが好き。" joined "2024-02-02" country JP >/dev/null
$R -n 0 HSET user:u_007:profile name "Dmitri Petrov" name_ru "Дмитрий Петров" lang ru bio_ru "Я инженер-программист." joined "2024-03-27" country RU >/dev/null
$R -n 0 HSET user:u_008:profile name "Sota Abe" name_ja "阿部 颯太" lang ja joined "2024-05-09" country JP >/dev/null
$R -n 0 HSET user:u_009:profile name "Cai Xiaoxia" name_zh "蔡小霞" lang zh bio_zh "摄影与美食。" joined "2024-07-21" country CN >/dev/null
$R -n 0 HSET user:u_010:profile name "Igor Novikov" name_ru "Игорь Новиков" lang ru bio_ru "Люблю горы и чай." joined "2024-09-14" country RU >/dev/null
$R -n 0 HSET user:u_011:profile name "Chen Jing" name_zh "陈静" lang zh bio_zh "前端工程师。" joined "2025-01-03" country CN >/dev/null
$R -n 0 HSET user:u_012:profile name "Clara Rossi" lang en joined "2025-02-19" country IT >/dev/null

# ---- Per-user tree: prefs / cart / orders by year / wishlist ----
n=1
while [ "$n" -le 12 ]; do
  id=$(printf "u_%03d" "$n")
  cart1=$(printf "p_100%d" $(((n % 9) + 1)))
  cart2=$(printf "p_100%d" $((((n + 1) % 9) + 1)))
  day=$(printf "%02d" $(((n % 9) + 1)))
  $R -n 0 HSET "user:${id}:prefs" theme dark currency EUR notifications on language en >/dev/null
  $R -n 0 RPUSH "user:${id}:cart" "$cart1" "$cart2" >/dev/null
  $R -n 0 ZADD "user:${id}:orders:2024" "$((n * 11 + 5))" "o:${id}:2024-03-${day}:A38" "$((n * 11 + 9))" "o:${id}:2024-09-${day}:B21" >/dev/null
  $R -n 0 ZADD "user:${id}:orders:2025" "$((n * 5 + 2))" "o:${id}:2025-01-${day}:C14" >/dev/null
  $R -n 0 SADD "user:${id}:wishlist" "$cart1" "p_1002" >/dev/null
  n=$((n + 1))
done

# ---- List ----
$R -n 0 RPUSH catalog:new-arrivals $arrivals >/dev/null
$R -n 0 RPUSH i18n:phrases:greet "Hello and welcome!" "你好，欢迎光临！" "こんにちは、ようこそ！" "Salvē, tē grātum accipimus!" "Здравствуйте, рады вас видеть!" >/dev/null
$R -n 0 RPUSH notify:queue:email "user:u_001|order shipped|2025-02-10" "user:u_004|stale cart|2025-02-10" "user:u_007|back in stock: p_1007|2025-02-10" >/dev/null
$R -n 0 RPUSH activities:recent "u_011 viewed product:p_1007" "u_003 purchased order:o_003" "u_006 liked product:p_1004" >/dev/null

# ---- Set ----
$R -n 0 SADD catalog:tags:new $tags >/dev/null
$R -n 0 SADD catalog:brands "Roma Brio" "Kyoto Kiln" "Uji Garden" "Hangzhou Silk" "Firenze Atelier" "Sakura Craft" "Ulaanbaatar Wool" "Jingdezhen Porcelain" "Norte Café" >/dev/null
$R -n 0 SADD role:admin:members u_001 u_004 >/dev/null
$R -n 0 SADD role:staff:members u_004 u_006 u_008 u_012 >/dev/null
$R -n 0 SADD user:u_001:following u_002 u_003 u_005 u_007 u_008 >/dev/null
$R -n 0 SADD user:u_002:followers u_001 u_009 u_010 >/dev/null
$R -n 0 SADD product:p_1001:tags espresso appliances premier >/dev/null
$R -n 0 SADD online:shoppers u_001 u_004 u_007 u_010 u_011 >/dev/null

# ---- ZSet (multilingual trending terms + paginated leaderboard) ----
$R -n 0 ZADD leaderboard:weekly $lb >/dev/null
$R -n 0 ZADD catalog:popularity 980 p_1012 760 p_1003 640 p_1006 531 p_1004 482 p_1001 410 p_1010 356 p_1005 301 p_1002 288 p_1011 204 p_1007 176 p_1009 141 p_1008 >/dev/null
$R -n 0 ZADD search:trending 98 coffee 95 咖啡 92 コーヒー 90 кофе 88 caffēa 85 茶壶 82 抹茶 79 ノート 76 книга 72 līber 70 春のセール 66 皮肤护理 63 新品入荷 60 перчатки 58 新到货 55 ハンドクリーム >/dev/null

# ---- Stream ----
$R -n 0 XADD events:orders "*" order o_2025_0001 user u_001 total 129.00 status paid >/dev/null
$R -n 0 XADD events:orders "*" order o_2025_0002 user u_004 total 45.50 status shipped >/dev/null
$R -n 0 XADD events:orders "*" order o_2025_0003 user u_007 total 299.00 status refunded >/dev/null
$R -n 0 XADD events:orders "*" order o_2025_0004 user u_011 total 88.20 status paid >/dev/null
$R -n 0 XADD events:audit "*" actor admin:u_001 action login ip 10.0.3.21 ok yes >/dev/null
$R -n 0 XADD events:audit "*" actor support:bot action password_reset user u_002 ok yes >/dev/null

# ---- Deep namespace trees for the key-browser tree view ----
$R -n 0 SET config:checkout:payment:methods:card enabled >/dev/null
$R -n 0 SET config:checkout:payment:methods:paypal enabled >/dev/null
$R -n 0 SET config:checkout:payment:methods:crypto disabled >/dev/null
$R -n 0 HSET config:checkout:shipping:carrier:dhl rate 12.50 zone_eu 3 zone_asia 9 >/dev/null
$R -n 0 HSET config:checkout:shipping:carrier:fedex rate 15.00 zone_eu 2 zone_asia 6 >/dev/null
$R -n 0 SADD org:retail:region:asia:team:growth:members u_001 u_005 u_008 u_011 >/dev/null

# ============================================================
# DB 1 — service / tenant infrastructure
# ============================================================

# ---- String: version + config + flags ----
$R -n 1 SET svc:gateway:version 3.14.2 >/dev/null
$R -n 1 SET svc:auth:version 2.8.0 >/dev/null
$R -n 1 SET svc:search:version 1.45.1 >/dev/null
$R -n 1 SET svc:gateway:config '{"tls":true,"port":8443,"timeouts":{"read":5,"write":5}}' >/dev/null
$R -n 1 SET svc:auth:config '{"issuer":"https://id.example.com","ttl":3600}' >/dev/null
$R -n 1 SET kv:cluster:name prod-eu-west >/dev/null
$R -n 1 SET kv:cluster:role primary >/dev/null
$R -n 1 SET flag:enable:tls yes >/dev/null
$R -n 1 SET flag:enable:compression on >/dev/null
$R -n 1 SET flag:verbose:logging off >/dev/null

# ---- String/Hash: per-region service tree ----
$R -n 1 SET svc:gateway:region:eu:haproxy:cfg "/etc/haproxy/eu.conf" >/dev/null
$R -n 1 SET svc:gateway:region:us:haproxy:cfg "/etc/haproxy/us.conf" >/dev/null
$R -n 1 SET svc:gateway:region:ap:haproxy:cfg "/etc/haproxy/ap.conf" >/dev/null
$R -n 1 HSET svc:gateway:region:eu:haproxy:stats sessions 4821 bytes_in 9210300 route "/shop/*" >/dev/null
$R -n 1 SET svc:auth:region:eu:oidc:cfg "discovery=/auth/.well-known" >/dev/null
$R -n 1 SET svc:auth:region:us:oidc:cfg "discovery=/auth/.well-known" >/dev/null
$R -n 1 HSET svc:gateway:region:eu:pod:p-1:stat cpu 18 mem_pct 55 replicas 3 >/dev/null
$R -n 1 HSET svc:auth:region:eu:pod:p-1:stat cpu 9 mem_pct 41 replicas 3 >/dev/null
$R -n 1 HSET svc:search:region:eu:pod:p-1:stat cpu 33 mem_pct 62 replicas 6 >/dev/null

# ---- Hash: search index shards (6-level svc:... trees) ----
for pair in "products 4" "users 3" "orders 4" "tags 2"; do
  set -- $pair
  index=$1; count=$2; s=0
  while [ "$s" -lt "$count" ]; do
    docs=$((10000 * (s + 3)))
    $R -n 1 HSET "svc:search:index:$index:shard:$s:stat" docs $docs size_mb $((docs / 120)) >/dev/null
    s=$((s + 1))
  done
done

# ---- Hash/Set: per-tenant env trees ----
t=1
while [ "$t" -le 12 ]; do
  tid=$(printf "t_%04d" "$t")
  $R -n 1 HSET "tenant:$tid:env:prod:config" region eu-west apiserver "gw-${t}.internal" max_replicas 6 >/dev/null
  $R -n 1 HSET "tenant:$tid:env:prod:limits" rps 1200 kv_used_mb $((t * 25)) >/dev/null
  $R -n 1 SADD "tenant:$tid:env:prod:flags" dark_mode beta_pricing svc_mesh >/dev/null
  $R -n 1 HSET "tenant:$tid:env:staging:config" region eu-central apiserver "staging-${t}.internal" max_replicas 2 >/dev/null
  t=$((t + 1))
done

# ---- String: multilingual tenant notices (deep i18n leaf) ----
$R -n 1 SET tenant:t_0001:env:prod:notice:en "All systems operational" >/dev/null
$R -n 1 SET tenant:t_0001:env:prod:notice:zh "服务正常" >/dev/null
$R -n 1 SET tenant:t_0001:env:prod:notice:ja "全サービス正常稼働中" >/dev/null
$R -n 1 SET tenant:t_0001:env:prod:notice:la "Omnia systēmata operantur." >/dev/null
$R -n 1 SET tenant:t_0001:env:prod:notice:ru "Все системы работают" >/dev/null

# ---- List ----
$R -n 1 RPUSH deploy:history:gateway $deploy >/dev/null
$R -n 1 RPUSH deploy:history:auth v2.7.9 v2.8.0 >/dev/null
$R -n 1 RPUSH log:tail:error:recent "ERR 2025-02-10T09:12:33Z auth: token expired for u_003" "ERR 2025-02-10T09:47:01Z gateway: upstream timeout /api/orders" "ERR 2025-02-10T10:02:18Z search: shard 0 refresh lag 2100ms" >/dev/null

# ---- Set ----
$R -n 1 SADD svc:mesh:nodes $mesh >/dev/null
$R -n 1 SADD kvstore:cluster:members node-a node-b node-c node-d node-e >/dev/null
$R -n 1 SADD feature:flags:active tls-persist shard-rebalance mesh-bgp >/dev/null
$R -n 1 SADD alerts:open:severity:high p99-latency kv-latency >/dev/null
$R -n 1 SADD alerts:open:severity:medium cpu-spike disk-90 >/dev/null

# ---- Hash: health + per-node stats ----
$R -n 1 HSET svc:gateway:health status ok uptime 99.982 version 3.14.2 >/dev/null
$R -n 1 HSET svc:auth:health status degraded latency_ms 340 >/dev/null
$R -n 1 HSET svc:search:health status ok qps 1284 >/dev/null
$R -n 1 HSET node:node-01:stats cpu 23 mem_pct 61 disk_gb 480 net_mb 812 >/dev/null
$R -n 1 HSET node:node-02:stats cpu 18 mem_pct 54 disk_gb 512 net_mb 640 >/dev/null
$R -n 1 HSET node:node-03:stats cpu 41 mem_pct 79 disk_gb 428 net_mb 998 >/dev/null
$R -n 1 HSET node:node-04:stats cpu 27 mem_pct 58 disk_gb 501 net_mb 731 >/dev/null
$R -n 1 HSET node:node-05:stats cpu 14 mem_pct 47 disk_gb 552 net_mb 512 >/dev/null

# ---- ZSet ----
$R -n 1 ZADD metric:latency:p99:per-service 112 gateway 89 auth 204 search 23 kv >/dev/null
$R -n 1 ZADD metric:requests:per-endpoint $req >/dev/null
$R -n 1 ZADD metric:load:per-node 0.71 node-01 0.48 node-02 0.92 node-03 0.66 node-04 0.35 node-05 >/dev/null

# ---- Stream ----
$R -n 1 XADD metrics:events "*" service gateway metric latency value 112 >/dev/null
$R -n 1 XADD metrics:events "*" service auth metric error_rate value 0.4 >/dev/null
$R -n 1 XADD log:stream:audit "*" actor deploy-bot action deploy:gateway result ok >/dev/null
$R -n 1 XADD log:stream:audit "*" actor alice action svc:auth:restart result ok >/dev/null

# ============================================================
echo "Seeded. Sizes:"
echo "  redis://$TARGET_HOST:$TARGET_PORT/0 -> $($R -n 0 DBSIZE) keys"
echo "  redis://$TARGET_HOST:$TARGET_PORT/1 -> $($R -n 1 DBSIZE) keys"
echo ""
echo "Try in poste-redis (connections 'local' -> /0, 'local-db2' -> /1):"
echo "  GET site:announcement          # en/zh/ja/ru in one value"
echo "  HGETALL user:u_004:profile     # Latin bio (Marcus Lūcius)"
echo "  ZRANGE search:trending 0 -1 WITHSCORES   # multilingual terms"
echo "  SMEMBERS catalog:tags:new      # paginated table"
echo "  LRANGE catalog:new-arrivals 0 -1        # 3 pages of data"
echo "  ZRANGE leaderboard:weekly 0 -1 WITHSCORES"
echo "  XRANGE events:orders - +"
echo "  -- in the key browser, expand user -> u_001 -> orders -> 2024"