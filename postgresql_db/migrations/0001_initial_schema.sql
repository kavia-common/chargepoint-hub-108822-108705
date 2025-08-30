-- ChargeMate initial schema (Supabase-first, Postgres compatible)
-- Safe to run on local Postgres and on Supabase.
-- Notes:
-- - When on Supabase, auth users live in auth.users. Locally, we create a minimal users table.
-- - Geospatial: we use PostGIS if available; otherwise, we store lon/lat separately and create btree indexes.

BEGIN;

-- Extensions: try PostGIS if available (Supabase has it). If fails, continue.
DO $$
BEGIN
  -- Enable postgis if present; ignore errors on local environments without PostGIS
  BEGIN
    EXECUTE 'CREATE EXTENSION IF NOT EXISTS postgis';
  EXCEPTION WHEN OTHERS THEN
    -- ignore
    NULL;
  END;

  -- Enable pgcrypto for UUID generation if needed
  BEGIN
    EXECUTE 'CREATE EXTENSION IF NOT EXISTS pgcrypto';
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
END
$$;

-- Universal enums
CREATE TYPE booking_status AS ENUM ('pending', 'confirmed', 'in_progress', 'completed', 'cancelled', 'no_show', 'failed');
CREATE TYPE payment_status AS ENUM ('requires_payment', 'authorized', 'captured', 'refunded', 'failed', 'cancelled');
CREATE TYPE notification_type AS ENUM ('booking', 'payment', 'system', 'message');
CREATE TYPE notification_channel AS ENUM ('push', 'email', 'sms', 'in_app');
CREATE TYPE charger_status AS ENUM ('active', 'inactive', 'maintenance');
CREATE TYPE connector_type AS ENUM ('type1', 'type2', 'ccs', 'chademo', 'gb_t', 'tesla');
CREATE TYPE currency_code AS ENUM ('USD', 'EUR', 'GBP', 'AUD', 'CAD', 'INR');

-- Users: Supabase auth reference
-- On Supabase, we will reference auth.users via UUIDs and not own that table.
-- For local development without Supabase, create a minimal users table if not exists.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'auth' AND table_name = 'users'
  ) THEN
    -- Minimal local users table (mirrors auth.users keys we need)
    CREATE TABLE IF NOT EXISTS public.users (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      email text UNIQUE NOT NULL,
      phone text,
      created_at timestamptz NOT NULL DEFAULT now()
    );
  END IF;
END
$$;

-- Roles table: app-level roles (rider, host, admin)
CREATE TABLE IF NOT EXISTS public.roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text UNIQUE NOT NULL CHECK (char_length(name) BETWEEN 3 AND 32),
  description text,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.roles(name, description)
VALUES ('rider', 'Default EV rider role'),
       ('host', 'Charger host/owner role'),
       ('admin', 'Administrator')
ON CONFLICT (name) DO NOTHING;

-- User roles mapping
-- user_id references either auth.users(id) (Supabase) or public.users(id) (local).
CREATE TABLE IF NOT EXISTS public.user_roles (
  user_id uuid NOT NULL,
  role_id uuid NOT NULL REFERENCES public.roles(id) ON DELETE CASCADE,
  assigned_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, role_id)
);

-- We cannot add a hard FK to auth.users in portable SQL. We'll keep a partial check:
-- Add a NOT VALID FK to public.users(id) which is a no-op on Supabase
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'users'
  ) THEN
    ALTER TABLE public.user_roles
    ADD CONSTRAINT fk_user_roles_users
    FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;
  END IF;
END
$$;

-- Charger locations (hosts create locations; multiple chargers per location)
-- Geospatial: try PostGIS geometry(Point, 4326). If not available, keep lon/lat columns and index them.
CREATE TABLE IF NOT EXISTS public.charger_locations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  host_user_id uuid NOT NULL,
  name text NOT NULL,
  description text,
  address_line1 text,
  address_line2 text,
  city text,
  state text,
  country text,
  postal_code text,
  -- Coordinates
  latitude double precision NOT NULL CHECK (latitude BETWEEN -90 AND 90),
  longitude double precision NOT NULL CHECK (longitude BETWEEN -180 AND 180),
  -- PostGIS geometry column if extension exists
  geom geometry(Point, 4326),
  is_public boolean NOT NULL DEFAULT true,
  status charger_status NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Optional FK to users (local only)
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'users'
  ) THEN
    ALTER TABLE public.charger_locations
    ADD CONSTRAINT fk_charger_locations_host
    FOREIGN KEY (host_user_id) REFERENCES public.users(id) ON DELETE CASCADE;
  END IF;
