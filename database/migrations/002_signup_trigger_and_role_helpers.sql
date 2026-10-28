-- Internal helper functions live in a `private` schema (not `public`) so
-- they are NOT exposed as callable PostgREST RPC endpoints - Postgres still
-- lets RLS policies call them, it just keeps them off the public API surface.
create schema if not exists private;

-- Automatically create a profile row (and, for customers, a linked
-- customers row) whenever a new user signs up through Supabase Auth.
-- Admin-created staff/admin accounts pass role via user_metadata
-- (see backend/app/routers/users.py).
create or replace function private.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role public.user_role;
begin
  v_role := coalesce((new.raw_user_meta_data->>'role')::public.user_role, 'customer');

  insert into public.profiles (id, full_name, role, phone, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
    v_role,
    new.raw_user_meta_data->>'phone',
    new.email
  );

  if v_role = 'customer' then
    insert into public.customers (user_id, name, phone, email, address)
    values (
      new.id,
      coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
      new.raw_user_meta_data->>'phone',
      new.email,
      new.raw_user_meta_data->>'address'
    );
  end if;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_auth_user();

-- Role helper functions, used by RLS policies -----------------------------
create or replace function private.current_role()
returns public.user_role
language sql stable security definer set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

create or replace function private.is_staff()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (
      select role in ('admin', 'staff') and is_active
      from public.profiles
      where id = auth.uid()
    ),
    false
  );
$$;

create or replace function private.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (
      select role = 'admin' and is_active
      from public.profiles
      where id = auth.uid()
    ),
    false
  );
$$;
