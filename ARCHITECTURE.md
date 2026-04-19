## Задание 7. Схемы коллекций и шард-ключи

### Коллекция `orders`

**Назначение:** заказы, история по пользователю, статус, геозона.

**Пример документа:**

```javascript
{
  _id: ObjectId("..."),
  order_number: "ORD-2026-00001",       // уникальный номер заказа (бизнес-ключ)
  customer_id: ObjectId("..."),         // ссылка на пользователя
  created_at: ISODate("2026-04-15T10:00:00Z"),
  updated_at: ISODate("2026-04-15T10:05:00Z"),
  items: [
    { product_id: ObjectId("..."), sku: "PHONE-X", price: NumberDecimal("999.00"), qty: 1 }
  ],
  status: "paid",                       // created | paid | shipped | cancelled | ...
  total: NumberDecimal("999.00"),
  geo_zone: "MSK",
  payment_ref: "pay_abc123"             // внешняя ссылка на платёж
}
```

**Индексы (создание до/после шардирования — согласовать с выбранным shard key):**

| Индекс | Назначение |
|--------|------------|
| `{ customer_id: 1, created_at: -1 }` | История заказов пользователя (основной read-паттерн) |
| `{ order_number: 1 }` **unique** | Поиск по номеру заказа, идемпотентность |
| `{ status: 1, created_at: -1 }` | Очереди обработки по статусу (админка, воркеры) |
| `{ geo_zone: 1, created_at: -1 }` | Аналитика по геозонам |

Пример команд:

```javascript
db.orders.createIndex({ customer_id: 1, created_at: -1 })
db.orders.createIndex({ order_number: 1 }, { unique: true })
db.orders.createIndex({ status: 1, created_at: -1 })
db.orders.createIndex({ geo_zone: 1, created_at: -1 })
```

**Шард-ключ и стратегия**

- **Вариант A (равномерная запись):** `{ _id: "hashed" }` — максимально ровное распределение; запросы «все заказы клиента» идут на все шарды (scatter/gather), компенсируется кешем и агрегатами.
- **Вариант B (локальность по клиенту):** `{ customer_id: 1, _id: 1 }` или compound hashed по `customer_id` — история заказа пользователя попадает на один шард; риск «горячего» шарда при крупном B2B-клиенте.

```javascript
// Пример после создания нужного индекса под выбранный ключ:
sh.shardCollection("shop.orders", { customer_id: 1, _id: 1 })
// или
sh.shardCollection("shop.orders", { _id: "hashed" })
```

---

### Коллекция `products`

**Назначение:** каталог, остатки по геозонам, фильтры по цене и категории.

**Полная схема документа (пример):**

```javascript
{
  _id: ObjectId("..."),
  sku: "PHONE-X-128",
  name: "Смартфон X",
  category: "electronics",
  category_path: ["electronics", "phones"],
  price: NumberDecimal("49990.00"),
  currency: "RUB",
  stock_by_zone: {
    MSK: { qty: 50, reserved: 2 },
    SPB: { qty: 30, reserved: 0 }
  },
  attributes: { color: "black", storage_gb: 128 },
  updated_at: ISODate("...")
}
```

**Индексы**

| Индекс | Назначение |
|--------|------------|
| `{ sku: 1 }` **unique** | Выдача карточки товара, списание остатков по SKU |
| `{ category: 1, price: 1 }` | Витрина: фильтр по категории и диапазону цен |
| `{ name: "text" }` (опционально) | Поиск по названию |
| `{ "stock_by_zone.MSK.qty": 1 }` | Региональные отчёты (по необходимости) |

```javascript
db.products.createIndex({ sku: 1 }, { unique: true })
db.products.createIndex({ category: 1, price: 1 })
```

**Шард-ключ:** не использовать один `category` (низкая кардинальность + «Электроника» = hot shard). Предпочтительно **`{ _id: "hashed" }`** или **`{ sku: "hashed" }`** для равномерности; запросы по категории остаются multi-shard, но покрываются индексом `{ category: 1, price: 1 }`.

```javascript
sh.shardCollection("shop.products", { sku: "hashed" })
```

---

### Коллекция `carts`

**Назначение:** гостевые и пользовательские корзины, TTL для «забытых» корзин.

**Полная схема документа (пример):**

```javascript
{
  _id: ObjectId("..."),
  user_id: ObjectId("..."),            // null для гостя
  session_id: "sess_abc",              // для гостя
  items: [{ product_id: ObjectId("..."), qty: 2, price_snapshot: NumberDecimal("100") }],
  status: "active",                    // active | ordered | abandoned
  created_at: ISODate("..."),
  updated_at: ISODate("..."),
  expires_at: ISODate("...")         // для TTL
}
```

**Индексы**

| Индекс | Назначение |
|--------|------------|
| `{ user_id: 1, status: 1 }` **unique partial** `status: "active"` | Одна активная корзина на пользователя (если бизнес-правило допускает) |
| `{ session_id: 1, status: 1 }` | Активная гостевая корзина |
| `{ expires_at: 1 }` **expireAfterSeconds: 0** | TTL — автоудаление просроченных документов |

