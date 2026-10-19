create or replace function public.create_store_order(
    p_customer_id bigint,
    p_phone text,
    p_shipping_address text,
    p_payment_method text,
    p_notes text,
    p_items jsonb,
    p_promo_code text default null
)
returns table(
    order_id bigint,
    order_no text,
    subtotal numeric,
    discount numeric,
    delivery_charge numeric,
    promo_code text,
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
    v_discount numeric := 0;
    v_delivery_charge numeric := 100;
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

    -- Promotion values.
    v_promotion_id bigint;
    v_promotion_code text;
    v_discount_type text;
    v_discount_value numeric;
    v_minimum_order_amount numeric;
    v_maximum_discount_amount numeric;
    v_starts_at timestamptz;
    v_expires_at timestamptz;
    v_usage_limit integer;
    v_usage_count integer;
    v_per_customer_limit integer;
    v_is_active boolean;

    v_customer_promo_usage integer := 0;

    v_clean_promo_code text;

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
    -- Calculate trusted subtotal from database product prices.
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

        select
            unit_price,
            stock_quantity
        into
            v_unit_price,
            v_stock
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


    -- --------------------------------------------------------
    -- Read server-controlled delivery charge.
    --
    -- The customer cannot provide this value.
    -- --------------------------------------------------------

    select ss.delivery_charge
    into v_delivery_charge
    from public.store_settings as ss
    where ss.id = 1;

    v_delivery_charge :=
        coalesce(v_delivery_charge, 100);

    if v_delivery_charge < 0 then
        raise exception 'Store delivery charge is invalid';
    end if;


    -- --------------------------------------------------------
    -- Normalize promo code.
    -- --------------------------------------------------------

    v_clean_promo_code :=
        nullif(
            upper(trim(coalesce(p_promo_code, ''))),
            ''
        );


    -- --------------------------------------------------------
    -- Validate and lock promotion.
    --
    -- The promotion row is locked so concurrent checkouts
    -- cannot exceed usage limits.
    -- --------------------------------------------------------

    if v_clean_promo_code is not null then

        select
            sp.id,
            sp.code,
            sp.discount_type,
            sp.discount_value,
            sp.minimum_order_amount,
            sp.maximum_discount_amount,
            sp.starts_at,
            sp.expires_at,
            sp.usage_limit,
            sp.usage_count,
            sp.per_customer_limit,
            sp.is_active
        into
            v_promotion_id,
            v_promotion_code,
            v_discount_type,
            v_discount_value,
            v_minimum_order_amount,
            v_maximum_discount_amount,
            v_starts_at,
            v_expires_at,
            v_usage_limit,
            v_usage_count,
            v_per_customer_limit,
            v_is_active
        from public.store_promotions sp
        where lower(sp.code) = lower(v_clean_promo_code)
        for update;

        if not found then
            raise exception 'Invalid promo code';
        end if;


        if not v_is_active then
            raise exception 'Promo code is inactive';
        end if;


        if v_starts_at > now() then
            raise exception 'Promo code is not active yet';
        end if;


        if v_expires_at is not null
           and v_expires_at <= now()
        then
            raise exception 'Promo code has expired';
        end if;


        if v_usage_limit is not null
           and v_usage_count >= v_usage_limit
        then
            raise exception 'Promo code usage limit reached';
        end if;


        if v_minimum_order_amount is not null
           and v_subtotal < v_minimum_order_amount
        then
            raise exception
                'Minimum order amount for this promo is %',
                v_minimum_order_amount;
        end if;


        if v_per_customer_limit is not null then

            select count(*)::integer
            into v_customer_promo_usage
            from public.store_promotion_usage spu
            where spu.promotion_id = v_promotion_id
              and spu.customer_id = p_customer_id;

            if v_customer_promo_usage >= v_per_customer_limit then
                raise exception
                    'Promo code customer usage limit reached';
            end if;

        end if;


        -- ----------------------------------------------------
        -- Calculate promotion discount.
        -- ----------------------------------------------------

        if v_discount_type = 'percentage' then

            v_discount :=
                v_subtotal * v_discount_value / 100;

            if v_maximum_discount_amount is not null then
                v_discount :=
                    least(
                        v_discount,
                        v_maximum_discount_amount
                    );
            end if;

        elsif v_discount_type = 'fixed' then

            v_discount :=
                least(
                    v_discount_value,
                    v_subtotal
                );

        elsif v_discount_type = 'free_delivery' then

            v_discount := 0;
            v_delivery_charge := 0;

        else

            raise exception
                'Invalid promotion type';

        end if;


        -- Never allow discount to exceed subtotal.
        v_discount :=
            least(
                greatest(v_discount, 0),
                v_subtotal
            );

    end if;


    -- --------------------------------------------------------
    -- Calculate final authoritative total.
    -- --------------------------------------------------------

    v_total :=
        greatest(
            v_subtotal
            - v_discount
            + v_delivery_charge,
            0
        );


    -- --------------------------------------------------------
    -- Credit limit enforcement uses FINAL total.
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
    --
    -- Pricing values are snapshotted here.
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
        notes,
        delivery_charge,
        promo_code,
        promotion_id
    )
    values (
        v_order_no,
        p_customer_id,
        'pending',
        v_subtotal,
        v_discount,
        0,
        v_total,
        p_payment_method::public.payment_method,
        'unpaid',
        trim(p_shipping_address),
        trim(p_phone),
        nullif(
            trim(coalesce(p_notes, '')),
            ''
        ),
        v_delivery_charge,
        v_promotion_code,
        v_promotion_id
    )
    returning id into v_order_id;


    -- --------------------------------------------------------
    -- Create order items and decrease inventory.
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
    -- Record promotion usage.
    --
    -- This occurs in the same transaction as the order.
    -- If checkout fails later, the entire transaction rolls back.
    -- --------------------------------------------------------

    if v_promotion_id is not null then

        update public.store_promotions
        set
            usage_count = usage_count + 1,
            updated_at = now()
        where id = v_promotion_id;


        insert into public.store_promotion_usage (
            promotion_id,
            customer_id,
            order_id
        )
        values (
            v_promotion_id,
            p_customer_id,
            v_order_id
        );

    end if;


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
        v_discount,
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
    -- These rows do not change inventory.
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
    -- Return authoritative pricing.
    -- --------------------------------------------------------

    return query
    select
        v_order_id,
        v_order_no,
        v_subtotal,
        v_discount,
        v_delivery_charge,
        v_promotion_code,
        v_total;

