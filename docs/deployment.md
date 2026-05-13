# Deployment

This document describes practical scenarios for running RoSeMAN. The architectural context (what modules and modes mean) is in [architecture.md](./architecture.md).

## Environment files

The repository root contains three `.example` files from which you should create real `.env` files:

| File                | Role                                                                              |
|---------------------|-----------------------------------------------------------------------------------|
| `.env`              | Base: `MONGODB_URI`, `PORT`, module flags, Robonomics agents, Nominatim           |
| `.env.polkadot`     | **Polkadot** indexer: `ROBONOMICS_WS`, `ROBONOMICS_STATE_KEY=polkadot_robonomics`, `ROBONOMICS_START_BLOCK`, `API_ENABLED=false`, the desired `ENABLED_HANDLERS` set |
| `.env.kusama`       | **Kusama** indexer: same as above, but with the Kusama endpoint and start block   |

The loading cascade (`src/env-bootstrap.ts`):

1. The shared `.env` is read (the base).
2. If `DOTENV_CONFIG_PATH` is set — the specified file is read with `override: true`, overwriting any matching variables.

The full list of variables and defaults is in [indexer.md → Configuration](./indexer.md#configuration).

## Local development

```bash
npm install

# All-in-one (API + indexer + IPFS + geocoder) from .env
npm run start:dev

# Headless: Polkadot indexer only (loads .env.polkadot on top of .env)
npm run start:dev:polkadot

# Headless: Kusama indexer only
npm run start:dev:kusama
```

`start:dev*` uses `nest start --watch` — changes in `src/` restart the process. To connect to a local MongoDB, set `MONGODB_URI=mongodb://localhost:27017/roseman` in `.env` or run MongoDB in Docker (see below).

## Production

### Direct Node run

```bash
npm run build

npm run start:prod         # API from .env
npm run start:polkadot     # Polkadot indexer (.env.polkadot)
npm run start:kusama       # Kusama indexer  (.env.kusama)
```

`start:polkadot` and `start:kusama` propagate `DOTENV_CONFIG_PATH` via `dotenv` and start `dist/main`. See `package.json`.

## Docker

The repository root contains `Dockerfile` and `docker-compose.yml`.

### Image

The `Dockerfile` is minimal: it installs **production** dependencies only and copies a **prebuilt `dist/`**. That is, the TypeScript build happens **before** the image build:

```bash
npm run build
docker build -t vol4/roseman:v0.1.0 .
```

This is a deliberate choice — the image does not carry `devDependencies` or the TypeScript toolchain. Key points:

- `NODE_ENV=production` is set, and `npm ci --omit=dev` skips dev dependencies.
- The container runs as the non-root `node` user.
- `EXPOSE 3000` documents the default port; override at runtime with the `APP_PORT` compose variable.

### Docker Compose

`docker-compose.yml` brings up five services:

| Service             | Image                  | Purpose                                                            |
|---------------------|------------------------|--------------------------------------------------------------------|
| `mongodb`           | `mongo:8`              | DB, healthcheck via `db.adminCommand('ping')`, named volume       |
| `mongo-restore`    | `mongo:8`              | One-off: restores a dump from `./dump/` if present, then exits   |
| `rest-api`          | `vol4/roseman:v0.1.0`  | REST API (reads `.env`)                                            |
| `indexer-polkadot`  | `vol4/roseman:v0.1.0`  | Polkadot indexer (`DOTENV_CONFIG_PATH=/app/.env.polkadot`)         |
| `indexer-kusama`    | `vol4/roseman:v0.1.0`  | Kusama indexer (`DOTENV_CONFIG_PATH=/app/.env.kusama`)             |

Configuration is supplied to the containers via **bind-mounts** of the corresponding `.env` files in read-only mode.

#### Startup order

The services start in a strict order enforced by `depends_on` conditions:

```
mongodb (service_healthy)
  └─▶ mongo-restore (service_completed_successfully)
        ├─▶ rest-api
        ├─▶ indexer-polkadot
        └─▶ indexer-kusama
```

1. **`mongodb`** starts first. The healthcheck (`mongosh —eval "db.adminCommand('ping')"`) must pass before anything else proceeds.
2. **`mongo-restore`** starts once MongoDB is healthy. If `./dump/` contains `.bson` files, `mongorestore` is executed; otherwise the container exits immediately with code 0.
3. **Application containers** start only after `mongo-restore` has completed successfully. This guarantees they never connect to a partially-restored database.

#### MongoDB connection string

Because the compose stack enables authentication (`MONGO_INITDB_ROOT_USERNAME` / `MONGO_ROOT_PASSWORD`), the `MONGODB_URI` in your `.env` must include credentials and the `authSource` parameter:

```dotenv
# .env
MONGODB_URI=mongodb://admin:secret@mongodb:27017/roseman?authSource=admin
```

Replace `admin` / `secret` with the values of `MONGO_ROOT_USER` / `MONGO_ROOT_PASSWORD` if you changed the defaults.

#### Quick start

```bash
cp .env.example .env
cp .env.polkadot.example .env.polkadot
cp .env.kusama.example .env.kusama
# Edit .env — set MONGODB_URI as shown above

docker compose up -d
docker compose logs -f indexer-polkadot
```

After startup:
- REST API: `http://localhost:${APP_PORT:-3000}/api`
- Metrics: `http://localhost:${APP_PORT:-3000}/metrics`
- MongoDB: `localhost:${MONGO_PORT:-27017}` (`admin` / `secret` by default — change via `MONGO_ROOT_USER` / `MONGO_ROOT_PASSWORD`)

### Restoring a MongoDB dump

The `mongo-restore` service automatically restores data on every `docker compose up` if the `./dump/` directory contains `.bson` files from `mongodump`.

#### Automatic restore (recommended)

1. Create a dump from the source database:

   ```bash
   mongodump --uri="mongodb://..." --out ./dump
   # or, from a running compose stack:
   docker compose exec mongodb mongodump \
       --username=admin --password=secret --authenticationDatabase=admin \
       --out /tmp/dump
   docker compose cp mongodb:/tmp/dump ./dump
   ```

2. Start the stack:

   ```bash
   docker compose up -d
   ```

   `mongo-restore` detects the dump, runs `mongorestore`, and exits. The three application containers wait for it to finish before starting.

3. After the first successful restore, clean up to prevent re-restoring on subsequent starts:

   ```bash
   rm -rf ./dump/roseman
   # or remove the entire directory:
   rm -rf ./dump
   mkdir dump  # keep the empty directory for bind-mount
   ```

> **Note:** `mongorestore` without `--drop` merges data into existing collections. Duplicate documents (by `_id` or unique index) are silently skipped. This makes repeated restores safe — they won't destroy new data added by running indexers.

#### Manual restore

To re-import a dump into a running stack without restarting all services:

```bash
# Place the dump in ./dump/, then:
docker compose run --rm mongo-restore
```

This executes the same `scripts/restore.sh` but as a one-off command against the already-running MongoDB. Application containers are **not** restarted.

#### Dropping collections before restore

By default the restore script does **not** use `--drop`, so existing data is preserved. To drop each collection before restoring (destructive — use with caution), edit `scripts/restore.sh` and add `--drop` to the `mongorestore` command.

### Volumes

| Volume         | Type         | Mount point      | Purpose                               |
|----------------|--------------|------------------|---------------------------------------|
| `mongodb-data` | named volume | `/data/db`       | MongoDB data (survives `docker compose down`) |
| `./dump`       | bind mount   | `/dump` (ro)     | Mongodump input for `mongo-restore`  |
| `./.env*`      | bind mount   | `/app/.env*` (ro)| Application configuration            |

To inspect the named volume:

```bash
docker volume inspect roseman_mongodb-data
```

To back up the volume:

```bash
docker compose exec mongodb mongodump \
    --username=admin --password=secret --authenticationDatabase=admin \
    --out /tmp/backup
docker compose cp mongodb:/tmp/backup ./backup
```

### Environment variables (Docker Compose)

| Variable              | Default  | Used by                                                   |
|-----------------------|----------|-----------------------------------------------------------|
| `MONGO_ROOT_USER`     | `admin`  | MongoDB root user, `mongo-restore`                        |
| `MONGO_ROOT_PASSWORD` | `secret` | MongoDB root password, `mongo-restore`                    |
| `MONGO_PORT`          | `27017`  | Host port for MongoDB                                     |
| `APP_PORT`            | `3000`   | Host port for REST API                                    |

> **Security:** change `MONGO_ROOT_USER` and `MONGO_ROOT_PASSWORD` before deploying to production. Put these in a `.env` file in the project root (Docker Compose auto-loads it).

## Multi-instance deployment

A typical production setup is to **split the roles across processes** so that each role can be scaled independently:

```
┌──────────────────────────┐    ┌────────────────────────────┐
│ REST API + Geocoding     │    │ Indexer Polkadot           │
│ + Measurement processor  │    │ (headless, datalog only)   │
│ API_ENABLED=true         │    │ API_ENABLED=false          │
│ MEASUREMENT_ENABLED=true │    │ INDEXER_ENABLED=true       │
│ GEOCODING_ENABLED=true   │    │ ENABLED_HANDLERS=          │
│ INDEXER_ENABLED=false    │    │   datalog-new-record       │
└────────────┬─────────────┘    └─────────────┬──────────────┘
             │                                │
             │       ┌────────────────────────┴───┐
             │       │ Indexer Kusama             │
             │       │ (headless, datalog only)   │
             │       │ API_ENABLED=false          │
             │       │ INDEXER_ENABLED=true       │
             │       │ ENABLED_HANDLERS=          │
             │       │   datalog-new-record       │
             │       └────────────┬───────────────┘
             │                    │
             ▼                    ▼
        ┌────────────────────────────────┐
        │           MongoDB              │
        │  index_state.{polkadot,kusama} │
        └────────────────────────────────┘
```

Key points:

- **Indexer state is separated by `ROBONOMICS_STATE_KEY`** in the `index_state` collection (`polkadot_robonomics`, `kusama_robonomics`, …). One MongoDB serves both indexers without conflicts.
- **`MEASUREMENT_ENABLED` only needs to be enabled on one instance** — `MeasurementProcessor` polls the `datalogs` collection and processes records produced by any indexer, regardless of which process wrote them. Running the processor on multiple instances simultaneously is safe (deduplication relies on unique indexes), but redundant.
- **`GEOCODING_ENABLED`** — same idea; it makes sense to keep it on a single instance because of Nominatim's rate limit.
- **The REST API can be horizontally scaled** — it is stateless and reads the DB through repositories. Behind a load balancer you can put N instances with `API_ENABLED=true` and all the other flags set to `false`.

See also [architecture.md → Run modes](./architecture.md#run-modes).

## Healthcheck and shutdown

- **MongoDB:** in `docker-compose.yml` — `healthcheck: db.adminCommand('ping')` with 10 s interval, 5 retries, 10 s start period.
- **mongo-restore:** exits with code 0 on success (including the no-dump case). Application containers depend on `service_completed_successfully`, so they never start until the restore finishes.
- **RoSeMAN:** `app.enableShutdownHooks()` is enabled in both modes (API/headless). On `SIGTERM`/`SIGINT` NestJS calls `OnModuleDestroy`, in particular `RobonomicsService.onModuleDestroy()`, which cleanly closes the WebSocket.
- There is currently no HTTP healthcheck endpoint (`/health`). For containerized infrastructure you can rely on `/api/status/last-block` or Prometheus metrics.

## Logging

Logs are written through `@nestjs/common` `Logger` to stdout. Levels:

- `Logger.log` — normal events (service startup, catch-up progress).
- `Logger.warn` — connection drops, IPFS gateway failures, Nominatim errors (best-effort).
- `Logger.error` — unhandled exceptions.
- `Logger.debug` — details of processing for individual events and blocks.

In `docker compose`, logs are available via `docker compose logs -f <service>`.

## Troubleshooting

### mongo-restore exits with an error

Check its logs:

```bash
docker compose logs mongo-restore
```

Common causes:
- Wrong `MONGO_ROOT_USER` / `MONGO_ROOT_PASSWORD` — make sure they match the `MONGO_INITDB_ROOT_USERNAME` / `MONGO_INITDB_ROOT_PASSWORD` values in the `mongodb` service.
- Corrupted dump — ensure `./dump/` contains valid `mongodump` output (`.bson` + `.json` metadata files).

### Application containers fail to start

If `mongo-restore` exited with a non-zero code, the application containers will stay in the `Waiting` state. Fix the restore issue first, then:

```bash
docker compose up -d
```

### Reset everything (⚠️ deletes all data)

```bash
docker compose down -v   # removes containers, networks AND named volumes
# or, to keep volumes:
docker compose down
```
