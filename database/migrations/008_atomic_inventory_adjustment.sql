-- ============================================================================
-- Migration 008: Atomic inventory adjustment
-- ============================================================================
-- Purpose:
--   Prevent stale admin inventory values from overwriting stock changes made
--   concurrently by checkout/POS operations.
--
-- The application supplies a relative adjustment:
--   +5 = receive 5 units
--   -3 = remove 3 units
--
-- PostgreSQL locks the product row before calculating the new quantity.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Atomic inventory adjustment function
-- ---------------------------------------------------------------------------

create or replace function public.adjust_store_product_stock(
    p_product_id bigint,
    p_adjustment integer
)
returns table(
    product_id bigint,
    stock_quantity integer
)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    v_current_stock integer;
    v_new_stock integer;
begin

    if p_product_id is null
       or p_product_id <= 0
    then
        raise exception 'Invalid product';
    end if;

    if p_adjustment is null
       or p_adjustment = 0
    then
        raise exception 'Stock adjustment cannot be zero';
    end if;


    -- Lock the product row so concurrent checkout/POS/admin operations
    -- cannot calculate stock from the same stale value.

    select p.stock_quantity
    into v_current_stock
    from public.products p
    where p.id = p_product_id
    for update;


    if not found then
        raise exception 'Product not found';
    end if;


    if v_current_stock is null
       or v_current_stock < 0
    then
        raise exception 'Product stock data is invalid';
    end if;


    v_new_stock :=
        v_current_stock + p_adjustment;


    if v_new_stock < 0 then
        raise exception 'Insufficient stock for adjustment';
    end if;


    update public.products
    set
        stock_quantity = v_new_stock,
        updated_at = now()
    where id = p_product_id;


    return query
    select
        p.id,
        p.stock_quantity
    from public.products p
    where p.id = p_product_id;

end;
$function$;


-- ---------------------------------------------------------------------------
-- 2. Restrict execution
-- ---------------------------------------------------------------------------
-- This function is called only by the backend using the service-role client.
-- Anonymous/authenticated clients must never be able to call it directly.

revoke execute
on function public.adjust_store_product_stock(
    bigint,
    integer
)
from public, anon, authenticated;


grant execute
on function public.adjust_store_product_stock(
    bigint,
    integer
)
to service_role;
