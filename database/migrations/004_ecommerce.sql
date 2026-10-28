-- ============================================================
-- The Blue Moon - E-commerce Extension
-- Migration 004
-- ============================================================

-- ------------------------------------------------------------
-- E-commerce enum types
-- ------------------------------------------------------------

create type public.order_status as enum (
  'pending',
  'confirmed',
  'processing',
  'ready',
  'out_for_delivery',
  'delivered',
  'cancelled',
  'returned'
);

-- ------------------------------------------------------------
-- Product images
-- Actual files live in Supabase Storage.
-- This table stores their metadata.
-- ------------------------------------------------------------

create table public.product_images (
  id bigint generated always as identity primary key,
  product_id bigint not null
    references public.products(id) on delete cascade,
  storage_path text not null,
  image_url text not null,
  is_primary boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create index product_images_product_idx
  on public.product_images (product_id);

create index product_images_sort_idx
  on public.product_images (product_id, sort_order);

-- ------------------------------------------------------------
-- Online orders
-- Separate from POS sales.
-- ------------------------------------------------------------

create table public.orders (
  id bigint generated always as identity primary key,

  order_no text not null unique,

  customer_id bigint not null
    references public.customers(id),

  status public.order_status not null default 'pending',

  subtotal numeric(12,2) not null default 0,
  discount numeric(12,2) not null default 0,
  tax numeric(12,2) not null default 0,
  total_amount numeric(12,2) not null default 0,

  payment_method public.payment_method not null default 'cash',
  payment_status public.payment_status not null default 'unpaid',

  shipping_address text not null,
  phone text,

  notes text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index orders_customer_idx
  on public.orders (customer_id);

create index orders_status_idx
  on public.orders (status);

create index orders_created_at_idx
  on public.orders (created_at);

-- ------------------------------------------------------------
-- Online order items
-- ------------------------------------------------------------

create table public.order_items (
  id bigint generated always as identity primary key,

  order_id bigint not null
    references public.orders(id) on delete cascade,

  product_id bigint
    references public.products(id),

  quantity integer not null
    check (quantity > 0),

  unit_price numeric(12,2) not null default 0,

  discount numeric(12,2) not null default 0,

  subtotal numeric(12,2) not null default 0,

  created_at timestamptz not null default now()
);

create index order_items_order_idx
  on public.order_items (order_id);

create index order_items_product_idx
  on public.order_items (product_id);

-- ------------------------------------------------------------
-- RLS
-- ------------------------------------------------------------

alter table public.product_images enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;

-- ------------------------------------------------------------
-- Product images
--
-- Staff/admin can manage images.
-- Customers do not directly query this table.
-- Storefront images will be served through the backend.
-- ------------------------------------------------------------

create policy "product_images_staff_all"
on public.product_images
for all
using (private.is_staff())
with check (private.is_staff());

-- ------------------------------------------------------------
-- Orders
--
-- Staff/admin can manage all orders.
-- Customers can read their own orders.
-- Customers cannot directly create/update/delete orders.
-- Checkout will go through FastAPI.
-- ------------------------------------------------------------

create policy "orders_staff_all"
on public.orders
for all
using (private.is_staff())
with check (private.is_staff());

create policy "orders_select_own"
on public.orders
for select
using (
  exists (
    select 1
    from public.customers c
    where c.id = orders.customer_id
      and c.user_id = (select auth.uid())
  )
);

-- ------------------------------------------------------------
-- Order items
-- ------------------------------------------------------------

create policy "order_items_staff_all"
on public.order_items
for all
using (private.is_staff())
with check (private.is_staff());

create policy "order_items_select_own"
on public.order_items
for select
using (
  exists (
    select 1
    from public.orders o
    join public.customers c
      on c.id = o.customer_id
    where o.id = order_items.order_id
      and c.user_id = (select auth.uid())
  )
);

-- ------------------------------------------------------------
-- Updated-at helper
-- ------------------------------------------------------------

create or replace function private.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger orders_set_updated_at
before update on public.orders
for each row
execute function private.set_updated_at();
