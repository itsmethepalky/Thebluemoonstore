-- ============================================================
-- The Blue Moon
-- Migration 009: Deterministic inventory lock ordering
-- ============================================================
--
-- Purpose:
--   Ensure Store checkout and Store cancellation acquire
--   multiple product row locks in deterministic product-ID
--   order.
--
-- This matches the POS inventory locking strategy and reduces
-- the possibility of deadlocks when Store and POS operations
-- touch overlapping products concurrently.
-- ============================================================


-- ------------------------------------------------------------
-- 1. Harden create_store_order lock ordering
-- ------------------------------------------------------------

create or replace function public.create_store_order(
    p_customer_id bigint,
    p_phone text,
    p_shipping_address text,
    p_payment_method text,
    p_notes text,
    p_items jsonb
)
returns table(
    order_id bigint,
    order_no text,
    total_amount numeric
)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    v_order_id bigint;
    v_order_no text;
    v_sale_id bigint;
    v_invoice_no text;

    v_subtotal numeric := 0;
    v_total numeric := 0;

    v_item jsonb;
    v_product_id bigint;
    v_quantity integer;
    v_unit_price numeric;
    v_line_total numeric;
    v_stock integer;

    v_amount_paid numeric := 0;
    v_payment_status public.payment_status := 'unpaid';

    v_customer_credit_limit numeric;
    v_customer_credit_balance numeric;

    v_seen_product_ids bigint[] := '{}';
