-- Store each checkout's selected delivery coordinates for authorized
-- administration. No existing order values or checkout RPCs are removed.
--
-- Apply after 014_route_based_delivery.sql.

do $migration$
declare
    v_constraint_definition text;
    v_wrapper_oid oid;
    v_overload_count integer;
    v_wrapper_definition text;
    v_wrapper_argument_names text[];
    v_wrapper_result text;
    v_wrapper_signature constant text :=
        'public.create_store_order_with_delivery_location(bigint,text,text,text,text,jsonb,text,numeric,double precision,double precision)';
    v_expected_argument_names constant text[] := array[
        'p_customer_id',
        'p_phone',
        'p_shipping_address',
        'p_payment_method',
        'p_notes',
        'p_items',
        'p_promo_code',
        'p_delivery_distance_km',
        'p_delivery_latitude',
        'p_delivery_longitude'
    ];
    v_expected_result constant text :=
        'TABLE(order_id bigint, order_no text, subtotal numeric, discount numeric, delivery_charge numeric, promo_code text, total_amount numeric)';
begin
    if to_regclass('public.orders') is null then
        raise exception 'Required table public.orders is missing';
    end if;

    if to_regprocedure(
        'public.create_store_order_with_delivery(bigint,text,text,text,text,jsonb,text,numeric)'
    ) is null then
        raise exception
            'The route-priced checkout function is missing'
            using hint =
                'Apply and verify 014_route_based_delivery.sql before migration 015.';
    end if;

    alter table public.orders
        add column if not exists delivery_latitude double precision,
        add column if not exists delivery_longitude double precision;

    if not exists (
        select 1
        from pg_attribute as a
        where a.attrelid = 'public.orders'::regclass
          and a.attname = 'delivery_latitude'
          and a.atttypid = 'double precision'::regtype
          and not a.attisdropped
    ) or not exists (
        select 1
        from pg_attribute as a
        where a.attrelid = 'public.orders'::regclass
          and a.attname = 'delivery_longitude'
          and a.atttypid = 'double precision'::regtype
          and not a.attisdropped
    ) then
        raise exception
            'Delivery coordinate columns already exist with incompatible types';
    end if;

    select pg_get_constraintdef(c.oid)
    into v_constraint_definition
    from pg_constraint as c
    where c.conrelid = 'public.orders'::regclass
      and c.conname = 'orders_delivery_coordinates_pair_check';

    if v_constraint_definition is null then
        alter table public.orders
            add constraint orders_delivery_coordinates_pair_check
            check (
                (
                    delivery_latitude is null
                    and delivery_longitude is null
                )
                or (
                    delivery_latitude is not null
                    and delivery_longitude is not null
                    and delivery_latitude between -90 and 90
                    and delivery_longitude between -180 and 180
                )
            ) not valid;
    elsif position('delivery_latitude' in v_constraint_definition) = 0
       or position('delivery_longitude' in v_constraint_definition) = 0 then
        raise exception
            'A conflicting orders_delivery_coordinates_pair_check constraint already exists; no functions were changed';
    end if;

    v_wrapper_oid := to_regprocedure(v_wrapper_signature);
    select count(*)
    into v_overload_count
    from pg_proc as p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'create_store_order_with_delivery_location';

    if v_overload_count > 1
       or (v_wrapper_oid is null and v_overload_count > 0) then
        raise exception
            'A conflicting create_store_order_with_delivery_location overload exists; no functions were changed';
    end if;

    if v_wrapper_oid is not null then
        select
            pg_get_functiondef(p.oid),
            p.proargnames[1:10],
            pg_get_function_result(p.oid)
        into
            v_wrapper_definition,
            v_wrapper_argument_names,
            v_wrapper_result
        from pg_proc as p
        where p.oid = v_wrapper_oid;

        if v_wrapper_argument_names is distinct from v_expected_argument_names
           or v_wrapper_result is distinct from v_expected_result
           or position(
                'delivery_latitude = p_delivery_latitude'
                in lower(v_wrapper_definition)
           ) = 0
           or position(
                'create_store_order_with_delivery('
                in lower(v_wrapper_definition)
           ) = 0
           or position(
                'security definer'
                in lower(v_wrapper_definition)
           ) = 0 then
            raise exception
                'The existing create_store_order_with_delivery_location function does not match this migration; it was not changed';
        end if;
    else
        execute $create$
            create function public.create_store_order_with_delivery_location(
                p_customer_id bigint,
                p_phone text,
                p_shipping_address text,
                p_payment_method text,
                p_notes text,
                p_items jsonb,
                p_promo_code text,
                p_delivery_distance_km numeric,
                p_delivery_latitude double precision,
                p_delivery_longitude double precision
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
            set search_path = public
            as $body$
            declare
                v_order_id bigint;
                v_order_no text;
                v_subtotal numeric;
                v_discount numeric;
                v_delivery_charge numeric;
                v_promo_code text;
                v_total_amount numeric;
            begin
                if p_delivery_latitude is null
                   or p_delivery_longitude is null
                   or p_delivery_latitude not between -90 and 90
                   or p_delivery_longitude not between -180 and 180 then
                    raise exception 'Invalid delivery coordinates';
                end if;

                select
                    result.order_id,
                    result.order_no,
                    result.subtotal,
                    result.discount,
                    result.delivery_charge,
                    result.promo_code,
                    result.total_amount
                into
                    v_order_id,
                    v_order_no,
                    v_subtotal,
                    v_discount,
                    v_delivery_charge,
                    v_promo_code,
                    v_total_amount
                from public.create_store_order_with_delivery(
                    p_customer_id,
                    p_phone,
                    p_shipping_address,
                    p_payment_method,
                    p_notes,
                    p_items,
                    p_promo_code,
                    p_delivery_distance_km
                ) as result;

                if v_order_id is null then
                    raise exception
                        'Route-priced checkout did not return an order';
                end if;

                update public.orders
                set
                    delivery_latitude = p_delivery_latitude,
                    delivery_longitude = p_delivery_longitude
                where id = v_order_id;

                if not found then
                    raise exception
                        'Could not save delivery coordinates for the order';
                end if;

                return query
                select
                    v_order_id,
                    v_order_no,
                    v_subtotal,
                    v_discount,
                    v_delivery_charge,
                    v_promo_code,
                    v_total_amount;
            end;
            $body$;
        $create$;
    end if;

    execute format(
        'revoke all on function %s from public, anon, authenticated',
        v_wrapper_signature
    );
    execute format(
        'grant execute on function %s to service_role',
        v_wrapper_signature
    );
end;
$migration$;

notify pgrst, 'reload schema';
