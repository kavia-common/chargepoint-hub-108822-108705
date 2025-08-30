ChargeMate Database Schema (Supabase-first)

Overview
- This schema is designed to work with Supabase Postgres and also run locally with vanilla PostgreSQL.
- Users: On Supabase, use auth.users (UUID) as the canonical user table. Locally, a minimal public.users is created for development/testing.
- Core entities:
  - roles, user_roles
  - charger_locations (geospatial)
  - chargers
  - bookings
  - payments
  - notifications

Geospatial
- If PostGIS is available (Supabase includes it), charger_locations.geom is maintained and a GIST index is created.
- If PostGIS is not available, geom remains NULL and we rely on latitude/longitude columns with btree indexes.

Tables
- roles: app roles (rider, host, admin)
- user_roles: many-to-many user to role mapping. user_id references auth.users on Supabase (not enforced by FK here), or public.users locally (FK added conditionally).
- charger_locations: the host-owned site. Includes address fields and coordinates.
- chargers: specific charging points at a location; includes connector type, power, and pricing.
- bookings: rider reserves a charger for a time window; overlap prevented per charger.
- payments: one per booking, tracks provider state (Stripe assumed).
- notifications: app-generated messages delivered by push, email, sms, or in-app.

Migrations
- Use scripts/migrate_local.sh to apply SQL migrations to local Postgres (after running startup.sh).
- Use scripts/migrate_supabase.sh with supabase CLI (supabase login; supabase db query ...).
- Migration files are ordered and idempotent.

Supabase Auth and Users
- Supabase provides auth.users (id UUID, email, etc.). In the backend, prefer joining on auth.users for display and emails.
- In this repo, foreign keys to auth.users are not declared to keep compatibility with local environments. The backend should enforce referential integrity when inserting.

RLS Plan (Supabase)
Note: RLS is not enabled by default here; you should enable and tailor policies in Supabase Dashboard or via SQL.

Recommended policies (sketch):
1) roles, user_roles:
   - roles: read for authenticated users; write restricted to admin.
   - user_roles: 
     - users can read their own roles (user_id = auth.uid()).
     - admin can assign roles.

   Example:
   ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;
   CREATE POLICY roles_read ON public.roles FOR SELECT TO authenticated USING (true);

   ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
   CREATE POLICY user_roles_self_read ON public.user_roles
     FOR SELECT TO authenticated USING (user_id = auth.uid());

   -- Admin policies require a helper function or claim indicating admin. e.g., has_role('admin').
   -- You can model this by a security definer function that checks exists(
   --   select 1 from public.user_roles ur
   --   join public.roles r on r.id = ur.role_id
   --   where ur.user_id = auth.uid() and r.name = 'admin'
   -- ).

2) charger_locations:
   - Read: public locations are readable by anyone (or authenticated). Private (is_public=false) should be readable by host and admin.
   - Write: only host_user_id (resource owner) or admin can insert/update/delete.

   ALTER TABLE public.charger_locations ENABLE ROW LEVEL SECURITY;
   CREATE POLICY locations_read_public ON public.charger_locations
     FOR SELECT USING (is_public = true);
   CREATE POLICY locations_read_owner_private ON public.charger_locations
     FOR SELECT TO authenticated USING (host_user_id = auth.uid());
   CREATE POLICY locations_owner_write ON public.charger_locations
     FOR ALL TO authenticated USING (host_user_id = auth.uid()) WITH CHECK (host_user_id = auth.uid());

3) chargers:
   - Read: same as parent location (public), or host/admin.
   - Write: only location owner or admin.

   ALTER TABLE public.chargers ENABLE ROW LEVEL SECURITY;
   CREATE POLICY chargers_read_public ON public.chargers
     FOR SELECT USING (EXISTS (
       SELECT 1 FROM public.charger_locations l WHERE l.id = chargers.location_id AND l.is_public
     ));
   CREATE POLICY chargers_owner_write ON public.chargers
     FOR ALL TO authenticated USING (EXISTS (
       SELECT 1 FROM public.charger_locations l WHERE l.id = chargers.location_id AND l.host_user_id = auth.uid()
     ))
     WITH CHECK (EXISTS (
       SELECT 1 FROM public.charger_locations l WHERE l.id = chargers.location_id AND l.host_user_id = auth.uid()
     ));

4) bookings:
   - Read: rider/host involved can read; admin can read.
   - Write:
     - Insert: rider creates booking, host_user_id must match location host via charger -> location.
     - Update status: rider can cancel their own; host can confirm/complete for their chargers.

   ALTER TABLE public.bookings ENABLE ROW LEVEL SECURITY;
   CREATE POLICY bookings_self_read ON public.bookings
     FOR SELECT TO authenticated USING (
       rider_user_id = auth.uid() OR host_user_id = auth.uid()
     );
   CREATE POLICY bookings_rider_insert ON public.bookings
     FOR INSERT TO authenticated WITH CHECK (
       rider_user_id = auth.uid()
       AND EXISTS (
         SELECT 1 FROM public.chargers c
         JOIN public.charger_locations l ON l.id = c.location_id
         WHERE c.id = bookings.charger_id AND bookings.host_user_id = l.host_user_id
       )
     );
   -- Additional policies can split UPDATE by status transitions and ownership.

5) payments:
   - Read: payer and related host can read; admin can read.
   - Write: only server-side service role should modify (Stripe webhooks). Use service role key in backend or a separate role.

   ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
   CREATE POLICY payments_payer_read ON public.payments
     FOR SELECT TO authenticated USING (payer_user_id = auth.uid());
   -- No public write policies; backend uses service role.

6) notifications:
   - Read: only user_id owner can read; write: only service role inserts.

   ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
   CREATE POLICY notifications_self_read ON public.notifications
     FOR SELECT TO authenticated USING (user_id = auth.uid());

Helpers
- Implement has_role(text) function in Supabase to check roles via user_roles; then use it in policies to gate admin privileges.

Local Development
- RLS is not enforced locally unless you explicitly enable it. The backend should emulate access control at the application layer during local development.

Indexes
- btree indexes on common filters and time ranges.
- PostGIS GIST index on geom when available.

Data Integrity
- bookings enforce non-overlapping reservations per charger using EXCLUDE with btree_gist if available; falls back gracefully in constrained environments.

Next Steps
- Backend should enforce user_id integrity against auth.users (Supabase) or public.users (local) at insertion time.
- Add seed data scripts for local testing if desired.
