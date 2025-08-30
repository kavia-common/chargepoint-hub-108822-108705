ChargeMate Database (PostgreSQL/Supabase)

This folder contains the SQL schema, migrations, and scripts to run ChargeMate on local PostgreSQL and on Supabase.

Quick Start (Local)
1) Start local Postgres:
   ./startup.sh

2) Apply migrations:
   ./scripts/migrate_local.sh

3) Inspect:
   source db_visualizer/postgres.env
   psql "$POSTGRES_URL"

Supabase
1) Install and login to supabase CLI:
   supabase login
   supabase link --project-ref <your-project-ref>

2) Apply migrations:
   ./scripts/migrate_supabase.sh

Docs
- SCHEMA.md: Schema overview, geospatial, and RLS plan
- MIGRATIONS.md: How to run/extend migrations
- rls/helpers.sql: Optional helper functions for RLS on Supabase (run with supabase db query)

Notes
- Schema is Supabase-first. Locally, a minimal public.users is created for development. On Supabase, use auth.users.
- Geospatial works with or without PostGIS. If PostGIS is present, a GIST index is created over charger_locations.geom.
- Booking overlaps are prevented with EXCLUDE USING gist if btree_gist is available.
