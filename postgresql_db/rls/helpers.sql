-- Helper functions for RLS (Supabase)
-- Note: Execute this on Supabase only (requires auth.uid()).

-- Check if current user has a named role
create or replace function public.has_role(role_name text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists(
    select 1
    from public.user_roles ur
    join public.roles r on r.id = ur.role_id
    where ur.user_id = auth.uid()
      and r.name = role_name
  );
$$;

-- Example admin check
create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
as $$
  select public.has_role('admin');
$$;
