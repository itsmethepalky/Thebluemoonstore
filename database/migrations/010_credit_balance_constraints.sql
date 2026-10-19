-- ============================================================
-- Migration 010: Credit balance/limit constraints
-- ============================================================
-- Prevent negative customer credit values at the database level.
-- Existing data was verified before applying this migration.
-- ============================================================

begin;

alter table public.customers
    add constraint customers_credit_balance_nonnegative
    check (credit_balance >= 0);

alter table public.customers
    add constraint customers_credit_limit_nonnegative
    check (credit_limit >= 0);

commit;
