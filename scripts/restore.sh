#!/bin/sh
# =============================================================
# MongoDB restore script for Docker Compose
#
# Runs as a one-off init container (mongo-restore service).
# If the /dump directory contains .bson files (mongodump output),
# this script restores them into the running MongoDB instance.
# Otherwise it exits successfully so that the application
# containers can start without delay.
#
# Usage:
#   1. Place your mongodump output into  ./dump/  on the host,
#      e.g.:  mongodump --uri="mongodb://..." --out ./dump
#   2. docker compose up
#   3. This container detects the dump and runs mongorestore
#      before any app container is allowed to start.
#
# Environment variables (set in docker-compose.yml):
#   MONGO_ROOT_USER     — MongoDB root username
#   MONGO_ROOT_PASSWORD — MongoDB root password
# =============================================================
set -e

DUMP_DIR="/dump"

echo "=== Mongo restore init ==="

# Check whether the dump directory exists and contains .bson files
# (plain .gitkeep or empty dirs are safely ignored).
if [ -d "$DUMP_DIR" ] && \
   find "$DUMP_DIR" -name '*.bson' -print -quit 2>/dev/null | grep -q .; then

    echo "=== Restoring MongoDB from dump in $DUMP_DIR ==="

    mongorestore \
        --host=mongodb \
        --port=27017 \
        --username="${MONGO_ROOT_USER}" \
        --password="${MONGO_ROOT_PASSWORD}" \
        --authenticationDatabase=admin \
        "$DUMP_DIR"

    echo "=== MongoDB restore completed ==="
else
    echo "=== No .bson files found in $DUMP_DIR — skipping restore ==="
fi
