-- ============================================================
-- 013_release_promo_on_order_cancel.sql
-- Release promotion usage when a store order is cancelled.
-- ============================================================

create or replace function public.cancel_store_order(
    p_order_id bigint
)
returns table(
    order_id bigint,
    order_no text,
    restored boolean
)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    v_order record;
    v_item record;
    v_product_id bigint;
    v_pos_sale_id bigint;
    v_restore_credit numeric;
    v_promotion_id bigint;
begin

    if p_order_id is null
       or p_order_id <= 0
    then
        raise exception 'Invalid order';
    end if;


    -- --------------------------------------------------------
    -- Lock the order first.
    -- --------------------------------------------------------

    select
        o.id,
        o.order_no,
        o.status,
        o.payment_method,
        o.customer_id,
        o.total_amount,
        o.amount_paid,
        o.promotion_id
    into v_order
    from public.orders o
    where o.id = p_order_id
    for update;

    if not found then
        raise exception 'Order not found';
    end if;


    if v_order.status = 'cancelled'::public.order_status then
        return query
        select
            v_order.id,
            v_order.order_no,
            false;
        return;
    end if;


    if v_order.status = 'delivered'::public.order_status then
        raise exception 'Order cannot be cancelled';
    end if;


    if coalesce(v_order.amount_paid, 0) < 0
       or coalesce(v_order.amount_paid, 0) > v_order.total_amount
    then
        raise exception 'Order payment data is invalid';
    end if;


    -- --------------------------------------------------------
    -- Lock customer before modifying credit.
    -- --------------------------------------------------------

    if v_order.payment_method =
       'credit'::public.payment_method
    then

        perform 1
        from public.customers c
        where c.id = v_order.customer_id
        for update;

        if not found then
            raise exception
                'Customer account not found';
        end if;

        v_restore_credit :=
            v_order.total_amount
            - coalesce(v_order.amount_paid, 0);

        update public.customers
        set credit_balance =
            greatest(
                0,
                credit_balance - v_restore_credit
            )
        where id = v_order.customer_id;

    end if;


    -- --------------------------------------------------------
    -- Release promotion usage.
    --
    -- Only decrement usage_count when this order actually has
    -- a usage record. This prevents double-decrementing and
    -- safely handles older orders without usage records.
    -- --------------------------------------------------------

    if v_order.promotion_id is not null then

        select spu.promotion_id
        into v_promotion_id
        from public.store_promotion_usage spu
        where spu.order_id = p_order_id
        for update;

        if v_promotion_id is not null then

            delete from public.store_promotion_usage as spu
            where spu.order_id = p_order_id;

            update public.store_promotions
            set
                usage_count =
                    greatest(
                        0,
                        coalesce(usage_count, 0) - 1
                    ),
                updated_at = now()
            where id = v_promotion_id;

        end if;

    end if;


    -- --------------------------------------------------------
    -- Lock ALL products in ascending product-ID order before
    -- restoring inventory.
    -- --------------------------------------------------------

    for v_product_id in
        select distinct oi.product_id
        from public.order_items oi
        where oi.order_id = p_order_id
        order by oi.product_id
    loop

        perform 1
        from public.products p
        where p.id = v_product_id
        for update;

        if not found then
            raise exception
                'Product % not found',
                v_product_id;
        end if;

    end loop;


    -- --------------------------------------------------------
    -- Restore inventory using the already-locked rows.
    -- --------------------------------------------------------

    for v_item in
        select
            oi.product_id,
            oi.quantity
        from public.order_items oi
        where oi.order_id = p_order_id
        order by oi.id
    loop

        update public.products
        set
            stock_quantity =
                stock_quantity + v_item.quantity,
            updated_at = now()
        where id = v_item.product_id;

    end loop;


    -- --------------------------------------------------------
    -- Mark order cancelled.
    -- --------------------------------------------------------

    update public.orders
    set
        status = 'cancelled'::public.order_status,
        payment_status =
            'unpaid'::public.payment_status,
        amount_paid = 0,
        updated_at = now()
    where id = p_order_id;


    -- --------------------------------------------------------
    -- Synchronize linked POS sale.
    -- --------------------------------------------------------

    select s.id
    into v_pos_sale_id
    from public.sales s
    where s.store_order_id = p_order_id
    for update;

    if v_pos_sale_id is not null then

        update public.sales
        set
            status = 'returned'::public.sale_status,
            payment_status =
                'unpaid'::public.payment_status,
            amount_paid = 0
        where id = v_pos_sale_id;

    end if;


    return query
    select
        v_order.id,
        v_order.order_no,
        true;

end;
$function$;


-- ------------------------------------------------------------
-- Preserve restricted execution permissions.
-- ------------------------------------------------------------

revoke all on function public.cancel_store_order(bigint)
from public, anon, authenticated;

grant execute on function public.cancel_store_order(bigint)
to service_role;
