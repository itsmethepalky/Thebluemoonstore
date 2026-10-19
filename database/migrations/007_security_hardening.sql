-- ============================================================
-- The Blue Moon
-- Migration 007: Store security hardening
-- ============================================================
--
-- Final hardening for ecommerce security-sensitive functions.
--
-- These functions are SECURITY DEFINER and therefore MUST NOT
-- be directly executable by anon/authenticated clients.
--
-- The FastAPI backend calls them using the Supabase service role.
-- ============================================================


-- ------------------------------------------------------------
-- 0. Ensure Store payment tracking column exists.
-- ------------------------------------------------------------

alter table public.orders
add column if not exists amount_paid numeric(12,2) not null default 0;

create index if not exists idx_orders_payment_status
on public.orders(payment_status);


-- ------------------------------------------------------------
-- 1. Harden create_store_order
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
    -- Credit checkout also locks the customer row so concurrent
    -- credit orders cannot race against credit balance.
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
    -- Validate every cart item.
    -- Lock product rows before calculating the total.
    --
    -- Prices always come from the database.
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


        -- Prevent duplicate product rows in one checkout.
        if v_product_id = any(v_seen_product_ids) then
            raise exception
                'Duplicate product in cart';
        end if;

        v_seen_product_ids :=
            array_append(
                v_seen_product_ids,
                v_product_id
            );


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
    --
    -- A zero credit limit means no credit is available.
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
    -- Inventory is decreased ONLY here.
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
-- 2. Harden cancel_store_order
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
    v_pos_sale_id bigint;
    v_restore_credit numeric;
begin

    if p_order_id is null
       or p_order_id <= 0
    then
        raise exception 'Invalid order';
    end if;


    -- --------------------------------------------------------
    -- Lock the order before making any changes.
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


    -- --------------------------------------------------------
    -- Cancellation is idempotent.
    -- --------------------------------------------------------

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


    -- --------------------------------------------------------
    -- Delivered orders cannot be cancelled.
    -- --------------------------------------------------------

    if v_order.status =
       'delivered'::public.order_status
    then
        raise exception
            'Order cannot be cancelled';
    end if;


    -- --------------------------------------------------------
    -- Validate stored payment amount.
    -- --------------------------------------------------------

    if coalesce(v_order.amount_paid, 0) < 0
       or coalesce(v_order.amount_paid, 0)
          > v_order.total_amount
    then
        raise exception
            'Order payment data is invalid';
    end if;


    -- --------------------------------------------------------
    -- For credit orders, reverse only the outstanding amount.
    --
    -- Outstanding credit =
    -- total order amount - amount already paid.
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
    -- Restore inventory.
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

        if not found then
            raise exception
                'Product % not found',
                v_item.product_id;
        end if;

    end loop;


    -- --------------------------------------------------------
    -- Mark order cancelled and reset payment state.
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
-- 3. Harden update_store_order_payment
-- ------------------------------------------------------------

create or replace function public.update_store_order_payment(
    p_order_id bigint,
    p_payment_status public.payment_status,
    p_amount_paid numeric
)
returns table(
    order_id bigint,
    order_no text,
    payment_status public.payment_status,
    amount_paid numeric
)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    v_order record;
    v_old_amount numeric;
    v_new_amount numeric;
    v_credit_delta numeric;
    v_pos_sale_id bigint;
