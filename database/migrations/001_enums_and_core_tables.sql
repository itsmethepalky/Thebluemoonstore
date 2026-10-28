-- Enum types -----------------------------------------------------------
create type public.user_role as enum ('admin', 'staff', 'customer');
create type public.payment_method as enum ('cash', 'card', 'mobile', 'credit');
create type public.payment_status as enum ('paid', 'partial', 'unpaid');
create type public.sale_status as enum ('completed', 'returned', 'partially_returned');

-- Profiles (1:1 with auth.users) ----------------------------------------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  email text,
  role public.user_role not null default 'customer',
  phone text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Catalog ----------------------------------------------------------------
create table public.categories (
  id bigint generated always as identity primary key,
  name text not null unique,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.brands (
  id bigint generated always as identity primary key,
  name text not null unique,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.products (
  id bigint generated always as identity primary key,
  sku text not null unique,
  name text not null,
  description text,
  category_id bigint references public.categories(id),
  brand_id bigint references public.brands(id),
  unit_price numeric(12,2) not null default 0,
  cost_price numeric(12,2) not null default 0,
  stock_quantity integer not null default 0,
  reorder_level integer not null default 5,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index products_name_idx on public.products using gin (to_tsvector('simple', name));
create index products_category_idx on public.products (category_id);
create index products_brand_idx on public.products (brand_id);

-- Suppliers & purchases ---------------------------------------------------
create table public.suppliers (
  id bigint generated always as identity primary key,
  name text not null,
  contact_person text,
  phone text,
  email text,
  address text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.purchases (
  id bigint generated always as identity primary key,
  reference_no text not null unique,
  supplier_id bigint not null references public.suppliers(id),
  recorded_by uuid references public.profiles(id),
  notes text,
  total_amount numeric(12,2) not null default 0,
  purchase_date timestamptz not null default now()
);
create index purchases_supplier_idx on public.purchases (supplier_id);

create table public.purchase_items (
  id bigint generated always as identity primary key,
  purchase_id bigint not null references public.purchases(id) on delete cascade,
  product_id bigint not null references public.products(id),
  quantity integer not null check (quantity > 0),
  unit_cost numeric(12,2) not null default 0,
  subtotal numeric(12,2) not null default 0
);
create index purchase_items_purchase_idx on public.purchase_items (purchase_id);
create index purchase_items_product_idx on public.purchase_items (product_id);

-- Customers ----------------------------------------------------------------
create table public.customers (
  id bigint generated always as identity primary key,
  user_id uuid unique references public.profiles(id) on delete set null,
  name text not null,
  phone text,
  email text,
  address text,
  credit_limit numeric(12,2) not null default 0,
  credit_balance numeric(12,2) not null default 0,
  created_at timestamptz not null default now()
);
create index customers_name_idx on public.customers using gin (to_tsvector('simple', name));

-- Sales / POS ----------------------------------------------------------------
create table public.sales (
  id bigint generated always as identity primary key,
  invoice_no text not null unique,
  customer_id bigint references public.customers(id),
  cashier_id uuid references public.profiles(id),
  subtotal numeric(12,2) not null default 0,
  discount numeric(12,2) not null default 0,
  tax numeric(12,2) not null default 0,
  total_amount numeric(12,2) not null default 0,
  payment_method public.payment_method not null default 'cash',
  amount_paid numeric(12,2) not null default 0,
  payment_status public.payment_status not null default 'unpaid',
  status public.sale_status not null default 'completed',
  sale_date timestamptz not null default now()
);
create index sales_customer_idx on public.sales (customer_id);
create index sales_date_idx on public.sales (sale_date);

create table public.sale_items (
  id bigint generated always as identity primary key,
  sale_id bigint not null references public.sales(id) on delete cascade,
  product_id bigint references public.products(id),
  quantity integer not null check (quantity > 0),
  unit_price numeric(12,2) not null default 0,
  discount numeric(12,2) not null default 0,
  subtotal numeric(12,2) not null default 0,
  returned_quantity integer not null default 0
);
create index sale_items_sale_idx on public.sale_items (sale_id);
create index sale_items_product_idx on public.sale_items (product_id);

-- Returns ----------------------------------------------------------------
create table public.returns (
  id bigint generated always as identity primary key,
  sale_id bigint references public.sales(id),
  sale_item_id bigint not null references public.sale_items(id),
  quantity integer not null check (quantity > 0),
  reason text,
  processed_by uuid references public.profiles(id),
  refund_amount numeric(12,2) not null default 0,
  return_date timestamptz not null default now()
);
create index returns_sale_item_idx on public.returns (sale_item_id);
create index returns_sale_idx on public.returns (sale_id);
