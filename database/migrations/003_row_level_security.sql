alter table public.profiles enable row level security;
alter table public.categories enable row level security;
alter table public.brands enable row level security;
alter table public.products enable row level security;
alter table public.suppliers enable row level security;
alter table public.purchases enable row level security;
alter table public.purchase_items enable row level security;
alter table public.customers enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.returns enable row level security;

-- profiles: everyone can read their own row; staff/admin can read all;
-- only admin can change roles; users may update their own name/phone.
create policy "profiles_select_own_or_staff" on public.profiles
  for select using ((select auth.uid()) = id or private.is_staff());
create policy "profiles_update_own_limited" on public.profiles
  for update using ((select auth.uid()) = id) with check ((select auth.uid()) = id);
create policy "profiles_admin_all" on public.profiles
  for all using (private.is_admin()) with check (private.is_admin());

-- Catalog & operational tables: staff/admin only (this app has no public
-- storefront, so customers never query these tables directly).
create policy "categories_staff_all" on public.categories for all using (private.is_staff()) with check (private.is_staff());
create policy "brands_staff_all" on public.brands for all using (private.is_staff()) with check (private.is_staff());
create policy "products_staff_all" on public.products for all using (private.is_staff()) with check (private.is_staff());
create policy "suppliers_staff_all" on public.suppliers for all using (private.is_staff()) with check (private.is_staff());
create policy "purchases_staff_all" on public.purchases for all using (private.is_staff()) with check (private.is_staff());
create policy "purchase_items_staff_all" on public.purchase_items for all using (private.is_staff()) with check (private.is_staff());

-- customers: staff/admin full access; a customer can read only their own
-- linked row.
create policy "customers_staff_all" on public.customers
  for all using (private.is_staff()) with check (private.is_staff());
create policy "customers_select_own" on public.customers
  for select using (user_id = (select auth.uid()));

-- sales: staff/admin full access; a customer can read only sales tied to
-- their own customer record.
create policy "sales_staff_all" on public.sales
  for all using (private.is_staff()) with check (private.is_staff());
create policy "sales_select_own" on public.sales
  for select using (
    exists (select 1 from public.customers c where c.id = sales.customer_id and c.user_id = (select auth.uid()))
  );

create policy "sale_items_staff_all" on public.sale_items
  for all using (private.is_staff()) with check (private.is_staff());
create policy "sale_items_select_own" on public.sale_items
  for select using (
    exists (
      select 1 from public.sales s
      join public.customers c on c.id = s.customer_id
      where s.id = sale_items.sale_id and c.user_id = (select auth.uid())
    )
  );

create policy "returns_staff_all" on public.returns
  for all using (private.is_staff()) with check (private.is_staff());
create policy "returns_select_own" on public.returns
  for select using (
    exists (
      select 1 from public.sale_items si
      join public.sales s on s.id = si.sale_id
      join public.customers c on c.id = s.customer_id
      where si.id = returns.sale_item_id and c.user_id = (select auth.uid())
    )
  );

-- Covering indexes for the UUID foreign keys above (flagged by the
-- Supabase performance advisor if missing).
create index if not exists purchases_recorded_by_idx on public.purchases (recorded_by);
create index if not exists returns_processed_by_idx on public.returns (processed_by);
create index if not exists sales_cashier_idx on public.sales (cashier_id);