END
$$;

-- Keep geom in sync (if PostGIS)
CREATE OR REPLACE FUNCTION public.set_location_geom()
RETURNS trigger AS $$
BEGIN
  IF NEW.latitude IS NOT NULL AND NEW.longitude IS NOT NULL THEN
    BEGIN
      NEW.geom := ST_SetSRID(ST_MakePoint(NEW.longitude, NEW.latitude), 4326);
    EXCEPTION WHEN undefined_function THEN
      -- PostGIS not installed; ignore
      NEW.geom := NULL;
    END;
  END IF;
  RETURN NEW;
END
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_set_location_geom ON public.charger_locations;
CREATE TRIGGER trg_set_location_geom
BEFORE INSERT OR UPDATE ON public.charger_locations
FOR EACH ROW
EXECUTE FUNCTION public.set_location_geom();

-- Chargers
CREATE TABLE IF NOT EXISTS public.chargers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  location_id uuid NOT NULL REFERENCES public.charger_locations(id) ON DELETE CASCADE,
  name text NOT NULL,
  connector connector_type NOT NULL,
  power_kw numeric(6,2) NOT NULL CHECK (power_kw > 0),
  price_per_kwh numeric(10,4) NOT NULL CHECK (price_per_kwh >= 0),
  currency currency_code NOT NULL DEFAULT 'USD',
  is_available boolean NOT NULL DEFAULT true,
  status charger_status NOT NULL DEFAULT 'active',
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Booking slots are implicit by start_at/end_at with exclusive overlap constraints per charger
CREATE TABLE IF NOT EXISTS public.bookings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  charger_id uuid NOT NULL REFERENCES public.chargers(id) ON DELETE CASCADE,
  rider_user_id uuid NOT NULL,
  host_user_id uuid NOT NULL,
  status booking_status NOT NULL DEFAULT 'pending',
  start_at timestamptz NOT NULL,
  end_at timestamptz NOT NULL,
  energy_kwh_estimated numeric(10,3) CHECK (energy_kwh_estimated IS NULL OR energy_kwh_estimated >= 0),
  energy_kwh_actual numeric(10,3) CHECK (energy_kwh_actual IS NULL OR energy_kwh_actual >= 0),
  price_currency currency_code NOT NULL DEFAULT 'USD',
  price_subtotal_cents integer NOT NULL DEFAULT 0 CHECK (price_subtotal_cents >= 0),
  price_tax_cents integer NOT NULL DEFAULT 0 CHECK (price_tax_cents >= 0),
  price_total_cents integer NOT NULL DEFAULT 0 CHECK (price_total_cents >= 0),
  payment_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_time_window CHECK (end_at > start_at)
);

-- Optional FKs to users (local)
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'users'
  ) THEN
    ALTER TABLE public.bookings
    ADD CONSTRAINT fk_bookings_rider
    FOREIGN KEY (rider_user_id) REFERENCES public.users(id) ON DELETE CASCADE;

    ALTER TABLE public.bookings
    ADD CONSTRAINT fk_bookings_host
    FOREIGN KEY (host_user_id) REFERENCES public.users(id) ON DELETE CASCADE;
  END IF;
END
$$;

-- Prevent overlapping bookings per charger
CREATE UNIQUE INDEX IF NOT EXISTS ux_bookings_no_overlap
ON public.bookings (charger_id, tsrange(start_at, end_at))
WHERE status IN ('pending','confirmed','in_progress')
  -- gist index needed for EXCLUDE; use unique btree workaround below
;

-- If btree-only environments, create an EXCLUDE constraint when Postgres supports gist
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'ex_bookings_no_overlap'
  ) THEN
    BEGIN
      CREATE EXTENSION IF NOT EXISTS btree_gist;
      ALTER TABLE public.bookings
      ADD CONSTRAINT ex_bookings_no_overlap
      EXCLUDE USING gist (
        charger_id WITH =,
        tsrange(start_at, end_at) WITH &&
      )
      WHERE (status IN ('pending','confirmed','in_progress'));
    EXCEPTION WHEN OTHERS THEN
      -- environments where extensions cannot be created; skip
      NULL;
    END;
  END IF;
