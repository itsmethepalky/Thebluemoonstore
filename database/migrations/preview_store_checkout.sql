-- ============================================================
-- THE BLUE MOON STORE
-- Checkout promo preview / Apply button
-- Amendment to: 012_create_store_order_fixed.sql
--
-- IMPORTANT:
-- This function mirrors the pricing/validation rules in
-- public.create_store_order but performs NO side effects.
--
-- It does NOT:
--   - create an order
--   - decrease stock
--   - create sales
--   - change customer credit
--   - increment promotion usage
--   - insert promotion usage records
--
-- The final create_store_order RPC remains authoritative.
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
    v_customer_credit_limit numeric;
    v_customer_credit_balance numeric;

    v_item jsonb;
    v_product_id bigint;
    v_quantity integer;

    v_seen_product_ids bigint[] := '{}';

    v_unit_price numeric;
    v_stock numeric;
    v_line_total numeric;

    v_subtotal numeric := 0;
    v_discount numeric := 0;
    v_total numeric := 0;

    v_base_delivery_charge numeric := 100;
    v_delivery_charge numeric := 100;
    v_original_delivery_charge numeric := 100;
    v_delivery_discount numeric := 0;

    v_clean_promo_code text;
    v_promotion_id bigint;
    v_promotion_code text;
    v_discount_type text;
    v_discount_value numeric;
    v_minimum_order_amount numeric;
    v_maximum_discount_amount numeric;
    v_usage_limit integer;
    v_usage_count integer;
    v_per_customer_limit integer;
    v_customer_promo_usage integer;
    v_starts_at timestamptz;
    v_expires_at timestamptz;
    v_is_active boolean;
begin

    -- --------------------------------------------------------
    -- Basic request validation.
    -- --------------------------------------------------------

    if p_customer_id is null or p_customer_id <= 0 then
        raise exception 'Invalid customer account';
    end if;

    if coalesce(length(trim(p_shipping_address)), 0) not between 5 and 500 then
        raise exception 'Shipping address must be between 5 and 500 characters';
    end if;

    if coalesce(length(trim(p_phone)), 0) not between 7 and 30 then
        raise exception 'Phone number must be between 7 and 30 characters';
    end if;

    if p_payment_method not in ('cash', 'card', 'mobile', 'credit', 'cod') then
        raise exception 'Invalid payment method';
    end if;

    if coalesce(jsonb_typeof(p_items), '') <> 'array' then
        raise exception 'Cart items must be an array';
    end if;

    if jsonb_array_length(p_items) = 0 then
        raise exception 'Cart cannot be empty';
    end if;

    if jsonb_array_length(p_items) > 100 then
        raise exception 'Cart contains too many items';
    end if;


    -- --------------------------------------------------------
    -- Validate customer account.
    --
    -- This exactly follows create_store_order:
    -- customers.id is the checkout customer ID.
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
          and p.is_active = true;

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
            raise exception 'Duplicate product in cart';
        end if;

        v_seen_product_ids :=
            array_append(
                v_seen_product_ids,
                v_product_id
            );

    end loop;


    -- --------------------------------------------------------
    -- Validate all affected products.
    --
    -- Preview deliberately does NOT use FOR UPDATE because
    -- preview must not hold database locks while the customer
    -- is looking at the checkout page.
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
          and is_active = true;

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
    -- Calculate trusted subtotal from database prices.
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
    -- --------------------------------------------------------

    select ss.delivery_charge
    into v_base_delivery_charge
    from public.store_settings as ss
    where ss.id = 1;

    v_base_delivery_charge :=
        coalesce(v_base_delivery_charge, 100);

    if v_base_delivery_charge < 0 then
        raise exception
            'Store delivery charge is invalid';
    end if;

    v_original_delivery_charge :=
        v_base_delivery_charge;

    v_delivery_charge :=
        v_base_delivery_charge;


    -- --------------------------------------------------------
    -- Normalize promo code.
    -- --------------------------------------------------------

    v_clean_promo_code :=
        nullif(
            upper(trim(coalesce(p_promo_code, ''))),
            ''
        );


    -- --------------------------------------------------------
    -- Validate promotion.
    --
    -- Same rules as create_store_order, but NO FOR UPDATE.
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
        limit 1;

        if not found then
            raise exception 'Invalid promo code';
        end if;

        if not v_is_active then
            raise exception 'Promo code is inactive';
        end if;

        if v_starts_at > now() then
            raise exception
                'Promo code is not active yet';
        end if;

        if v_expires_at is not null
           and v_expires_at <= now()
        then
            raise exception
                'Promo code has expired';
        end if;

        if v_usage_limit is not null
           and coalesce(v_usage_count, 0) >= v_usage_limit
        then
            raise exception
                'Promo code usage limit reached';
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
        -- Exactly the same rules as create_store_order.
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
    -- Calculate delivery discount for display.
    -- --------------------------------------------------------

    v_delivery_discount :=
        greatest(
            v_original_delivery_charge
            - v_delivery_charge,
            0
        );


    -- --------------------------------------------------------
    -- Calculate final authoritative preview total.
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
    -- This is validation only; nothing is updated.
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
    -- Return preview pricing.
    -- --------------------------------------------------------

    return query
    select
        v_subtotal,
        v_discount,
        v_original_delivery_charge,
        v_delivery_discount,
        v_delivery_charge,
        v_promotion_code,
        v_total;

end;
$function$;


-- Only the backend service role may call this function.
revoke all on function public.preview_store_checkout(
    bigint,
    text,
    text,
    text,
    jsonb,
    text
) from public;

revoke all on function public.preview_store_checkout(
    bigint,
    text,
    text,
    text,
    jsonb,
    text
) from anon;

revoke all on function public.preview_store_checkout(
    bigint,
    text,
    text,
    text,
    jsonb,
    text
) from authenticated;

grant execute on function public.preview_store_checkout(
    bigint,
    text,
    text,
    text,
    jsonb,
    text
) to service_role;
