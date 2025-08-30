#!/usr/bin/env bash
set -euo pipefail

# Runs all SQL migration files against local Postgres using env from db_visualizer/postgres.env
# Usage: ./scripts/migrate_local.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/db_visualizer/postgres.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE. Run startup.sh first to generate it."
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

if [ -z "${POSTGRES_URL:-}" ]; then
  echo "POSTGRES_URL not set in $ENV_FILE"
  exit 1
fi

echo "Applying migrations to ${POSTGRES_URL} ..."
MIGRATIONS_DIR="$ROOT_DIR/migrations"

shopt -s nullglob
for file in "$MIGRATIONS_DIR"/*.sql; do
  echo "-> Running $(basename "$file")"
  psql "$POSTGRES_URL" -v ON_ERROR_STOP=1 -f "$file"
done

echo "Migrations completed successfully."