end;
$function$;

-- ============================================================
-- THE BLUE MOON STORE
-- Amendment to: 012_create_store_order_fixed.sql
-- Feature: Checkout promo preview / Apply button
-- Function: preview_store_checkout
-- ============================================================

create or replace function public.preview_store_checkout(
    p_customer_id bigint,
    p_phone text,
    p_shipping_address text,
    p_payment_method text,
    p_items jsonb,
    p_promo_code text default null
)
returns table (
    subtotal numeric,
    discount numeric,
    original_delivery_charge numeric,
    delivery_discount numeric,
    delivery_charge numeric,
    promo_code text,
    total_amount numeric
)
language plpgsql
security definer
set search_path = public
as $function$
declare
    v_customer_role text;
    v_customer_active boolean;

    v_subtotal numeric := 0;
    v_discount numeric := 0;
    v_base_delivery_charge numeric := 0;
    v_delivery_charge numeric := 0;
    v_delivery_discount numeric := 0;
    v_total numeric := 0;

    v_promo_code text;
    v_promotion_id bigint;
    v_discount_type text;
    v_discount_value numeric;
    v_minimum_order_amount numeric;
    v_maximum_discount_amount numeric;
    v_usage_limit integer;
    v_usage_count integer;
    v_per_customer_limit integer;
    v_customer_usage integer;
    v_starts_at timestamptz;
    v_expires_at timestamptz;

    v_item jsonb;
    v_product_id bigint;
    v_quantity integer;
    v_unit_price numeric;
    v_stock integer;
    v_seen_product_ids bigint[] := '{}';