begin

    if p_order_id is null
       or p_order_id <= 0
    then
        raise exception 'Invalid order';
    end if;


    if p_payment_status is null then
        raise exception
            'Payment status is required';
    end if;


    if p_amount_paid is null
       or p_amount_paid < 0
    then
        raise exception
            'Amount paid cannot be negative';
    end if;


    -- --------------------------------------------------------
    -- Lock order before changing payment state.
    -- --------------------------------------------------------

    select
        o.id,
        o.order_no,
        o.customer_id,
        o.total_amount,
        o.payment_method,
        o.status,
        o.payment_status,
        o.amount_paid
    into v_order
    from public.orders o
    where o.id = p_order_id
    for update;

    if not found then
        raise exception 'Order not found';
    end if;


    -- --------------------------------------------------------
    -- Cancelled orders cannot receive payments.
    -- --------------------------------------------------------

    if v_order.status =
       'cancelled'::public.order_status
    then
        raise exception
            'Cancelled orders cannot receive payments';
    end if;


    -- --------------------------------------------------------
    -- Validate stored payment state.
    -- --------------------------------------------------------

    if coalesce(v_order.amount_paid, 0) < 0
       or coalesce(v_order.amount_paid, 0)
          > v_order.total_amount
    then
        raise exception
            'Order payment data is invalid';
    end if;


    -- --------------------------------------------------------
    -- Validate new amount.
    -- --------------------------------------------------------

    if p_amount_paid > v_order.total_amount then
        raise exception
            'Amount paid cannot exceed order total';
    end if;


    if p_payment_status =
       'paid'::public.payment_status
       and p_amount_paid <> v_order.total_amount
    then
        raise exception
            'Paid status requires the full order amount';
    end if;


    if p_payment_status =
       'unpaid'::public.payment_status
       and p_amount_paid <> 0
    then
        raise exception
            'Unpaid status requires amount paid to be 0';
    end if;


    if p_payment_status =
       'partial'::public.payment_status
       and (
           p_amount_paid <= 0
           or p_amount_paid >= v_order.total_amount
       )
    then
        raise exception
            'Partial payment must be greater than 0 and less than the order total';
    end if;


    v_old_amount :=
        coalesce(v_order.amount_paid, 0);

    v_new_amount :=
        p_amount_paid;


    -- --------------------------------------------------------
    -- Adjust customer credit for credit orders.
    --
    -- Increasing payment reduces outstanding credit.
    -- Reducing payment restores outstanding credit.
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

        v_credit_delta :=
            v_old_amount - v_new_amount;

        update public.customers
        set credit_balance =
            greatest(
                0,
                credit_balance + v_credit_delta
            )
        where id = v_order.customer_id;

    end if;


    -- --------------------------------------------------------
    -- Update ecommerce order.
    -- --------------------------------------------------------

    update public.orders
    set
        payment_status = p_payment_status,
        amount_paid = v_new_amount,
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
            payment_status = p_payment_status,
            amount_paid = v_new_amount
        where id = v_pos_sale_id;

    end if;


    return query
    select
        o.id,
        o.order_no,
        o.payment_status,
        o.amount_paid
    from public.orders o
    where o.id = p_order_id;

end;
$function$;


-- ------------------------------------------------------------
-- 4. Lock down all security-sensitive Store RPCs.
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

revoke execute
on function public.update_store_order_payment(
    bigint,
    public.payment_status,
    numeric
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

grant execute
on function public.update_store_order_payment(
    bigint,
    public.payment_status,
    numeric
)
to service_role;


-- ------------------------------------------------------------
-- 5. Atomic Store order status transition.
-- ------------------------------------------------------------

create or replace function public.update_store_order_status(
    p_order_id bigint,
    p_new_status public.order_status
)
returns setof public.orders
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    v_current_status public.order_status;
    v_expected_status public.order_status;
begin

    if p_order_id is null
       or p_order_id <= 0
    then
        raise exception 'Invalid order';
    end if;

    if p_new_status is null then
        raise exception 'Order status is required';
    end if;

    select o.status
    into v_current_status
    from public.orders o
    where o.id = p_order_id
    for update;

    if not found then
        raise exception 'Order not found';
    end if;

    if v_current_status in (
        'cancelled'::public.order_status,
        'delivered'::public.order_status
    ) then
        raise exception
            'Order is already in a terminal state';
    end if;

    v_expected_status :=
        case v_current_status
            when 'pending'::public.order_status
                then 'confirmed'::public.order_status
            when 'confirmed'::public.order_status
                then 'processing'::public.order_status
            when 'processing'::public.order_status
                then 'shipped'::public.order_status
            when 'shipped'::public.order_status
                then 'delivered'::public.order_status
            else null
        end;

    if v_expected_status is null then
        raise exception
            'Invalid current order status';
    end if;

    if p_new_status <> v_expected_status then
        raise exception
            'Invalid status transition';
    end if;

    update public.orders
    set
        status = p_new_status,
        updated_at = now()
    where id = p_order_id;

    return query
    select o.*
    from public.orders o
    where o.id = p_order_id;

end;
$function$;


revoke execute
on function public.update_store_order_status(
    bigint,
    public.order_status
)
from public, anon, authenticated;

grant execute
on function public.update_store_order_status(
    bigint,
    public.order_status
)
to service_role;