begin

    -- --------------------------------------------------------
    -- Validate customer id.
    -- --------------------------------------------------------

    if p_customer_id is null
       or p_customer_id <= 0
    then
        raise exception 'Invalid customer';
    end if;


    -- --------------------------------------------------------
    -- Validate shipping address.
    -- --------------------------------------------------------

    if p_shipping_address is null
       or length(trim(p_shipping_address)) < 5
       or length(trim(p_shipping_address)) > 500
    then
        raise exception 'A valid shipping address is required';
    end if;


    -- --------------------------------------------------------
    -- Validate phone.
    -- --------------------------------------------------------

    if p_phone is null
       or length(trim(p_phone)) < 7
       or length(trim(p_phone)) > 30
    then
        raise exception 'A valid phone number is required';
    end if;


    -- --------------------------------------------------------
    -- Validate payment method.
    -- --------------------------------------------------------

    if p_payment_method is null
       or p_payment_method not in (
           'cash',
           'card',
           'mobile',
           'credit',
           'cod'
       )
    then
        raise exception 'Invalid payment method';
    end if;


    -- --------------------------------------------------------
    -- Validate cart.
    -- --------------------------------------------------------

    if p_items is null
       or jsonb_typeof(p_items) <> 'array'
       or jsonb_array_length(p_items) = 0
    then
        raise exception 'Cart is empty';
    end if;

    if jsonb_array_length(p_items) > 100 then
        raise exception 'Too many cart items';
    end if;


    -- --------------------------------------------------------
    -- Verify customer profile.
    --
    -- Credit checkout locks the customer row before checking
    -- and changing credit balance.
    -- --------------------------------------------------------

    if p_payment_method = 'credit' then

        select
            c.credit_limit,
            c.credit_balance
        into
            v_customer_credit_limit,
            v_customer_credit_balance
        from public.customers c
        join public.profiles p
          on p.id = c.user_id
        where c.id = p_customer_id
          and p.role = 'customer'
          and p.is_active = true
        for update;

        if not found then
            raise exception 'Customer account not found';
        end if;

        if coalesce(v_customer_credit_limit, 0) < 0
           or coalesce(v_customer_credit_balance, 0) < 0
        then
            raise exception 'Customer credit account is invalid';
        end if;

    else

        if not exists (
            select 1
            from public.customers c
            join public.profiles p
              on p.id = c.user_id
            where c.id = p_customer_id
              and p.role = 'customer'
              and p.is_active = true
        ) then
            raise exception 'Customer account not found';
        end if;

    end if;


    -- --------------------------------------------------------
    -- Validate cart structure and collect unique product IDs.
    --
    -- IMPORTANT:
    --   No product locks are taken here.
    --   This lets us collect every product first and then lock
    --   all products in deterministic ascending ID order.
    -- --------------------------------------------------------

    for v_item in
        select value
        from jsonb_array_elements(p_items)
    loop

        if jsonb_typeof(v_item) <> 'object' then
            raise exception 'Invalid cart item';
        end if;

        begin
            v_product_id :=
                (v_item->>'product_id')::bigint;

            v_quantity :=
                (v_item->>'quantity')::integer;
        exception
            when invalid_text_representation then
                raise exception 'Invalid cart item';
        end;

        if v_product_id is null
           or v_product_id <= 0
           or v_quantity is null
           or v_quantity <= 0
        then
            raise exception 'Invalid cart item';
        end if;

        if v_product_id = any(v_seen_product_ids) then
            raise exception
                'Duplicate product in cart';
        end if;

        v_seen_product_ids :=
            array_append(
                v_seen_product_ids,
                v_product_id
            );

    end loop;


    -- --------------------------------------------------------
    -- Lock ALL affected products in ascending product-ID order.
    --
    -- This is the critical concurrency hardening.
    -- POS sales/purchases use the same ordering.
    -- --------------------------------------------------------

    for v_product_id in
        select unnest(v_seen_product_ids)
        order by 1
    loop

        select
            unit_price,
            stock_quantity
        into
            v_unit_price,
            v_stock
        from public.products
        where id = v_product_id
          and is_active = true
        for update;

        if not found then
            raise exception
                'Product % is no longer available',
                v_product_id;
        end if;

        if v_unit_price is null
           or v_unit_price < 0
        then
            raise exception
                'Product price is invalid';
        end if;

        if v_stock is null
           or v_stock < 0
        then
            raise exception
                'Product stock is invalid';
        end if;

    end loop;


    -- --------------------------------------------------------
    -- Calculate subtotal while all product locks are held.
    -- --------------------------------------------------------

    v_subtotal := 0;

    for v_item in
        select value
        from jsonb_array_elements(p_items)
    loop

        v_product_id :=
            (v_item->>'product_id')::bigint;

        v_quantity :=
            (v_item->>'quantity')::integer;

        select unit_price, stock_quantity
        into v_unit_price, v_stock
        from public.products
        where id = v_product_id;

        if v_stock < v_quantity then
            raise exception
                'Insufficient stock for product %',
                v_product_id;
        end if;

        v_line_total :=
            v_unit_price * v_quantity;

        v_subtotal :=
            v_subtotal + v_line_total;

    end loop;


    v_total := v_subtotal;


    -- --------------------------------------------------------
    -- Credit limit enforcement.
    -- --------------------------------------------------------

    if p_payment_method = 'credit' then

        if v_customer_credit_limit <= 0 then
            raise exception
                'Customer credit is not available';
        end if;

        if v_customer_credit_balance + v_total
           > v_customer_credit_limit
        then
            raise exception
                'Customer credit limit exceeded';
        end if;

    end if;


    -- --------------------------------------------------------
    -- Generate order number.
    -- --------------------------------------------------------

    v_order_no :=
        'BM-' ||
        to_char(
            clock_timestamp(),
            'YYYYMMDDHH24MISS'
        ) ||
        '-' ||
        lpad(
            floor(random() * 1000)::integer::text,
            3,
            '0'
        );


    -- --------------------------------------------------------
    -- Create ecommerce order.
    -- --------------------------------------------------------

    insert into public.orders (
        order_no,
        customer_id,
        status,
        subtotal,
        discount,
        tax,
        total_amount,
        payment_method,
        payment_status,
        shipping_address,
        phone,
        notes
    )
    values (
        v_order_no,
        p_customer_id,
        'pending',
        v_subtotal,
        0,
        0,
        v_total,
        p_payment_method::public.payment_method,
        'unpaid',
        trim(p_shipping_address),
        trim(p_phone),
        nullif(
            trim(coalesce(p_notes, '')),
            ''
        )
    )
    returning id into v_order_id;


    -- --------------------------------------------------------
    -- Create order items and decrease inventory.
    --
    -- Product locks were acquired above and remain held until
    -- the complete RPC transaction finishes.
    -- --------------------------------------------------------

    for v_item in
        select value
        from jsonb_array_elements(p_items)
    loop

        v_product_id :=
            (v_item->>'product_id')::bigint;

        v_quantity :=
            (v_item->>'quantity')::integer;

        select unit_price
        into v_unit_price
        from public.products
        where id = v_product_id;

        v_line_total :=
            v_unit_price * v_quantity;

        insert into public.order_items (
            order_id,
            product_id,
            quantity,
            unit_price,
            discount,
            subtotal
        )
        values (
            v_order_id,
            v_product_id,
            v_quantity,
            v_unit_price,
            0,
            v_line_total
        );

        update public.products
        set
            stock_quantity =
                stock_quantity - v_quantity,
            updated_at = now()
        where id = v_product_id;

    end loop;


    -- --------------------------------------------------------
    -- Payment handling.
    -- --------------------------------------------------------

    if p_payment_method = 'credit' then

        v_payment_status := 'unpaid';
        v_amount_paid := 0;

        update public.customers
        set credit_balance =
            credit_balance + v_total
        where id = p_customer_id;

    else

        v_payment_status := 'unpaid';
        v_amount_paid := 0;

    end if;


    -- --------------------------------------------------------
    -- Create linked POS sale.
    -- --------------------------------------------------------

    v_invoice_no :=
        'WEB-' || v_order_no;

    insert into public.sales (
        invoice_no,
        customer_id,
        cashier_id,
        subtotal,
        discount,
        tax,
        total_amount,
        payment_method,
        amount_paid,
        payment_status,
        status,
        sale_date,
        store_order_id
    )
    values (
        v_invoice_no,
        p_customer_id,
        null,
        v_subtotal,
        0,
        0,
        v_total,
        p_payment_method::public.payment_method,
        v_amount_paid,
        v_payment_status,
        'completed',
        now(),
        v_order_id
    )
    returning id into v_sale_id;


    -- --------------------------------------------------------
    -- Create linked POS sale items.
    --
    -- These rows DO NOT change inventory.
    -- --------------------------------------------------------

    for v_item in
        select value
        from jsonb_array_elements(p_items)
    loop

        v_product_id :=
            (v_item->>'product_id')::bigint;

        v_quantity :=
            (v_item->>'quantity')::integer;

        select unit_price
        into v_unit_price
        from public.products
        where id = v_product_id;

        v_line_total :=
            v_unit_price * v_quantity;

        insert into public.sale_items (
            sale_id,
            product_id,
            quantity,
            unit_price,
            discount,
            subtotal,
            returned_quantity
        )
        values (
            v_sale_id,
            v_product_id,
            v_quantity,
            v_unit_price,
            0,
            v_line_total,
            0
        );

    end loop;


    -- --------------------------------------------------------
    -- Return order information.
    -- --------------------------------------------------------

    return query
    select
        v_order_id,
        v_order_no,
        v_total;

