#!/usr/bin/env bash
set -euo pipefail

COMPOSE="${COMPOSE:-podman compose}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Init config_rs on configSrv"
$COMPOSE exec -T configSrv mongosh --port 27019 --quiet <<'EOF'
try {
  const s = rs.status();
  if (!s.ok) throw new Error("bad status");
} catch (e) {
  rs.initiate({
    _id: "config_rs",
    configsvr: true,
    members: [{ _id: 0, host: "configSrv:27019" }]
  });
}
EOF

echo "==> Init replica set shard1 (3 members)"
$COMPOSE exec -T shard1-1 mongosh --port 27018 --quiet <<'EOF'
try {
  rs.status();
} catch (e) {
  rs.initiate({
    _id: "shard1",
    members: [
      { _id: 0, host: "shard1-1:27018" },
      { _id: 1, host: "shard1-2:27018" },
      { _id: 2, host: "shard1-3:27018" }
    ]
  });
}
EOF

echo "==> Init replica set shard2 (3 members)"
$COMPOSE exec -T shard2-1 mongosh --port 27020 --quiet <<'EOF'
try {
  rs.status();
} catch (e) {
  rs.initiate({
    _id: "shard2",
    members: [
      { _id: 0, host: "shard2-1:27020" },
      { _id: 1, host: "shard2-2:27020" },
      { _id: 2, host: "shard2-3:27020" }
    ]
  });
}
EOF

echo "==> Waiting for replica set elections..."
sleep 8

echo "==> Restart mongos"
$COMPOSE restart mongos
sleep 5

echo "==> Add shards and enable sharding"
$COMPOSE exec -T mongos mongosh --port 27017 --quiet <<'EOF'
function safeAddShard(spec) {
  try {
    return sh.addShard(spec);
  } catch (e) {
    const msg = String(e);
    if (msg.includes("already exists") || msg.includes("duplicate")) {
      print("skip addShard (already): " + spec);
      return;
    }
    throw e;
  }
}

safeAddShard("shard1/shard1-1:27018");
safeAddShard("shard2/shard2-1:27020");

sh.enableSharding("somedb");

try {
  sh.shardCollection("somedb.helloDoc", { _id: "hashed" });
} catch (e) {
  const msg = String(e);
  if (msg.includes("already sharded")) {
    print("helloDoc already sharded");
  } else {
    throw e;
  }
}
EOF

echo "==> Cluster init done."