```javascript
db.carts.createIndex(
  { user_id: 1, status: 1 },
  { unique: true, partialFilterExpression: { status: "active", user_id: { $exists: true } } }
)
db.carts.createIndex({ session_id: 1, status: 1 })
db.carts.createIndex({ expires_at: 1 }, { expireAfterSeconds: 0 })
```

**Шард-ключ:** `{ user_id: "hashed" }` или `{ session_id: "hashed" }` в зависимости от доминирующего ключа; для гостей без `user_id` важно не оставлять «пустой» shard key — часто вводят синтетическое поле `cart_tenant_id = user_id || session_id` и шардируют его.

```javascript
sh.shardCollection("shop.carts", { user_id: "hashed" })
```

---

## Задание 8. Горячий шард: как выявить и что делать (команды и сценарии)

### 1) Быстрая проверка баланса чанков по шардам

Подключение к **mongos**:

```javascript
sh.status()
// или детальнее по коллекции:
use config
db.chunks.aggregate([
  { $match: { ns: "shop.products" } },
  { $group: { _id: "$shard", n: { $sum: 1 } } },
  { $sort: { n: -1 } }
])
```

Если один shard id сильно больше других по **числу чанков** или **размеру данных** — кандидат в перегрузку (при равномерном shard key это сигнал либо дисбаланса балансировщика, либо «горячих» ключей внутри чанков).

### 2) Кто именно горячий: метрики на узле

На **primary** проблемного шарда (или через мониторинг Prometheus/Grafana с `mongodb_exporter`):

- `opcounters`, `connections`, `globalLock` (в старых версиях), **документ-ориентированные метрики**: latency команд, queue диска.
- Сравнить **операции в секунду** между `shard0000` и `shard0001` в одинаковые интервалы.

### 3) Понять, «узкий» ли shard key (категория «Электроника»)

```javascript
use shop
db.products.getShardDistribution()
// или агрегация по категории (дорого на больших данных — лучше off-line в DWH)
db.products.aggregate([
  { $match: { category: "electronics" } },
  { $count: "n" }
])
```

Если большая доля документов попадает в малый диапазон chunk’ов — проблема в **данных/ключе**, а не только в балансировщике.

### 4) Что делать по шагам

**A. Включить/проверить балансировщик и дождаться миграций**

```javascript
sh.getBalancerState()
sh.enableBalancing("shop.products")
// смотреть лог миграций / метрики до стабилизации
```

**B. Принудительно перенести чанк** (такое лучше делать при низкой нагрузке):

```javascript
// узнать границы чанка в config.chunks, затем (пример старого API — актуальность проверить по версии MongoDB):
// sh.moveChunk("shop.products", { category: "electronics", ... }, "shard0001")
```

**C. Сменить shard key** (MongoDB 4.2+ `refineCollectionShardKey` / смена ключа — ограничения; часто дешевле новая коллекция):

1. Создать `products_v2` с новым ключом и индексами.
2. Заполнить бэкфиллом (пакетами) из `products`.
3. Переключить чтение/запись в приложении.
4. Удалить старую коллекцию после стабилизации.

**D. Изоляция горячей категории в приложении**

- Отдельная коллекция `products_hot` с собственным шардированием или даже отдельный кластер.
- Агрессивный кеш (Redis) для чтения горячих SKU.

**E. Зоновое шардирование** (если географию нужно привязать к шардам):

```javascript
sh.addShardTag("shard0000", "EU")
sh.addTagRange("shop.orders", { geo_zone: "EU" }, { geo_zone: "EU" }, "EU")
```

(Синтаксис tag range зависит от типа ключа; используется когда осознанно крепят диапазоны к шардам.)

---

## Задание 9. Чтение с primary и secondary

Допустимая задержка репликации (**replication lag**) зависит от SLA: для остатков товара — секунды недопустимы при риске оверселлинга; для рекомендаций — допустимы единицы секунд.

| Операция / коллекция | Primary / Secondary | Допустимый lag | Обоснование |
|---------------------|---------------------|----------------|-------------|
| Создание заказа + списание остатков (`products`, `orders` write) | **primary** | — | линейная запись и согласованность транзакции |
| Чтение остатка перед оплатой (`products`) | **primary** или **secondary** с `readConcern: majority` | **&lt; 100–300 ms** | риск продать отсутствующий товар при stale read |
| Каталог / фильтр по категории (`products`, read-heavy) | **secondary** с `secondaryPreferred` | **1–5 s** | допустимо устаревание для витрины при дисклеймере |
| История заказов пользователя (`orders`) | **secondary** | **до нескольких секунд** | реже критично, чем оплата |
| Активная корзина (`carts`) | **primary** для merge/update | — | гонки при логине/слиянии гостевой корзины |
| Просмотр корзины после недавнего обновления | **primary** или causal | **минимальный** | согласованность с только что добавленными позициями |

---

## Задание 10. Cassandra

### 10.1 Критичные данные

