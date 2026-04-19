#!/usr/bin/env bash
set -euo pipefail

# Вставка >= 1000 документов в somedb.helloDoc через mongos.

COMPOSE="${COMPOSE:-podman compose}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

$COMPOSE exec -T mongos mongosh --port 27017 --quiet <<'EOF'
use somedb
const n = 1000;
for (let i = 0; i < n; i++) {
  db.helloDoc.insertOne({ age: i, name: "ly" + i });
}
print("inserted " + n + " docs");
EOF