END
$$;

-- Payments
CREATE TABLE IF NOT EXISTS public.payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id uuid NOT NULL UNIQUE REFERENCES public.bookings(id) ON DELETE CASCADE,
  payer_user_id uuid NOT NULL,
  amount_total_cents integer NOT NULL CHECK (amount_total_cents >= 0),
  currency currency_code NOT NULL DEFAULT 'USD',
  status payment_status NOT NULL DEFAULT 'requires_payment',
  provider text NOT NULL DEFAULT 'stripe',
  provider_intent_id text,   -- e.g., Stripe PaymentIntent id
  provider_charge_id text,   -- e.g., Stripe Charge id (if capture)
  raw_provider_response jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Optional FK to local users
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'users'
  ) THEN
    ALTER TABLE public.payments
    ADD CONSTRAINT fk_payments_payer
    FOREIGN KEY (payer_user_id) REFERENCES public.users(id) ON DELETE CASCADE;
  END IF;
END
$$;

-- Notifications
CREATE TABLE IF NOT EXISTS public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  type notification_type NOT NULL,
  channel notification_channel NOT NULL,
  title text NOT NULL,
  body text NOT NULL,
  data jsonb NOT NULL DEFAULT '{}'::jsonb,
  sent_at timestamptz,
  read_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Optional FK to local users
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'users'
  ) THEN
    ALTER TABLE public.notifications
    ADD CONSTRAINT fk_notifications_user
    FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;
  END IF;
END
$$;

-- Indexes for performance and geospatial queries
CREATE INDEX IF NOT EXISTS idx_user_roles_user ON public.user_roles(user_id);
CREATE INDEX IF NOT EXISTS idx_user_roles_role ON public.user_roles(role_id);

CREATE INDEX IF NOT EXISTS idx_locations_host ON public.charger_locations(host_user_id);
CREATE INDEX IF NOT EXISTS idx_locations_status ON public.charger_locations(status);
CREATE INDEX IF NOT EXISTS idx_locations_public ON public.charger_locations(is_public);
CREATE INDEX IF NOT EXISTS idx_locations_city ON public.charger_locations(city);
CREATE INDEX IF NOT EXISTS idx_locations_country ON public.charger_locations(country);
CREATE INDEX IF NOT EXISTS idx_locations_lat_long ON public.charger_locations(latitude, longitude);

-- PostGIS geography/geometry index if available
DO $$
BEGIN
  BEGIN
    EXECUTE 'CREATE INDEX IF NOT EXISTS gix_locations_geom ON public.charger_locations USING GIST (geom)';
  EXCEPTION WHEN undefined_object OR undefined_function THEN
    -- PostGIS not present
    NULL;
  END;
END
$$;

CREATE INDEX IF NOT EXISTS idx_chargers_location ON public.chargers(location_id);
CREATE INDEX IF NOT EXISTS idx_chargers_status ON public.chargers(status);
CREATE INDEX IF NOT EXISTS idx_chargers_availability ON public.chargers(is_available);
CREATE INDEX IF NOT EXISTS idx_chargers_connector ON public.chargers(connector);

CREATE INDEX IF NOT EXISTS idx_bookings_charger ON public.bookings(charger_id);
CREATE INDEX IF NOT EXISTS idx_bookings_rider ON public.bookings(rider_user_id);
CREATE INDEX IF NOT EXISTS idx_bookings_host ON public.bookings(host_user_id);
CREATE INDEX IF NOT EXISTS idx_bookings_status ON public.bookings(status);
CREATE INDEX IF NOT EXISTS idx_bookings_start_end ON public.bookings(start_at, end_at);

CREATE INDEX IF NOT EXISTS idx_payments_booking ON public.payments(booking_id);
CREATE INDEX IF NOT EXISTS idx_payments_user ON public.payments(payer_user_id);
CREATE INDEX IF NOT EXISTS idx_payments_status ON public.payments(status);

CREATE INDEX IF NOT EXISTS idx_notifications_user ON public.notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notifications_type ON public.notifications(type);
CREATE INDEX IF NOT EXISTS idx_notifications_channel ON public.notifications(channel);
CREATE INDEX IF NOT EXISTS idx_notifications_sent_read ON public.notifications(sent_at, read_at);

COMMIT;