begin
    -- Basic customer validation
    if p_customer_id is null or p_customer_id <= 0 then
        raise exception 'Invalid customer';
    end if;

    select role, is_active
    into v_customer_role, v_customer_active
    from public.profiles
    where id = p_customer_id
    limit 1;

    if v_customer_role is null then
        raise exception 'Customer profile not found';
    end if;

    if v_customer_role <> 'customer' then
        raise exception 'Only customer accounts can place store orders';
    end if;

    if coalesce(v_customer_active, false) = false then
        raise exception 'Customer account is inactive';
    end if;

    -- Validate checkout fields using the same rules as final checkout
    if p_shipping_address is null
       or length(trim(p_shipping_address)) < 5
       or length(trim(p_shipping_address)) > 500 then
        raise exception 'Shipping address must be between 5 and 500 characters';
    end if;

    if p_phone is null
       or length(trim(p_phone)) < 7
       or length(trim(p_phone)) > 30 then
        raise exception 'Phone number must be between 7 and 30 characters';
    end if;

    if p_payment_method not in ('cash', 'card', 'mobile', 'credit', 'cod') then
        raise exception 'Invalid payment method';
    end if;

    if p_items is null
       or jsonb_typeof(p_items) <> 'array'
       or jsonb_array_length(p_items) = 0 then
        raise exception 'Cart cannot be empty';
    end if;

    if jsonb_array_length(p_items) > 100 then
        raise exception 'Cart contains too many items';
    end if;

    -- Calculate trusted subtotal from current database prices.
    -- Preview never changes stock.
    for v_item in
        select value
        from jsonb_array_elements(p_items)
    loop
        if jsonb_typeof(v_item) <> 'object' then
            raise exception 'Invalid cart item';
        end if;

        if not (v_item ? 'product_id') or not (v_item ? 'quantity') then
            raise exception 'Invalid cart item';
        end if;

        begin
            v_product_id := (v_item ->> 'product_id')::bigint;
            v_quantity := (v_item ->> 'quantity')::integer;
        exception
            when invalid_text_representation then
                raise exception 'Invalid product or quantity';
        end;

        if v_product_id <= 0 or v_quantity <= 0 then
            raise exception 'Invalid product or quantity';
        end if;

        if v_product_id = any(v_seen_product_ids) then
            raise exception 'Duplicate product in cart';
        end if;

        v_seen_product_ids := array_append(v_seen_product_ids, v_product_id);

        select unit_price, stock
        into v_unit_price, v_stock
        from public.store_products
        where id = v_product_id
          and coalesce(is_active, true) = true
        limit 1;

        if not found then
            raise exception 'Product not found or unavailable';
        end if;

        if v_stock < v_quantity then
            raise exception 'Insufficient stock';
        end if;

        if v_unit_price is null or v_unit_price < 0 then
            raise exception 'Invalid product price';
        end if;

        v_subtotal := v_subtotal + (v_unit_price * v_quantity);
    end loop;

    -- Server-controlled delivery charge
    select delivery_charge
    into v_base_delivery_charge
    from public.store_settings
    limit 1;

    v_base_delivery_charge := greatest(
        coalesce(v_base_delivery_charge, 100),
        0
    );

    v_delivery_charge := v_base_delivery_charge;

    -- Normalize promo code
    v_promo_code := nullif(upper(trim(coalesce(p_promo_code, ''))), '');

    if v_promo_code is not null then
        select
            id,
            code,
            discount_type,
            discount_value,
            minimum_order_amount,
            maximum_discount_amount,
            usage_limit,
            usage_count,
            per_customer_limit,
            starts_at,
            expires_at
        into
            v_promotion_id,
            v_promo_code,
            v_discount_type,
            v_discount_value,
            v_minimum_order_amount,
            v_maximum_discount_amount,
            v_usage_limit,
            v_usage_count,
            v_per_customer_limit,
            v_starts_at,
            v_expires_at
        from public.store_promotions
        where upper(code) = v_promo_code
        limit 1;

        if not found then
            raise exception 'Invalid promo code';
        end if;

        if not exists (
            select 1
            from public.store_promotions
            where id = v_promotion_id
              and is_active = true
        ) then
            raise exception 'Promo code is inactive';
        end if;

        if v_starts_at is not null and v_starts_at > now() then
            raise exception 'Promo code is not active yet';
        end if;

        if v_expires_at is not null and v_expires_at < now() then
            raise exception 'Promo code has expired';
        end if;

        if v_usage_limit is not null
           and coalesce(v_usage_count, 0) >= v_usage_limit then
            raise exception 'Promo code usage limit reached';
        end if;

        if v_minimum_order_amount is not null
           and v_subtotal < v_minimum_order_amount then
            raise exception 'Minimum order amount for this promo is '
                || v_minimum_order_amount;
        end if;

        if v_per_customer_limit is not null then
            select count(*)
            into v_customer_usage
            from public.store_promotion_usage
            where promotion_id = v_promotion_id
              and customer_id = p_customer_id;

            if coalesce(v_customer_usage, 0) >= v_per_customer_limit then
                raise exception 'You have reached the usage limit for this promo';
            end if;
        end if;

        -- Calculate the exact same promotion rules as final checkout.
        if v_discount_type = 'percentage' then
            v_discount :=
                v_subtotal * coalesce(v_discount_value, 0) / 100;

            if v_maximum_discount_amount is not null then
                v_discount := least(
                    v_discount,
                    v_maximum_discount_amount
                );
            end if;

        elsif v_discount_type = 'fixed' then
            v_discount := least(
                coalesce(v_discount_value, 0),
                v_subtotal
            );

        elsif v_discount_type = 'free_delivery' then
            v_discount := 0;
            v_delivery_charge := 0;

        else
            raise exception 'Invalid promotion configuration';
        end if;
    end if;

    v_discount := greatest(
        least(v_discount, v_subtotal),
        0
    );

    v_delivery_charge := greatest(
        coalesce(v_delivery_charge, 0),
        0
    );

    v_delivery_discount := greatest(
        v_base_delivery_charge - v_delivery_charge,
        0
    );

    v_total := greatest(
        v_subtotal
        - v_discount
        + v_delivery_charge,
        0
    );

    -- Return preview only.
    -- Nothing is inserted, stock is not changed,
    -- and promotion usage is not incremented.
    return query
    select
        round(v_subtotal, 2),
        round(v_discount, 2),
        round(v_base_delivery_charge, 2),
        round(v_delivery_discount, 2),
        round(v_delivery_charge, 2),
        v_promo_code,
        round(v_total, 2);
end;
$function$;

revoke all on function public.preview_store_checkout(
    bigint,
    text,
    text,
    text,
    jsonb,
    text
) from public;

grant execute on function public.preview_store_checkout(
    bigint,
    text,
    text,
    text,
    jsonb,
    text
) to service_role;

-- ============================================================
-- END: promo preview amendment
-- ============================================================

