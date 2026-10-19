-- ============================================================
-- The Blue Moon Ecommerce
-- Migration 005: Secure checkout
-- ============================================================

create or replace function public.create_store_order(
    p_customer_id bigint,
    p_phone text,
    p_shipping_address text,
    p_payment_method text,
    p_notes text,
    p_items jsonb
)
returns table (
    order_id bigint,
    order_no text,
    total_amount numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_order_id bigint;
    v_order_no text;
    v_subtotal numeric := 0;
    v_total numeric := 0;
    v_item jsonb;
    v_product_id bigint;
    v_quantity integer;
    v_unit_price numeric;
    v_line_total numeric;
    v_stock integer;
begin
    -- Basic validation
    if p_customer_id is null then
        raise exception 'Customer is required';
    end if;

    if p_shipping_address is null
       or length(trim(p_shipping_address)) < 5 then
        raise exception 'A valid shipping address is required';
    end if;

    if p_phone is null
       or length(trim(p_phone)) < 7 then
        raise exception 'A valid phone number is required';
    end if;

    if p_payment_method not in ('cash', 'card', 'mobile', 'credit') then
        raise exception 'Invalid payment method';
    end if;

    if p_items is null
       or jsonb_typeof(p_items) <> 'array'
       or jsonb_array_length(p_items) = 0 then
        raise exception 'Cart is empty';
    end if;


    -- Verify the customer exists.
    if not exists (
        select 1
        from public.customers
        where id = p_customer_id
    ) then
        raise exception 'Customer account not found';
    end if;


    -- Lock each product row while checking stock and prices.
    -- This prevents two simultaneous checkouts from overselling stock.
    for v_item in
        select value
        from jsonb_array_elements(p_items)
    loop

        v_product_id :=
            (v_item->>'product_id')::bigint;

        v_quantity :=
            (v_item->>'quantity')::integer;


        if v_product_id is null
           or v_quantity is null
           or v_quantity <= 0 then
            raise exception 'Invalid cart item';
        end if;


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


    -- Currently delivery/tax/discount are zero.
    -- These can be extended later without trusting browser values.
    v_total := v_subtotal;


    -- Generate a human-readable order number.
    v_order_no :=
        'BM-' ||
        to_char(clock_timestamp(), 'YYYYMMDDHH24MISS') ||
        '-' ||
        lpad(
            floor(random() * 1000)::integer::text,
            3,
            '0'
        );


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
        nullif(trim(coalesce(p_notes, '')), '')
    )
    returning id into v_order_id;


    -- Create order items using the DATABASE price,
    -- not the browser-supplied price.
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


        -- Decrease inventory atomically.
        update public.products
        set stock_quantity =
            stock_quantity - v_quantity,
            updated_at = now()
        where id = v_product_id;

    end loop;


    return query
    select
        v_order_id,
        v_order_no,
        v_total;

exception
    when others then
        raise;
end;
$$;


revoke all
on function public.create_store_order(
    bigint,
    text,
    text,
    text,
    text,
    jsonb
)
from public;


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
