--- Redis command documentation — display-only reference rendered by
--- `poste-redis.doc` (the `K` source-buffer hover). One entry per command,
--- keyed by uppercase name, same vocabulary as completion/data.lua COMMANDS.
---
--- entry: { category, syntax, desc, example = string[] }
---   syntax  — canonical signature (also rendered into markdown)
---   desc    — one-sentence semantics
---   example — 1..2 redis-cli-style lines
---
--- This is a pcall-free, pure-data module (headless-test friendly).
local M = {}

local DOCS = {
  -- Keys
  COPY = {
    category = "Keys", syntax = "COPY source destination [DB destination-db] [REPLACE]",
    desc = "Copy the value of source to destination. REPLACE overwrites an existing destination key.",
    example = { "COPY user:1000 user:1000:backup REPLACE" },
  },
  DEL = {
    category = "Keys", syntax = "DEL key [key ...]",
    desc = "Removes the specified keys. Returns the number of keys removed.",
    example = { "DEL user:1000 session:abc", "DEL cache:home cache:profile" },
  },
  DUMP = {
    category = "Keys", syntax = "DUMP key",
    desc = "Serialize the value stored at key into a RDB-format binary payload (feeds RESTORE).",
    example = { "DUMP mykey" },
  },
  EXISTS = {
    category = "Keys", syntax = "EXISTS key [key ...]",
    desc = "Returns the number of existing keys among the ones given (duplicates counted).",
    example = { "EXISTS user:1000 user:1001" },
  },
  EXPIRE = {
    category = "Keys", syntax = "EXPIRE key seconds [NX | XX | GT | LT]",
    desc = "Set a timeout in seconds; the key is deleted once it elapses.",
    example = { "EXPIRE session:abc 3600", "EXPIRE coupon:2000 86400 NX" },
  },
  EXPIREAT = {
    category = "Keys", syntax = "EXPIREAT key unix-time-seconds [NX | XX | GT | LT]",
    desc = "Set the key to expire at a given absolute Unix timestamp in seconds.",
    example = { "EXPIREAT coupon:2000 1900000000" },
  },
  KEYS = {
    category = "Keys", syntax = "KEYS pattern",
    desc = "Return all keys matching a glob pattern. Blocking on big keyspaces — prefer SCAN.",
    example = { "KEYS user:*" },
  },
  MIGRATE = {
    category = "Keys", syntax = "MIGRATE host port key destination-db timeout [COPY] [REPLACE] [AUTH password | AUTH2 username password] [KEYS key ...]",
    desc = "Atomically transfer one (or more) keys to another instance.",
    example = { "MIGRATE 10.0.0.2 6379 mykey \"\" 0 3000 COPY" },
  },
  MOVE = {
    category = "Keys", syntax = "MOVE key db",
    desc = "Moves a key to a different database in the same instance.",
    example = { "MOVE mykey 1" },
  },
  OBJECT = {
    category = "Keys", syntax = "OBJECT SUBCOMMAND key",
    desc = "Inspect key internals: ENCODING, REFCOUNT, IDLETIME, or FREQ.",
    example = { "OBJECT ENCODING user:1000", "OBJECT IDLETIME session:abc" },
  },
  PERSIST = {
    category = "Keys", syntax = "PERSIST key",
    desc = "Remove the timeout on key, turning it back into a persistent key.",
    example = { "PERSIST session:abc" },
  },
  PEXPIRE = {
    category = "Keys", syntax = "PEXPIRE key milliseconds [NX | XX | GT | LT]",
    desc = "Set a timeout in milliseconds.",
    example = { "PEXPIRE cache:home 60000" },
  },
  PEXPIREAT = {
    category = "Keys", syntax = "PEXPIREAT key unix-time-milliseconds [NX | XX | GT | LT]",
    desc = "Set the key to expire at an absolute Unix timestamp in milliseconds.",
    example = { "PEXPIREAT coupon:2000 1900000000000" },
  },
  PTTL = {
    category = "Keys", syntax = "PTTL key",
    desc = "Remaining time to live in milliseconds (-1 = no TTL, -2 = key missing).",
    example = { "PTTL cache:home" },
  },
  RANDOMKEY = {
    category = "Keys", syntax = "RANDOMKEY",
    desc = "Return a random key from the current database.",
    example = { "RANDOMKEY" },
  },
  RENAME = {
    category = "Keys", syntax = "RENAME key newkey",
    desc = "Renames key to newkey (overwrites an existing newkey).",
    example = { "RENAME users:legacy users:current" },
  },
  RENAMENX = {
    category = "Keys", syntax = "RENAMENX key newkey",
    desc = "Rename only when the newkey does not yet exist.",
    example = { "RENAMENX users:legacy users:current" },
  },
  RESTORE = {
    category = "Keys", syntax = "RESTORE key ttl serialized-value [REPLACE] [ABSTTL] [IDLETIME seconds] [FREQ frequency]",
    desc = "Create a key from a DUMP payload; a ttl of 0 means persistent.",
    example = { 'RESTORE mykey 0 "\\x00\\x01\\x02" REPLACE' },
  },
  SCAN = {
    category = "Keys", syntax = "SCAN cursor [MATCH pattern] [COUNT count] [TYPE type]",
    desc = "Incrementally iterate the keyspace without blocking (non-guaranteed results).",
    example = { "SCAN 0 MATCH user:* COUNT 100" },
  },
  SORT = {
    category = "Keys", syntax = "SORT key [BY pattern] [LIMIT offset count] [GET pattern [GET pattern ...]] [ASC | DESC] [ALPHA] [STORE destination]",
    desc = "Sort the elements of a list, set, or sorted set, optionally storing the result.",
    example = { "SORT leaderboard:week DESC LIMIT 0 10", 'SORT phones BY stock:*->qty GET stock:*->name' },
  },
  TOUCH = {
    category = "Keys", syntax = "TOUCH key [key ...]",
    desc = "Alter the last-access time of one or more keys (cache eviction hint).",
    example = { "TOUCH coldkey cache:home" },
  },
  TTL = {
    category = "Keys", syntax = "TTL key",
    desc = "Remaining time to live in seconds (-1 = no TTL, -2 = key missing).",
    example = { "TTL session:abc" },
  },
  TYPE = {
    category = "Keys", syntax = "TYPE key",
    desc = "Return the type of the value (string, hash, list, set, zset, stream, ...).",
    example = { "TYPE user:1000" },
  },
  UNLINK = {
    category = "Keys", syntax = "UNLINK key [key ...]",
    desc = "Like DEL but reclaims memory in the background (non-blocking).",
    example = { "UNLINK biglist" },
  },
  WAIT = {
    category = "Keys", syntax = "WAIT numreplicas timeout",
    desc = "Block until the last write has been acknowledged by numreplicas replicas.",
    example = { "WAIT 1 5000" },
  },
  -- Strings
  APPEND = {
    category = "Strings", syntax = "APPEND key value",
    desc = "Append a value to the string; the key is created if it does not exist.",
    example = { 'APPEND logs:app "[/] new request"' },
  },
  BITCOUNT = {
    category = "Strings", syntax = "BITCOUNT key [start end [BIT | BYTE]]",
    desc = "Count the number of set bits in the string value.",
    example = { "BITCOUNT bitmap-key", "BITCOUNT bitmap-key 0 1 BYTE" },
  },
  BITFIELD = {
    category = "Strings", syntax = "BITFIELD key [GET type offset] [SET type offset value] [INCRBY type offset increment] [OVERFLOW WRAP | SAT | FAIL]",
    desc = "Perform atomic bitfield arithmetic on the string value.",
    example = { "BITFIELD mykey GET u8 0", "BITFIELD counter INCRBY u8 0 1 OVERFLOW SAT" },
  },
  BITOP = {
    category = "Strings", syntax = "BITOP AND | OR | XOR | NOT destkey key [key ...]",
    desc = "Perform a bitwise operation between string values, storing the result.",
    example = { "BITOP AND and-dest a b" },
  },
  BITPOS = {
    category = "Strings", syntax = "BITPOS key bit [start [end [BIT | BYTE]]]",
    desc = "Find the first byte offset where the given bit (0 or 1) appears.",
    example = { "BITPOS mykey 1" },
  },
  DECR = {
    category = "Strings", syntax = "DECR key",
    desc = "Decrement the integer value stored at key by 1.",
    example = { "DECR counter" },
  },
  DECRBY = {
    category = "Strings", syntax = "DECRBY key decrement",
    desc = "Decrement the integer value stored at key by the given amount.",
    example = { "DECRBY counter 10" },
  },
  GET = {
    category = "Strings", syntax = "GET key",
    desc = "Get the string value stored at key.",
    example = { "GET user:1000:name" },
  },
  GETBIT = {
    category = "Strings", syntax = "GETBIT key offset",
    desc = "Return the bit value at the given offset.",
    example = { "GETBIT bitmap 5" },
  },
  GETDEL = {
    category = "Strings", syntax = "GETDEL key",
    desc = "Get the value of key and then delete the key.",
    example = { "GETDEL temp:lastseen" },
  },
  GETEX = {
    category = "Strings", syntax = "GETEX key [EX seconds | PX milliseconds | EXAT unix-time-seconds | PXAT unix-time-milliseconds | PERSIST]",
    desc = "Get the value and simultaneously set or clear the key TTL.",
    example = { "GETEX cache:x EX 60" },
  },
  GETRANGE = {
    category = "Strings", syntax = "GETRANGE key start end",
    desc = "Return a substring by byte offsets of the string value.",
    example = { "GETRANGE name 0 4" },
  },
  GETSET = {
    category = "Strings", syntax = "GETSET key value",
    desc = "Set a new value and return the old value atomically.",
    example = { "GETSET counter 1" },
  },
  INCR = {
    category = "Strings", syntax = "INCR key",
    desc = "Increment the integer value stored at key by 1.",
    example = { "INCR counter" },
  },
  INCRBY = {
    category = "Strings", syntax = "INCRBY key increment",
    desc = "Increment the integer value stored at key by the given amount.",
    example = { "INCRBY counter 7" },
  },
  INCRBYFLOAT = {
    category = "Strings", syntax = "INCRBYFLOAT key increment",
    desc = "Increment the float value stored at key by the given amount.",
    example = { "INCRBYFLOAT price 12.50" },
  },
  MGET = {
    category = "Strings", syntax = "MGET key [key ...]",
    desc = "Get the values of multiple keys in a single round-trip.",
    example = { "MGET k1 k2 k3" },
  },
  MSET = {
    category = "Strings", syntax = "MSET key value [key value ...]",
    desc = "Set multiple keys to values atomically.",
    example = { "MSET k1 v1 k2 v2" },
  },
  MSETNX = {
    category = "Strings", syntax = "MSETNX key value [key value ...]",
    desc = "Set multiple keys only if none of them already exist.",
    example = { "MSETNX k1 v1 k2 v2" },
  },
  PSETEX = {
    category = "Strings", syntax = "PSETEX key milliseconds value",
    desc = "Set a value with an expiry in milliseconds.",
    example = { 'PSETEX otp:code 10000 "123456"' },
  },
  SET = {
    category = "Strings", syntax = "SET key value [EX seconds | PX milliseconds | EXAT unix-time-seconds | PXAT unix-time-milliseconds | KEEPTTL] [NX | XX] [GET]",
    desc = "Set the string value with optional expiry, existence, and GET modifiers.",
    example = { 'SET session:abc "abc123" EX 3600 NX' },
  },
  SETBIT = {
    category = "Strings", syntax = "SETBIT key offset value",
    desc = "Set or clear the bit at the given offset (value is 0 or 1).",
    example = { "SETBIT bitmap 7 1" },
  },
  SETEX = {
    category = "Strings", syntax = "SETEX key seconds value",
    desc = "Set a value with an expiry in seconds.",
    example = { 'SETEX otp:code 60 "123456"' },
  },
  SETNX = {
    category = "Strings", syntax = "SETNX key value",
    desc = "Set a value only if the key does not exist. Returns 1 on success.",
    example = { 'SETNX lock:job "holder"' },
  },
  SETRANGE = {
    category = "Strings", syntax = "SETRANGE key offset value",
    desc = "Overwrite part of the string starting at the given byte offset.",
    example = { 'SETRANGE msg 7 "world"' },
  },
  STRLEN = {
    category = "Strings", syntax = "STRLEN key",
    desc = "Return the byte length of the string value.",
    example = { "STRLEN msg" },
  },
  SUBSTR = {
    category = "Strings", syntax = "SUBSTR key start end",
    desc = "Deprecated alias of GETRANGE.",
    example = { "SUBSTR name 0 4" },
  },
  -- Hashes
  HDEL = {
    category = "Hashes", syntax = "HDEL key field [field ...]",
    desc = "Delete one or more hash fields. Returns the number removed.",
    example = { "HDEL user:1000 age" },
  },
  HEXISTS = {
    category = "Hashes", syntax = "HEXISTS key field",
    desc = "Return 1 if the field exists in the hash, 0 otherwise.",
    example = { "HEXISTS user:1000 name" },
  },
  HGET = {
    category = "Hashes", syntax = "HGET key field",
    desc = "Get the value of a single hash field.",
    example = { "HGET user:1000 name" },
  },
  HGETALL = {
    category = "Hashes", syntax = "HGETALL key",
    desc = "Return all fields and values of the hash.",
    example = { "HGETALL user:1000" },
  },
  HINCRBY = {
    category = "Hashes", syntax = "HINCRBY key field increment",
    desc = "Increment the integer value of a hash field.",
    example = { "HINCRBY user:1000 visits 1" },
  },
  HINCRBYFLOAT = {
    category = "Hashes", syntax = "HINCRBYFLOAT key field increment",
    desc = "Increment the float value of a hash field.",
    example = { "HINCRBYFLOAT user:1000 balance 0.5" },
  },
  HKEYS = {
    category = "Hashes", syntax = "HKEYS key",
    desc = "Return all field names of the hash.",
    example = { "HKEYS user:1000" },
  },
  HLEN = {
    category = "Hashes", syntax = "HLEN key",
    desc = "Return the number of fields in the hash.",
    example = { "HLEN user:1000" },
  },
  HMGET = {
    category = "Hashes", syntax = "HMGET key field [field ...]",
    desc = "Get the values of several hash fields.",
    example = { "HMGET user:1000 name age" },
  },
  HMSET = {
    category = "Hashes", syntax = "HMSET key field value [field value ...]",
    desc = "Deprecated multi-field set — use HSET instead.",
    example = { 'HMSET user:1000 name "peter" age 27' },
  },
  HRANDFIELD = {
    category = "Hashes", syntax = "HRANDFIELD key [count [WITHVALUES]]",
    desc = "Return one or (with count) multiple random fields.",
    example = { "HRANDFIELD myhash -5 WITHVALUES" },
  },
  HSCAN = {
    category = "Hashes", syntax = "HSCAN key cursor [MATCH pattern] [COUNT count]",
    desc = "Incrementally iterate the fields and values of a hash.",
    example = { "HSCAN user:1000 0 MATCH n*" },
  },
  HSET = {
    category = "Hashes", syntax = "HSET key field value [field value ...]",
    desc = "Set the value of one or more hash fields, creating the hash if needed.",
    example = { 'HSET user:1000 name "Peter" age 27' },
  },
  HSETNX = {
    category = "Hashes", syntax = "HSETNX key field value",
    desc = "Set a hash field only if it does not yet exist.",
    example = { 'HSETNX user:1000 email "peter@example.com"' },
  },
  HSTRLEN = {
    category = "Hashes", syntax = "HSTRLEN key field",
    desc = "Return the byte length of a hash field value.",
    example = { "HSTRLEN user:1000 name" },
  },
  HVALS = {
    category = "Hashes", syntax = "HVALS key",
    desc = "Return all field values of the hash.",
    example = { "HVALS user:1000" },
  },
  -- Lists
  BLMOVE = {
    category = "Lists", syntax = "BLMOVE source destination LEFT | RIGHT LEFT | RIGHT timeout",
    desc = "Blocking variant of LMOVE; 0 means wait forever.",
    example = { "BLMOVE queue1 queue2 LEFT RIGHT 0" },
  },
  BLPOP = {
    category = "Lists", syntax = "BLPOP key [key ...] timeout",
    desc = "Blocking LPOP over the first non-empty key; 0 means wait forever.",
    example = { "BLPOP queue1 queue2 5" },
  },
  BRPOP = {
    category = "Lists", syntax = "BRPOP key [key ...] timeout",
    desc = "Blocking RPOP over the first non-empty key; 0 means wait forever.",
    example = { "BRPOP queue1 5" },
  },
  BRPOPLPUSH = {
    category = "Lists", syntax = "BRPOPLPUSH source destination timeout",
    desc = "Blocking variant of RPOPLPUSH.",
    example = { "BRPOPLPUSH q1 q2 5" },
  },
  LINDEX = {
    category = "Lists", syntax = "LINDEX key index",
    desc = "Return the element at the given index (negative = from tail).",
    example = { "LINDEX mylist 0" },
  },
  LINSERT = {
    category = "Lists", syntax = "LINSERT key BEFORE | AFTER pivot value",
    desc = "Insert a value before or after a reference (pivot) element.",
    example = { 'LINSERT mylist BEFORE "b" "a"' },
  },
  LLEN = {
    category = "Lists", syntax = "LLEN key",
    desc = "Return the length of the list.",
    example = { "LLEN mylist" },
  },
  LMOVE = {
    category = "Lists", syntax = "LMOVE source destination LEFT | RIGHT LEFT | RIGHT",
    desc = "Atomically move an element from the head/tail of source to destination.",
    example = { "LMOVE q1 q2 LEFT RIGHT" },
  },
  LPOP = {
    category = "Lists", syntax = "LPOP key [count]",
    desc = "Remove and return the first (head) element(s) of the list.",
    example = { "LPOP mylist", "LPOP mylist 3" },
  },
  LPOS = {
    category = "Lists", syntax = "LPOS key element [RANK rank] [COUNT num-matches] [MAXLEN len]",
    desc = "Return the index (or indices) of a matching element.",
    example = { 'LPOS mylist "b"', 'LPOS mylist "b" COUNT 2' },
  },
  LPUSH = {
    category = "Lists", syntax = "LPUSH key element [element ...]",
    desc = "Prepend one or more elements onto the head of the list.",
    example = { "LPUSH mylist b c" },
  },
  LPUSHX = {
    category = "Lists", syntax = "LPUSHX key element [element ...]",
    desc = "Prepend elements only when the list already exists.",
    example = { "LPUSHX mylist a" },
  },
  LRANGE = {
    category = "Lists", syntax = "LRANGE key start stop",
    desc = "Return a range of elements by index (-1 = last element).",
    example = { "LRANGE mylist 0 -1" },
  },
  LREM = {
    category = "Lists", syntax = "LREM key count element",
    desc = "Remove matching elements; count>0 from head, count<0 from tail, 0 = all.",
    example = { 'LREM mylist -2 "a"' },
  },
  LSET = {
    category = "Lists", syntax = "LSET key index value",
    desc = "Set the list element at the given index.",
    example = { 'LSET mylist 1 "updated"' },
  },
  LTRIM = {
    category = "Lists", syntax = "LTRIM key start stop",
    desc = "Trim the list to only the given index range, in place.",
    example = { "LTRIM mylist 0 99" },
  },
  RPOP = {
    category = "Lists", syntax = "RPOP key [count]",
    desc = "Remove and return the last (tail) element(s) of the list.",
    example = { "RPOP mylist" },
  },
  RPOPLPUSH = {
    category = "Lists", syntax = "RPOPLPUSH source destination",
    desc = "Pop the tail of source and push it onto the head of destination, atomically.",
    example = { "RPOPLPUSH q1 q2" },
  },
  RPUSH = {
    category = "Lists", syntax = "RPUSH key element [element ...]",
    desc = "Append one or more elements onto the tail of the list.",
    example = { "RPUSH mylist 1 2 3" },
  },
  RPUSHX = {
    category = "Lists", syntax = "RPUSHX key element [element ...]",
    desc = "Append elements only when the list already exists.",
    example = { "RPUSHX mylist a" },
  },
  -- Sets
  SADD = {
    category = "Sets", syntax = "SADD key member [member ...]",
    desc = "Add one or more members to a set.",
    example = { "SADD tags:post:1 redis lua nvim" },
  },
  SCARD = {
    category = "Sets", syntax = "SCARD key",
    desc = "Return the cardinality (number of members) of the set.",
    example = { "SCARD tags:post:1" },
  },
  SDIFF = {
    category = "Sets", syntax = "SDIFF key [key ...]",
    desc = "Return the set difference (members present in the first set only).",
    example = { "SDIFF s1 s2" },
  },
  SDIFFSTORE = {
    category = "Sets", syntax = "SDIFFSTORE destination key [key ...]",
    desc = "Store the set difference into a new set.",
    example = { "SDIFFSTORE out s1 s2" },
  },
  SINTER = {
    category = "Sets", syntax = "SINTER key [key ...]",
    desc = "Return the set intersection of the given sets.",
    example = { "SINTER online:1 online:2" },
  },
  SINTERCARD = {
    category = "Sets", syntax = "SINTERCARD numkeys key [key ...] [LIMIT limit]",
    desc = "Return the cardinality of the intersection without building the set.",
    example = { "SINTERCARD 3 s1 s2 s3" },
  },
  SINTERSTORE = {
    category = "Sets", syntax = "SINTERSTORE destination key [key ...]",
    desc = "Store the set intersection into a new set.",
    example = { "SINTERSTORE out s1 s2" },
  },
  SISMEMBER = {
    category = "Sets", syntax = "SISMEMBER key member",
    desc = "Return 1 if the member exists in the set, 0 otherwise.",
    example = { "SISMEMBER tags:post:1 redis" },
  },
  SMEMBERS = {
    category = "Sets", syntax = "SMEMBERS key",
    desc = "Return all members of the set.",
    example = { "SMEMBERS tags:post:1" },
  },
  SMISMEMBER = {
    category = "Sets", syntax = "SMISMEMBER key member [member ...]",
    desc = "Batched membership check; returns 1/0 per member.",
    example = { "SMISMEMBER tags:post:1 redis lua" },
  },
  SMOVE = {
    category = "Sets", syntax = "SMOVE source destination member",
    desc = "Atomically move a member from source to destination.",
    example = { 'SMOVE s1 s2 "x"' },
  },
  SPOP = {
    category = "Sets", syntax = "SPOP key [count]",
    desc = "Remove and return one or more random members.",
    example = { "SPOP lottery 3" },
  },
  SRANDMEMBER = {
    category = "Sets", syntax = "SRANDMEMBER key [count]",
    desc = "Return one or more random members without removing them.",
    example = { "SRANDMEMBER pool 5" },
  },
  SREM = {
    category = "Sets", syntax = "SREM key member [member ...]",
    desc = "Remove one or more members from the set.",
    example = { "SREM tags:post:1 lua" },
  },
  SSCAN = {
    category = "Sets", syntax = "SSCAN key cursor [MATCH pattern] [COUNT count]",
    desc = "Incrementally iterate the members of a set.",
    example = { "SSCAN tags:post:1 0 MATCH r*" },
  },
  SUNION = {
    category = "Sets", syntax = "SUNION key [key ...]",
    desc = "Return the set union of the given sets.",
    example = { "SUNION s1 s2" },
  },
  SUNIONSTORE = {
    category = "Sets", syntax = "SUNIONSTORE destination key [key ...]",
    desc = "Store the set union into a new set.",
    example = { "SUNIONSTORE merged s1 s2" },
  },
  -- Sorted sets
  BZPOPMAX = {
    category = "Sorted sets", syntax = "BZPOPMAX key [key ...] timeout",
    desc = "Blocking ZPOPMAX (remove highest-score member); 0 = wait forever.",
    example = { "BZPOPMAX leaderboard 0" },
  },
  BZPOPMIN = {
    category = "Sorted sets", syntax = "BZPOPMIN key [key ...] timeout",
    desc = "Blocking ZPOPMIN (remove lowest-score member); 0 = wait forever.",
    example = { "BZPOPMIN taskqueue 0" },
  },
  ZADD = {
    category = "Sorted sets", syntax = "ZADD key [NX | XX] [GT | LT] [CH] [INCR] score member [score member ...]",
    desc = "Add members with a numeric score, or update the score of existing members.",
    example = { 'ZADD leaderboard 100 "alice" 90 "bob"' },
  },
  ZCARD = {
    category = "Sorted sets", syntax = "ZCARD key",
    desc = "Return the number of members in the sorted set.",
    example = { "ZCARD leaderboard" },
  },
  ZCOUNT = {
    category = "Sorted sets", syntax = "ZCOUNT key min max",
    desc = "Count members whose score falls in the inclusive [min, max] range.",
    example = { "ZCOUNT leaderboard 80 100" },
  },
  ZDIFF = {
    category = "Sorted sets", syntax = "ZDIFF numkeys key [key ...] [WITHSCORES]",
    desc = "Return the difference between sorted sets (members left after subtraction).",
    example = { "ZDIFF 2 s1 s2" },
  },
  ZDIFFSTORE = {
    category = "Sorted sets", syntax = "ZDIFFSTORE destination numkeys key [key ...]",
    desc = "Compute the difference between sorted sets and store the result.",
    example = { "ZDIFFSTORE out 2 s1 s2" },
  },
  ZINCRBY = {
    category = "Sorted sets", syntax = "ZINCRBY key increment member",
    desc = "Increase the score of a member by the given amount.",
    example = { 'ZINCRBY leaderboard 5 "alice"' },
  },
  ZINTER = {
    category = "Sorted sets", syntax = "ZINTER numkeys key [key ...] [WEIGHTS weight [weight ...]] [AGGREGATE SUM | MIN | MAX] [WITHSCORES]",
    desc = "Return the intersection of sorted sets.",
    example = { "ZINTER 2 z1 z2 WITHSCORES" },
  },
  ZINTERCARD = {
    category = "Sorted sets", syntax = "ZINTERCARD numkeys key [key ...] [LIMIT limit]",
    desc = "Return the cardinality of the intersection of sorted sets.",
    example = { "ZINTERCARD 2 z1 z2" },
  },
  ZINTERSTORE = {
    category = "Sorted sets", syntax = "ZINTERSTORE destination numkeys key [key ...] [WEIGHTS weight [weight ...]] [AGGREGATE SUM | MIN | MAX]",
    desc = "Compute the intersection of sorted sets and store the result.",
    example = { "ZINTERSTORE out 2 z1 z2 WEIGHTS 2 3" },
  },
  ZLEXCOUNT = {
    category = "Sorted sets", syntax = "ZLEXCOUNT key min max",
    desc = "Count members in a lexicographic range (same-score members only).",
    example = { "ZLEXCOUNT myzset [a [f" },
  },
  ZMPOP = {
    category = "Sorted sets", syntax = "ZMPOP numkeys key [key ...] MIN | MAX [COUNT count]",
    desc = "Pop the lowest/highest-score members from the first non-empty key.",
    example = { "ZMPOP 1 leaderboard MIN COUNT 2" },
  },
  ZMSCORE = {
    category = "Sorted sets", syntax = "ZMSCORE key member [member ...]",
    desc = "Return the scores of multiple members (nil for missing).",
    example = { "ZMSCORE leaderboard alice bob" },
  },
  ZPOPMAX = {
    category = "Sorted sets", syntax = "ZPOPMAX key [count]",
    desc = "Remove and return the highest-score member(s).",
    example = { "ZPOPMAX leaderboard 3" },
  },
  ZPOPMIN = {
    category = "Sorted sets", syntax = "ZPOPMIN key [count]",
    desc = "Remove and return the lowest-score member(s).",
    example = { "ZPOPMIN queue 5" },
  },
  ZRANDMEMBER = {
    category = "Sorted sets", syntax = "ZRANDMEMBER key [count [WITHSCORES]]",
    desc = "Return one or more random members (negative count allows repeats).",
    example = { "ZRANDMEMBER leaderboard -3" },
  },
  ZRANGE = {
    category = "Sorted sets", syntax = "ZRANGE key start stop [WITHSCORES] | ZRANGE key min max BYSCORE | BYLEX [REV] [OFFSET,count] [WITHSCORES]",
    desc = "Return members by index rank, or (BYSCORE/BYLEX) by score/lex range.",
    example = { "ZRANGE leaderboard 0 -1 WITHSCORES" },
  },
  ZRANGEBYLEX = {
    category = "Sorted sets", syntax = "ZRANGEBYLEX key min max [LIMIT offset count]",
    desc = "Return members in a lexicographic range (same-score members only).",
    example = { "ZRANGEBYLEX words [a [z" },
  },
  ZRANGEBYSCORE = {
    category = "Sorted sets", syntax = "ZRANGEBYSCORE key min max [WITHSCORES] [LIMIT offset count]",
    desc = "Return members whose score falls in [min, max] (-inf/+inf allowed).",
    example = { "ZRANGEBYSCORE leaderboard 80 +inf" },
  },
  ZRANGESTORE = {
    category = "Sorted sets", syntax = "ZRANGESTORE dst src min max [BYSCORE | BYLEX] [REV] [LIMIT offset count]",
    desc = "Store the result of a ZRANGE into a destination sorted set.",
    example = { "ZRANGESTORE top3 leaderboard 0 2" },
  },
  ZRANK = {
    category = "Sorted sets", syntax = "ZRANK key member",
    desc = "Return the 0-based rank of a member (lowest score = rank 0).",
    example = { "ZRANK leaderboard alice" },
  },
  ZREM = {
    category = "Sorted sets", syntax = "ZREM key member [member ...]",
    desc = "Remove one or more members from the sorted set.",
    example = { "ZREM leaderboard bob" },
  },
  ZREMRANGEBYLEX = {
    category = "Sorted sets", syntax = "ZREMRANGEBYLEX key min max",
    desc = "Remove members in a lexicographic range.",
    example = { "ZREMRANGEBYLEX words [a [d" },
  },
  ZREMRANGEBYRANK = {
    category = "Sorted sets", syntax = "ZREMRANGEBYRANK key start stop",
    desc = "Remove members within the index rank range.",
    example = { "ZREMRANGEBYRANK leaderboard 0 4" },
  },
  ZREMRANGEBYSCORE = {
    category = "Sorted sets", syntax = "ZREMRANGEBYSCORE key min max",
    desc = "Remove members whose score falls in [min, max].",
    example = { "ZREMRANGEBYSCORE leaderboard -inf 60" },
  },
  ZREVRANGE = {
    category = "Sorted sets", syntax = "ZREVRANGE key start stop [WITHSCORES]",
    desc = "Return members by rank, highest score first.",
    example = { "ZREVRANGE leaderboard 0 9 WITHSCORES" },
  },
  ZREVRANGEBYLEX = {
    category = "Sorted sets", syntax = "ZREVRANGEBYLEX key max min [LIMIT offset count]",
    desc = "Return members in a lexicographic range, reverse order.",
    example = { "ZREVRANGEBYLEX words [z [a" },
  },
  ZREVRANGEBYSCORE = {
    category = "Sorted sets", syntax = "ZREVRANGEBYSCORE key max min [WITHSCORES] [LIMIT offset count]",
    desc = "Return members by descending score within [max, min].",
    example = { "ZREVRANGEBYSCORE leaderboard +inf 80" },
  },
  ZREVRANK = {
    category = "Sorted sets", syntax = "ZREVRANK key member",
    desc = "Return the rank of a member from the top (highest score = rank 0).",
    example = { "ZREVRANK leaderboard alice" },
  },
  ZSCAN = {
    category = "Sorted sets", syntax = "ZSCAN key cursor [MATCH pattern] [COUNT count]",
    desc = "Incrementally iterate members and scores of a sorted set.",
    example = { "ZSCAN leaderboard 0 MATCH a*" },
  },
  ZSCORE = {
    category = "Sorted sets", syntax = "ZSCORE key member",
    desc = "Return the score of a single member.",
    example = { "ZSCORE leaderboard alice" },
  },
  ZUNION = {
    category = "Sorted sets", syntax = "ZUNION numkeys key [key ...] [WEIGHTS weight [weight ...]] [AGGREGATE SUM | MIN | MAX] [WITHSCORES]",
    desc = "Return the union of sorted sets.",
    example = { "ZUNION 2 z1 z2 WITHSCORES" },
  },
  ZUNIONSTORE = {
    category = "Sorted sets", syntax = "ZUNIONSTORE destination numkeys key [key ...] [WEIGHTS weight [weight ...]] [AGGREGATE SUM | MIN | MAX]",
    desc = "Compute the union of sorted sets and store the result.",
    example = { "ZUNIONSTORE out 2 z1 z2 WEIGHTS 2 3" },
  },
  -- Streams
  XACK = {
    category = "Streams", syntax = "XACK key group id [id ...]",
    desc = "Acknowledge one or more pending messages as processed.",
    example = { "XACK mystream mygroup 1526569495631-0" },
  },
  XADD = {
    category = "Streams", syntax = "XADD key [NOMKSTREAM] [MAXLEN | MINID [= | ~] threshold [LIMIT count]] id field value [field value ...]",
    desc = "Append a message to the stream; use `*` to auto-generate the ID.",
    example = { 'XADD events * "user" 42 "action" "login"' },
  },
  XAUTOCLAIM = {
    category = "Streams", syntax = "XAUTOCLAIM key group consumer min-idle-time start [COUNT count] [JUSTID]",
    desc = "Claim idle pending messages for a consumer, auto-advancing the cursor.",
    example = { "XAUTOCLAIM mystream mygroup c1 3000 0 COUNT 10" },
  },
  XCLAIM = {
    category = "Streams", syntax = "XCLAIM key group consumer min-idle-time id [id ...] [TIME ms-unix-time] [RETRYCOUNT count] [FORCE] [JUSTID]",
    desc = "Manually claim one or more pending messages for a consumer.",
    example = { "XCLAIM mystream mygroup c1 3600000 0-0" },
  },
  XDEL = {
    category = "Streams", syntax = "XDEL key id [id ...]",
    desc = "Delete one or more messages from the stream.",
    example = { "XDEL mystream 1526569495631-0" },
  },
  XGROUP = {
    category = "Streams", syntax = "XGROUP CREATE key group id | $ [MKSTREAM] | XGROUP SETID | DESTROY | CREATECONSUMER | DELCONSUMER",
    desc = "Manage consumer groups: create, destroy, and set the last-delivered ID.",
    example = { "XGROUP CREATE mystream mygroup $ MKSTREAM" },
  },
  XINFO = {
    category = "Streams", syntax = "XINFO STREAM key [FULL [COUNT count]] | XINFO GROUPS key | XINFO CONSUMERS key group",
    desc = "Stream and consumer-group introspection.",
    example = { "XINFO STREAM mystream", "XINFO GROUPS mystream" },
  },
  XLEN = {
    category = "Streams", syntax = "XLEN key",
    desc = "Return the number of messages in the stream.",
    example = { "XLEN mystream" },
  },
  XPENDING = {
    category = "Streams", syntax = "XPENDING key group [idle min-idle-time] [start end count [consumer]]",
    desc = "Summary of pending (unacknowledged) messages for a group.",
    example = { "XPENDING mystream mygroup" },
  },
  XRANGE = {
    category = "Streams", syntax = "XRANGE key start end [COUNT count]",
    desc = "Return messages between two IDs (`-` and `+` for the extremes).",
    example = { "XRANGE mystream - + COUNT 10" },
  },
  XREAD = {
    category = "Streams", syntax = "XREAD [COUNT count] [BLOCK milliseconds] STREAMS key [key ...] id [id ...]",
    desc = "Read from one or more streams at (or after) a given ID; `$` waits for new.",
    example = { "XREAD BLOCK 5000 STREAMS mystream $" },
  },
  XREADGROUP = {
    category = "Streams", syntax = "XREADGROUP GROUP group consumer [COUNT count] [BLOCK milliseconds] [NOACK] STREAMS key [key ...] id [id ...]",
    desc = "Read from a stream as a consumer-group member; `>` means new messages.",
    example = { "XREADGROUP GROUP mygroup c1 COUNT 10 STREAMS mystream >" },
  },
  XREVRANGE = {
    category = "Streams", syntax = "XREVRANGE key end start [COUNT count]",
    desc = "Return messages between two IDs in reverse order.",
    example = { "XREVRANGE mystream + - COUNT 5" },
  },
  XSETID = {
    category = "Streams", syntax = "XSETID key last-id [ENTRIESADDED entries-added] [MAXDELETEDID max-deleted-id]",
    desc = "Manually set the last delivered ID of a stream.",
    example = { "XSETID mystream 1526569495631-0" },
  },
  XTRIM = {
    category = "Streams", syntax = "XTRIM key MAXLEN | MINID [= | ~] threshold [LIMIT count]",
    desc = "Trim the stream to a maximum length or minimum ID.",
    example = { "XTRIM mystream MAXLEN ~ 1000" },
  },
  -- HyperLogLog
  PFADD = {
    category = "HyperLogLog", syntax = "PFADD key [element [element ...]]",
    desc = "Add one or more elements to a HyperLogLog (approx distinct count).",
    example = { "PFADD unique:today user1 user2" },
  },
  PFCOUNT = {
    category = "HyperLogLog", syntax = "PFCOUNT key [key ...]",
    desc = "Return the approximated cardinality of the HyperLogLog.",
    example = { "PFCOUNT unique:today" },
  },
  PFMERGE = {
    category = "HyperLogLog", syntax = "PFMERGE destkey sourcekey [sourcekey ...]",
    desc = "Merge multiple HyperLogLogs into a single one.",
    example = { "PFMERGE unique:week unique:today unique:yesterday" },
  },
  -- Geo
  GEOADD = {
    category = "Geo", syntax = "GEOADD key [NX | XX] [CH] longitude latitude member [longitude latitude member ...]",
    desc = "Add one or more members with longitude/latitude coordinates.",
    example = { 'GEOADD cities 13.361389 38.115556 "Palermo"' },
  },
  GEODIST = {
    category = "Geo", syntax = "GEODIST key member1 member2 [m | km | ft | mi]",
    desc = "Return the distance between two members (default meters).",
    example = { 'GEODIST cities "Palermo" "Catania" km' },
  },
  GEOHASH = {
    category = "Geo", syntax = "GEOHASH key member [member ...]",
    desc = "Return the standard GeoHash string(s) of the members.",
    example = { "GEOHASH cities Palermo" },
  },
  GEOPOS = {
    category = "Geo", syntax = "GEOPOS key member [member ...]",
    desc = "Return the longitude/latitude of one or more members.",
    example = { "GEOPOS cities Palermo" },
  },
  GEORADIUS = {
    category = "Geo", syntax = "GEORADIUS key longitude latitude radius m | km | ft | mi [WITHCOORD] [WITHDIST] [WITHHASH] [COUNT count [ANY]] [ASC | DESC] [STORE key | STOREDIST key]",
    desc = "Return members within a circle around given coordinates (deprecated — use GEOSEARCH).",
    example = { "GEORADIUS cities 15 37 200 km" },
  },
  GEORADIUSBYMEMBER = {
    category = "Geo", syntax = "GEORADIUSBYMEMBER key member radius m | km | ft | mi [WITHCOORD] [WITHDIST] [WITHHASH] [COUNT count [ANY]] [ASC | DESC] [STORE key | STOREDIST key]",
    desc = "Like GEORADIUS but centered on an existing member (deprecated — use GEOSEARCH).",
    example = { 'GEORADIUSBYMEMBER cities "Palermo" 100 km' },
  },
  GEOSEARCH = {
    category = "Geo", syntax = "GEOSEARCH key FROMMEMBER member | FROMLONLAT longitude latitude BYRADIUS radius m | km | ft | mi | BYBOX width height m | km | ft | mi [ASC | DESC] [COUNT count [ANY]] [WITHCOORD] [WITHDIST] [WITHHASH]",
    desc = "Search members within a circular or box-shaped area.",
    example = { 'GEOSEARCH cities FROMMEMBER "Palermo" BYRADIUS 200 km ASC' },
  },
  GEOSEARCHSTORE = {
    category = "Geo", syntax = "GEOSEARCHSTORE destination source FROMMEMBER member | FROMLONLAT longitude latitude BYRADIUS | BYBOX ... [ASC | DESC] [COUNT count [ANY]] [STOREDIST]",
    desc = "Run a GEOSEARCH and store the result into a destination key.",
    example = { 'GEOSEARCHSTORE nearby cities FROMMEMBER "Palermo" BYBOX 400 400 km' },
  },
  -- Server
  ACL = {
    category = "Server", syntax = "ACL SUBCOMMAND [arg ...]",
    desc = "Access-control-list management (ACL SETUSER, GETUSER, LIST, CAT, WHOAMI...).",
    example = { "ACL LIST", 'ACL SETUSER myuser on >password ~* +@all -FLUSHALL' },
  },
  BGREWRITEAOF = {
    category = "Server", syntax = "BGREWRITEAOF",
    desc = "Asynchronously rewrite the append-only file to compact it.",
    example = { "BGREWRITEAOF" },
  },
  BGSAVE = {
    category = "Server", syntax = "BGSAVE [SCHEDULE]",
    desc = "Snapshot the dataset to disk in the background.",
    example = { "BGSAVE" },
  },
  CLIENT = {
    category = "Server", syntax = "CLIENT SUBCOMMAND [arg ...]",
    desc = "Connection management: LIST, ID, INFO, KILL, GETNAME, SETNAME, NO-EVICT...",
    example = { "CLIENT LIST", "CLIENT KILL TYPE normal" },
  },
  COMMAND = {
    category = "Server", syntax = "COMMAND [SUBCOMMAND] [arg ...]",
    desc = "Introspection over the command table (COUNT, INFO, GETKEYS, DOCS...).",
    example = { "COMMAND COUNT", "COMMAND GETKEYS HSET k f v" },
  },
  CONFIG = {
    category = "Server", syntax = "CONFIG GET parameter [parameter ...] | CONFIG SET parameter value [parameter value ...] | CONFIG RESETSTAT | CONFIG REWRITE",
    desc = "Read and modify the server runtime configuration.",
    example = { "CONFIG GET maxmemory", "CONFIG SET maxmemory 512mb" },
  },
  DBSIZE = {
    category = "Server", syntax = "DBSIZE",
    desc = "Return the number of keys in the current database.",
    example = { "DBSIZE" },
  },
  DEBUG = {
    category = "Server", syntax = "DEBUG SUBCOMMAND [arg ...]",
    desc = "Internal debugging commands — reserved for tracing (OBJECT, SLEEP, SET-ACTIVE-EXPIRE...).",
    example = { "DEBUG OBJECT mykey" },
  },
  FLUSHALL = {
    category = "Server", syntax = "FLUSHALL [ASYNC | SYNC]",
    desc = "Delete ALL keys in ALL databases. Irreversible — ASYNC to avoid blocking.",
    example = { "FLUSHALL ASYNC" },
  },
  FLUSHDB = {
    category = "Server", syntax = "FLUSHDB [ASYNC | SYNC]",
    desc = "Delete all keys in the current database. Irreversible.",
    example = { "FLUSHDB ASYNC" },
  },
  INFO = {
    category = "Server", syntax = "INFO [section [section ...]]",
    desc = "Return server statistics grouped by section (server, memory, cpu...).",
    example = { "INFO server", "INFO all" },
  },
  LASTSAVE = {
    category = "Server", syntax = "LASTSAVE",
    desc = "Return the Unix timestamp of the last successful RDB save.",
    example = { "LASTSAVE" },
  },
  LATENCY = {
    category = "Server", syntax = "LATENCY SUBCOMMAND [arg ...]",
    desc = "Latency introspection (LATEST, HISTORY, RESET, DOCTOR...).",
    example = { "LATENCY LATEST", "LATENCY HISTORY command" },
  },
  LOLWUT = {
    category = "Server", syntax = "LOLWUT [version]",
    desc = "Display a piece of visual art produced by the server.",
    example = { "LOLWUT" },
  },
  MEMORY = {
    category = "Server", syntax = "MEMORY SUBCOMMAND [arg ...]",
    desc = "Memory introspection (USAGE, STATS, MALLOC-STATS, PURGE, DOCTOR...).",
    example = { "MEMORY USAGE mykey", "MEMORY DOCTOR" },
  },
  MODULE = {
    category = "Server", syntax = "MODULE SUBCOMMAND [arg ...]",
    desc = "Dynamic module management (LIST, LOAD, UNLOAD...).",
    example = { "MODULE LIST", "MODULE LOAD /path/to/plugin.so" },
  },
  MONITOR = {
    category = "Server", syntax = "MONITOR",
    desc = "Stream every command the server receives to the client (debugging only).",
    example = { "MONITOR" },
  },
  REPLICAOF = {
    category = "Server", syntax = "REPLICAOF host port | REPLICAOF NO ONE",
    desc = "Configure the instance as a replica of another, or promote back to master.",
    example = { "REPLICAOF NO ONE" },
  },
  ROLE = {
    category = "Server", syntax = "ROLE",
    desc = "Return the replication role and topology of the instance.",
    example = { "ROLE" },
  },
  SAVE = {
    category = "Server", syntax = "SAVE",
    desc = "Synchronously save a snapshot to disk (blocks — prefer BGSAVE).",
    example = { "SAVE" },
  },
  SHUTDOWN = {
    category = "Server", syntax = "SHUTDOWN [NOSAVE | SAVE] [NOW] [FORCE] [ABORT]",
    desc = "Shut down the server, optionally persisting first. Dangerous.",
    example = { "SHUTDOWN" },
  },
  SLAVEOF = {
    category = "Server", syntax = "SLAVEOF host port | SLAVEOF NO ONE",
    desc = "Deprecated alias of REPLICAOF.",
    example = { "SLAVEOF NO ONE" },
  },
  SLOWLOG = {
    category = "Server", syntax = "SLOWLOG GET [count] | SLOWLOG RESET | SLOWLOG LEN",
    desc = "Manage and inspect the slow query log.",
    example = { "SLOWLOG GET 10" },
  },
  SWAPDB = {
    category = "Server", syntax = "SWAPDB index1 index2",
    desc = "Swap two databases atomically.",
    example = { "SWAPDB 0 1" },
  },
  TIME = {
    category = "Server", syntax = "TIME",
    desc = "Return the server time as [seconds, microseconds].",
    example = { "TIME" },
  },
  -- Connection
  AUTH = {
    category = "Connection", syntax = "AUTH [username] password",
    desc = "Authenticate the connection (AUTH password, or AUTH username password).",
    example = { "AUTH mypassword", "AUTH default mypassword" },
  },
  ECHO = {
    category = "Connection", syntax = "ECHO message",
    desc = "Return the given message unchanged.",
    example = { 'ECHO "hi"' },
  },
  HELLO = {
    category = "Connection", syntax = "HELLO [protover [AUTH username password] [SETNAME client-name]]",
    desc = "Handshake: negotiate the protocol version (3 = RESP3) and set the client name.",
    example = { "HELLO 3" },
  },
  PING = {
    category = "Connection", syntax = "PING [message]",
    desc = "Round-trip liveness check; returns PONG or the given message.",
    example = { "PING" },
  },
  QUIT = {
    category = "Connection", syntax = "QUIT",
    desc = "Ask the server to close the connection.",
    example = { "QUIT" },
  },
  SELECT = {
    category = "Connection", syntax = "SELECT index",
    desc = "Switch to a different database (0 by default; 0-15 on the standard setup).",
    example = { "SELECT 3" },
  },
  RESET = {
    category = "Connection", syntax = "RESET",
    desc = "Reset the connection state: discards MULTI, unwatches keys, exits subscribe mode.",
    example = { "RESET" },
  },
  -- Transactions
  DISCARD = {
    category = "Transactions", syntax = "DISCARD",
    desc = "Abort the transaction initiated with MULTI.",
    example = { "DISCARD" },
  },
  EXEC = {
    category = "Transactions", syntax = "EXEC",
    desc = "Execute all queued commands of the MULTI transaction, atomically.",
    example = { "EXEC" },
  },
  MULTI = {
    category = "Transactions", syntax = "MULTI",
    desc = "Begin queueing commands; they run atomically on EXEC.",
    example = { "MULTI" },
  },
  UNWATCH = {
    category = "Transactions", syntax = "UNWATCH",
    desc = "Forget all keys watched via WATCH.",
    example = { "UNWATCH" },
  },
  WATCH = {
    category = "Transactions", syntax = "WATCH key [key ...]",
    desc = "Watch keys for optimistic locking; EXEC aborts if any changed.",
    example = { "WATCH balance" },
  },
  -- Scripting
  EVAL = {
    category = "Scripting", syntax = "EVAL script numkeys [key [key ...]] [arg [arg ...]]",
    desc = "Evaluate a Lua script; KEYS[i] and ARGV[i] index the passed parameters (1-based).",
    example = { "EVAL \"return redis.call('GET', KEYS[1])\" 1 mykey" },
  },
  EVALSHA = {
    category = "Scripting", syntax = "EVALSHA sha1 numkeys [key [key ...]] [arg [arg ...]]",
    desc = "Evaluate a cached script by its SHA1 digest (see SCRIPT LOAD).",
    example = { "EVALSHA e0e1f9ab87912a7e6c7f 1 mykey" },
  },
  EVALSHA_RO = {
    category = "Scripting", syntax = "EVALSHA_RO sha1 numkeys [key [key ...]] [arg [arg ...]]",
    desc = "Read-only variant of EVALSHA (safe on replicas).",
    example = { "EVALSHA e0e1f9ab 0" },
  },
  EVAL_RO = {
    category = "Scripting", syntax = "EVAL_RO script numkeys [key [key ...]] [arg [arg ...]]",
    desc = "Read-only variant of EVAL (safe on replicas).",
    example = { "EVAL_RO \"return 1\" 0" },
  },
  FCALL = {
    category = "Scripting", syntax = "FCALL function numkeys [key [key ...]] [arg [arg ...]]",
    desc = "Invoke a server-side function previously loaded via FUNCTION LOAD.",
    example = { "FCALL mylib.myfunc 1 mykey arg1" },
  },
  FCALL_RO = {
    category = "Scripting", syntax = "FCALL_RO function numkeys [key [key ...]] [arg [arg ...]]",
    desc = "Read-only variant of FCALL (safe on replicas).",
    example = { "FCALL_RO mylib.readonly 0" },
  },
  FUNCTION = {
    category = "Scripting", syntax = "FUNCTION SUBCOMMAND [arg ...]",
    desc = "Manage server-side functions: LOAD, LIST, DELETE, DUMP, RESTORE, KILL, STATS...",
    example = { "FUNCTION LIST", "FUNCTION LOAD \"#!lua name=mylib\\nredis.register_function('hello', function() return 'hi' end)\"" },
  },
  SCRIPT = {
    category = "Scripting", syntax = "SCRIPT SUBCOMMAND [arg ...]",
    desc = "Manage the script cache: LOAD, EXISTS, FLUSH, KILL.",
    example = { "SCRIPT LOAD \"return redis.call('GET', KEYS[1])\"", "SCRIPT EXISTS e0e1f9ab" },
  },
  -- Pub/Sub
  PSUBSCRIBE = {
    category = "Pub/Sub", syntax = "PSUBSCRIBE pattern [pattern ...]",
    desc = "Subscribe to channels matching a glob pattern.",
    example = { "PSUBSCRIBE news.*" },
  },
  PUBLISH = {
    category = "Pub/Sub", syntax = "PUBLISH channel message",
    desc = "Post a message to a channel; returns the number of subscribers that received it.",
    example = { 'PUBLISH news "cats are cute"' },
  },
  PUBSUB = {
    category = "Pub/Sub", syntax = "PUBSUB CHANNELS [pattern] | PUBSUB NUMSUB [channel ...] | PUBSUB NUMPAT | PUBSUB SHARDCHANNELS [pattern] | PUBSUB SHARDNUMSUB [channel ...]",
    desc = "Introspect the pub/sub state.",
    example = { "PUBSUB CHANNELS news.*" },
  },
  PUNSUBSCRIBE = {
    category = "Pub/Sub", syntax = "PUNSUBSCRIBE [pattern [pattern ...]]",
    desc = "Unsubscribe from one or more (or all) channel patterns.",
    example = { "PUNSUBSCRIBE news.*" },
  },
  SPUBLISH = {
    category = "Pub/Sub", syntax = "SPUBLISH shardchannel message",
    desc = "Publish a message to a shard channel (often used with cluster mode).",
    example = { 'SPUBLISH shards:1 "hi"' },
  },
  SSUBSCRIBE = {
    category = "Pub/Sub", syntax = "SSUBSCRIBE shardchannel [shardchannel ...]",
    desc = "Subscribe to one or more shard channels.",
    example = { "SSUBSCRIBE shards:1" },
  },
  SUBSCRIBE = {
    category = "Pub/Sub", syntax = "SUBSCRIBE channel [channel ...]",
    desc = "Subscribe to one or more channels; messages arrive asynchronously.",
    example = { "SUBSCRIBE news" },
  },
  SUNSUBSCRIBE = {
    category = "Pub/Sub", syntax = "SUNSUBSCRIBE [shardchannel [shardchannel ...]]",
    desc = "Unsubscribe from one or more (or all) shard channels.",
    example = { "SUNSUBSCRIBE shards:1" },
  },
  UNSUBSCRIBE = {
    category = "Pub/Sub", syntax = "UNSUBSCRIBE [channel [channel ...]]",
    desc = "Unsubscribe from one or more (or all) channels.",
    example = { "UNSUBSCRIBE news" },
  },
  -- Cluster
  ASKING = {
    category = "Cluster", syntax = "ASKING",
    desc = "Signal that the next command should be served despite a MIGRATING slot (cluster).",
    example = { "ASKING" },
  },
  CLUSTER = {
    category = "Cluster", syntax = "CLUSTER SUBCOMMAND [arg ...]",
    desc = "Cluster management: INFO, SLOTS, NODES, SHARDS, MYID, MEET, FORGET...",
    example = { "CLUSTER INFO", "CLUSTER SLOTS" },
  },
  READONLY = {
    category = "Cluster", syntax = "READONLY",
    desc = "Enable read-only mode on a cluster replica so reads can be routed to it.",
    example = { "READONLY" },
  },
  READWRITE = {
    category = "Cluster", syntax = "READWRITE",
    desc = "Disable read-only replica mode (default).",
    example = { "READWRITE" },
  },
  -- File-level directive (parser kind="use")
  USE = {
    category = "File directive", syntax = "USE <connection>",
    desc = "Select the connection (from connections.toml) used by subsequent commands on the block.",
    example = { "USE production" },
  },
}

--- Look up a command doc by name (case-insensitive: "hset" → HSET).
--- @param cmd string
--- @return table|nil
function M.lookup(cmd)
  if type(cmd) ~= "string" then return nil end
  return DOCS[cmd:upper()]
end

M.DOCS = DOCS

M._test = {
  DOCS = DOCS,
  lookup = M.lookup,
}

return M