| Данные | Cassandra уместна | Комментарий |
|--------|-------------------|-------------|
| Поток заказов, события статусов | Да | высокая запись, масштабирование линейно с узлами |
| Каталог и остатки (strong consistency) | Обычно **не как единственный SoT** | LWT дорогие и ограниченные; Mongo/SQL + кеш часто проще |
| Корзины / сессии | Частично | TTL-friendly; сложные обновления — Mongo/Redis |
| История для аналитики | Да | широкие строки, партиции по времени/сущности |

---

### 10.2 Концептуальная модель, partition key и clustering keys

Ниже — **несколько таблиц** с явным разделением access-паттернов. `PRIMARY KEY ((partition_key), clustering_cols...)` — данные одной партиции лежат на одном наборе узлов; равномерность обеспечивается **высокой кардинальностью** partition key (хеш user_id, order_id и т.д.).

#### Таблица A — история заказов клиента (чтение по `customer_id`)

**Паттерн:** все заказы пользователя — один partition; сортировка по времени внутри партиции.

```sql
CREATE TABLE shop.orders_by_customer (
  customer_id uuid,
  order_time timestamp,
  order_id uuid,
  status text,
  total decimal,
  currency text,
  PRIMARY KEY ((customer_id), order_time, order_id)
) WITH CLUSTERING ORDER BY (order_time DESC);
```

- **Partition key:** `customer_id` — один клиент = одна партиция (риск hot partition для «гигантского» B2B — смягчать лимитами и шардированием на уровне приложения).
- **Clustering keys:** `order_time`, `order_id` — уникальность и порядок без дополнительного индекса.

#### Таблица B — события заказа (высокая запись, чтение по заказу)

**Паттерн:** append-only статусы; запросы «все события заказа X».

```sql
CREATE TABLE shop.order_events (
  order_id uuid,
  event_time timestamp,
  event_type text,
  payload text,
  PRIMARY KEY ((order_id), event_time, event_type)
) WITH CLUSTERING ORDER BY (event_time ASC);
```

- **Partition key:** `order_id` — равномерно по заказам при высокой кардинальности.
- Hot partition, если один заказ генерирует миллионы событий — тогда **дополнительное поле** в partition key (например, `bucket = hash(order_id) % 16`) и денормализация.

#### Таблица C — снимки остатков по складу (аналитика / витрина в Cassandra)

Если остатки дублируются в Cassandra для чтения:

```sql
CREATE TABLE shop.inventory_by_sku_zone (
  sku text,
  zone text,
  qty int,
  version bigint,
  updated_at timestamp,
  PRIMARY KEY ((sku, zone))
);
```

- Одна строка на `(sku, zone)` — быстрый point read; запись узкая (LWT при необходимости согласованности с внешним источником).

#### «Горячие» партиции и топология

- Мониторить **размер партиции** и **запросы/сек на партицию** (nodetool tablestats, Prometheus).
- При смене топологии Cassandra **не делает полного reshuffle как range-shard в Mongo** в том же виде; добавление узла — постепенный **stream** данных. Модель должна минимизировать партиции > десятков GB.

---

### 10.3 Hinted Handoff, Read Repair, Anti-Entropy repair — выбор по сущностям

| Механизм | Суть | Компромисс |
|----------|------|------------|
| **Hinted Handoff** | при недоступной реплике координатор сохраняет «подсказку» и доставляет позже | доступность записи vs временная несогласованность до доставки |
| **Read Repair** | при чтении с уровнем ниже ALL обнаруживаются расхождения и исправляются | latency vs свежесть данных на репликах |
| **Anti-entropy (nodetool repair)** | фоновое сравнение Merkle trees между узлами | нагрузка на диск/сеть; планировать по окнам |

**Рекомендуемое сопоставление сущностей (пример):**

| Сущность | Hinted Handoff | Read Repair | Repair / AE |
|----------|------------------|---------------|----------------|
| **События заказа (`order_events`)** | Да — важна доступность append | Да при чтении с `LOCAL_QUORUM` / `ONE` для фоновой согласованности | Периодический **repair** по keyspace для редко читаемых партиций |
| **История по клиенту (`orders_by_customer`)** | Да | Да — при чтении истории витриной | Еженедельный **repair** + контроль `repair` после вывода узла из обслуживания |
| **Снимки остатков (`inventory_by_sku_zone`)** | Да, но критичные списания лучше подтверждать **LWT** или источником в Mongo | Обязателен при `ONE` на чтении | Частый repair при сильной важности цифр |

**Уровни согласованности (ориентир):**

- Финансово значимые операции: **`LOCAL_QUORUM`** на запись и чтение в одном DC; repair по регламенту.
- Высокий read RPS, допустимое устаревание: чтение **`ONE`** / **`LOCAL_ONE`** + опора на **read repair** и **repair** по расписанию.

```sql
-- пример записи с кворумом (концептуально из приложения)
-- consistency LOCAL_QUORUM
INSERT INTO shop.order_events (order_id, event_time, event_type, payload)
VALUES (...);
```

---

