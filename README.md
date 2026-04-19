В репозитории несколько стендов Podman Compose:

1. [Корень](compose.yaml) - Исходный PoC: один MongoDB + API
1. [mongo-sharding/](mongo-sharding/) - Шардирование (2 шарда), mongos, config server
1. [mongo-sharding-repl/](mongo-sharding-repl/) - То же + по 3 реплики на каждый шард
1. [sharding-repl-cache/](sharding-repl-cache/) - финальный вариант: шарды, реплики, Redis, API

**Схемы:** [diagrams/architecture-final.drawio](diagrams/architecture-final.drawio) — несколько вкладок (шардирование → репликация → Redis → API Gateway / Consul → CDN). На первой (0) вкладке финальная схема

**Архитектурный документ (задания 7–10):** [ARCHITECTURE.md](ARCHITECTURE.md).

## Требования

Точно работает на podman (compose), но по идее можно без проблем запуститься и с docker (во всех командах вместо podman писать docker)


## Финальный стенд: `sharding-repl-cache`

MongoDB с шардированием и репликацией (по 3 узла на шард), mongos, config server, Redis для кеша ответов API.

```shell
cd sharding-repl-cache
podman compose up -d
```

Инициализация кластера:

```shell
chmod +x scripts/init-cluster.sh scripts/mongo-init.sh
./scripts/init-cluster.sh
./scripts/mongo-init.sh
```

Переменная **`REDIS_URL`** задана в [sharding-repl-cache/compose.yaml](sharding-repl-cache/compose.yaml): `redis://redis:6379`.

### Проверка

- [http://localhost:8080/](http://localhost:8080/) — JSON: топология, шарды, **`helloDoc_documents_per_shard`**, **`shard_replica_members`**, **`cache_enabled`: `true`**
- [http://localhost:8080/docs](http://localhost:8080/docs) — Swagger

Кешируется `GET /helloDoc/users`: первый запрос ~1 с, повторные из Redis — около 100 ms:

```shell
curl -o /dev/null -s -w "first %{time_total}s\n" http://localhost:8080/helloDoc/users
curl -o /dev/null -s -w "second %{time_total}s\n" http://localhost:8080/helloDoc/users
```

Образ API собирается из каталога **`api_app`** внутри стенда (совместим с образом `kazhem/pymongo_api:1.0.0`, с Redis и сводкой по шардам).

## Стенд `mongo-sharding` (только шардирование)

Два шарда (по одному узлу), config server, mongos, без полноценной многоузловой репликации по шардам.

```shell
cd mongo-sharding
podman compose up -d
chmod +x scripts/init-cluster.sh scripts/mongo-init.sh
./scripts/init-cluster.sh
./scripts/mongo-init.sh
```

**Что делают скрипты**

1. **`init-cluster.sh`** — инициализирует replica set **config_rs** на `configSrv:27019`; одноузловые replica set **shard1** и **shard2** на `shard1:27018` и `shard2:27020`; перезапускает **mongos**; выполняет `sh.addShard`, `sh.enableSharding("somedb")`, `sh.shardCollection("somedb.helloDoc", { _id: "hashed" })`.
2. **`mongo-init.sh`** — вставляет **1000** документов в `helloDoc`

В ответе на `/`: `mongo_topology_type: Sharded`, `mongo_is_mongos: true`, `collections.helloDoc.documents_count`, **`helloDoc_documents_per_shard`**, **`shards`**.

Дополнительно через mongosh на mongos:

```shell
podman compose exec -T mongos mongosh --port 27017 --quiet <<'EOF'
sh.status()
use somedb
db.helloDoc.getShardDistribution()
EOF
```

---

## Стенд `mongo-sharding-repl` (шардирование + репликация)

У каждого шарда **три реплики**: узлы `shard1-1` … `shard1-3` и `shard2-1` … `shard2-3`.

```shell
cd mongo-sharding-repl
podman compose up -d
chmod +x scripts/init-cluster.sh scripts/mongo-init.sh
./scripts/init-cluster.sh
./scripts/mongo-init.sh
```

**`init-cluster.sh`** поднимает **configSrv**, инициализирует replica set **shard1** и **shard2** (по 3 члена), перезапускает **mongos**, регистрирует шарды и шардирует `somedb.helloDoc` по хэшу `_id`.

В JSON на `/`: **`helloDoc_documents_per_shard`**, **`shard_replica_members`** (часто по **3** на шард; через mongos `replSetGetStatus` для всего кластера может быть недоступен).

Проверка реплик на узле шарда:

```shell
podman compose exec -T shard1-1 mongosh --port 27018 --quiet <<'EOF'
rs.status()
EOF
```

Распределение по шардам:

```shell
podman compose exec -T mongos mongosh --port 27017 --quiet <<'EOF'
use somedb
db.helloDoc.getShardDistribution()
EOF
```

---

## Исходный PoC (корень репозитория)

Один инстанс MongoDB и API без шардирования:

```shell
podman compose up -d
./scripts/mongo-init.sh
```

Откройте [http://localhost:8080/](http://localhost:8080/).

---

## Доступ с виртуальной машины

Узнать внешний IP и открыть в браузере `http://<ip>:8080`:

```shell
curl --silent http://ifconfig.me
```
