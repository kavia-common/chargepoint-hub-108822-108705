ChargeMate Migrations and Supabase/RLS Guide

Local Development
1) Start local Postgres (one-time):
   ./startup.sh

2) Apply migrations locally:
   ./scripts/migrate_local.sh

3) Inspect database (optional):
   source db_visualizer/postgres.env
   psql "$POSTGRES_URL"

Supabase
1) Install supabase CLI (if not installed): https://supabase.com/docs/guides/cli
2) Login and link your project:
   supabase login
   supabase link --project-ref <your-project-ref>

3) Apply migrations:
   ./scripts/migrate_supabase.sh
   - This runs each SQL file in migrations/ via `supabase db query`.

RLS Policies (Supabase)
- The schema ships without RLS enabled by default. Enable and apply policies in your Supabase instance.
- Examples are included in SCHEMA.md under "RLS Plan (Supabase)".
- You can convert those examples to SQL and apply via:
   supabase db query path/to/your_rls_policies.sql

Auth Users
- On Supabase, use auth.users as the canonical user table (id UUID).
- Our FK references are conditional to ensure local portability. The backend should ensure only valid user UUIDs are used.

Adding Migrations
- Create a new SQL file in postgresql_db/migrations with an increasing numeric prefix, e.g.:
  0003_add_indexes.sql
- Write idempotent SQL (use IF EXISTS/IF NOT EXISTS and DO $$ ... $$ blocks to handle environments).
- Re-run the local or Supabase migration scripts.

Rollbacks
- Rollbacks are not automated. If needed, create a compensating migration (e.g., 0004_rollback_x.sql) that undoes prior changes.