end;
$function$;


-- ------------------------------------------------------------
-- 2. Harden cancel_store_order product lock ordering
-- ------------------------------------------------------------

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
        o.amount_paid
    into v_order
    from public.orders o
    where o.id = p_order_id
    for update;

    if not found then
        raise exception 'Order not found';
    end if;


    if v_order.status =
       'cancelled'::public.order_status
    then
        return query
        select
            v_order.id,
            v_order.order_no,
            false;

        return;
    end if;


    if v_order.status =
       'delivered'::public.order_status
    then
        raise exception
            'Order cannot be cancelled';
    end if;


    if coalesce(v_order.amount_paid, 0) < 0
       or coalesce(v_order.amount_paid, 0)
          > v_order.total_amount
    then
        raise exception
            'Order payment data is invalid';
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
-- 3. Preserve restricted execution permissions
-- ------------------------------------------------------------

revoke execute
on function public.create_store_order(
    bigint,
    text,
    text,
    text,
    text,
    jsonb
)
from public, anon, authenticated;

revoke execute
on function public.cancel_store_order(
    bigint
)
from public, anon, authenticated;

grant execute
on function public.create_store_order(
    bigint,
    text,
    text,
    text,
    text,
    jsonb
)
to service_role;

grant execute
on function public.cancel_store_order(
    bigint
)
to service_role;
