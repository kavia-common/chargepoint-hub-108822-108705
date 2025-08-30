ChargeMate PostgreSQL Configuration

This container provides local PostgreSQL for development. You can also connect the backend to Supabase Postgres instead.

Variables
- POSTGRES_URL: Connection URL for local Postgres and tooling.
- POSTGRES_USER: Local DB user.
- POSTGRES_PASSWORD: Local DB password.
- POSTGRES_DB: Local database name.
- POSTGRES_PORT: Port for local Postgres server.
- SUPABASE_DB_URL: Optional URL for Supabase-managed Postgres (used by backend_api if preferred).

Usage
- Run startup.sh to initialize and start local Postgres on the configured port.
- The script will also write db_visualizer/postgres.env for the Node.js viewer.
- Apply schema/migrations:
  - Local: ./scripts/migrate_local.sh
  - Supabase: ./scripts/migrate_supabase.sh (requires supabase CLI)
- Point backend_api to either:
  - SUPABASE_DB_URL (recommended if you use Supabase), or
  - POSTGRES_URL/POSTGRES_* (for pure local DB).

Notes
- The schema is Supabase-first: when running on Supabase, reference auth.users (UUID).
- Locally, a minimal public.users table is created to mimic auth.users so the app runs without Supabase.
- Geospatial: If PostGIS is available, geom column and GIST index are active; otherwise, code uses lat/long btree indexes.

Security
- Do not commit real credentials. Use this file as a template for your .env.
