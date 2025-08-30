#!/usr/bin/env bash
set -euo pipefail

# Apply our SQL migrations to a Supabase project using the supabase CLI.
# Requirements:
#   - supabase CLI installed and authenticated (supabase login)
#   - SUPABASE_DB_URL in environment OR project linked (supabase link)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATIONS_DIR="$ROOT_DIR/migrations"

echo "Applying migrations to Supabase via supabase CLI..."
shopt -s nullglob
for file in "$MIGRATIONS_DIR"/*.sql; do
  echo "-> Running $(basename "$file")"
  supabase db query "$file"
done

echo "Supabase migrations completed."
