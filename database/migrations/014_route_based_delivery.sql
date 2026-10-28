-- Add route-priced checkout RPCs without changing or deleting the
-- existing checkout functions or any stored data.
--
-- Prerequisites:
--   - public.create_store_order(bigint, text, text, text, text, jsonb, text)
--   - public.preview_store_checkout(bigint, text, text, text, jsonb, text)
--
-- This migration is safe to rerun. Existing route-priced functions are
-- left unchanged after their signatures and pricing logic are validated.
do $migration$
declare
    v_create_source_oid oid;
    v_preview_source_oid oid;
    v_create_route_oid oid;
    v_preview_route_oid oid;
    v_create_source text;
    v_preview_source text;
    v_create_definition text;
    v_preview_definition text;
    v_original text;
    v_create_return_type oid;
    v_preview_return_type oid;
    v_existing_return_type oid;
    v_existing_argument_name text;
    v_existing_result text;
    v_overload_count integer;
    v_create_route_signature constant text :=
        'public.create_store_order_with_delivery(bigint,text,text,text,text,jsonb,text,numeric)';
    v_preview_route_signature constant text :=
        'public.preview_store_checkout_with_delivery(bigint,text,text,text,jsonb,text,numeric)';
begin
    v_create_source_oid := to_regprocedure(
        'public.create_store_order(bigint,text,text,text,text,jsonb,text)'
    );
    v_preview_source_oid := to_regprocedure(
        'public.preview_store_checkout(bigint,text,text,text,jsonb,text)'
    );

    if v_create_source_oid is null then
        raise exception
            'Required checkout function is missing: public.create_store_order(bigint, text, text, text, text, jsonb, text)'
            using hint =
                'Apply the checkout migrations, including 012_create_store_order_fixed.sql, before migration 014.';
    end if;

    if v_preview_source_oid is null then
        raise exception
            'Required preview function is missing: public.preview_store_checkout(bigint, text, text, text, jsonb, text)'
            using hint =
                'Apply preview_store_checkout.sql before migration 014.';
    end if;

    select p.prorettype
    into v_create_return_type
    from pg_proc as p
    where p.oid = v_create_source_oid;

    select p.prorettype
    into v_preview_return_type
    from pg_proc as p
    where p.oid = v_preview_source_oid;

    v_create_route_oid := to_regprocedure(v_create_route_signature);
    select count(*)
    into v_overload_count
    from pg_proc as p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'create_store_order_with_delivery';

    if v_overload_count > 1
       or (v_create_route_oid is null and v_overload_count > 0) then
        raise exception
            'A conflicting public.create_store_order_with_delivery overload already exists; no functions were changed';
    end if;

    v_preview_route_oid := to_regprocedure(v_preview_route_signature);
    select count(*)
    into v_overload_count
    from pg_proc as p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'preview_store_checkout_with_delivery';

    if v_overload_count > 1
       or (v_preview_route_oid is null and v_overload_count > 0) then
        raise exception
            'A conflicting public.preview_store_checkout_with_delivery overload already exists; no functions were changed';
    end if;

    if v_create_route_oid is not null then
        select
            p.prorettype,
            p.proargnames[8],
            pg_get_function_result(p.oid),
            pg_get_functiondef(p.oid)
        into
            v_existing_return_type,
            v_existing_argument_name,
            v_existing_result,
            v_create_definition
        from pg_proc as p
        where p.oid = v_create_route_oid;

        if v_existing_return_type <> v_create_return_type
           or v_existing_argument_name <> 'p_delivery_distance_km'
           or v_existing_result is distinct from
               pg_get_function_result(v_create_source_oid)
           or position(
               'p_delivery_distance_km * 50'
               in lower(v_create_definition)
           ) = 0
           or position('security definer' in lower(v_create_definition)) = 0 then
            raise exception
                'Existing public.create_store_order_with_delivery does not match the expected route-pricing definition; it was not changed';
        end if;
    end if;

    if v_preview_route_oid is not null then
        select
            p.prorettype,
            p.proargnames[7],
            pg_get_function_result(p.oid),
            pg_get_functiondef(p.oid)
        into
            v_existing_return_type,
            v_existing_argument_name,
            v_existing_result,
            v_preview_definition
        from pg_proc as p
        where p.oid = v_preview_route_oid;

        if v_existing_return_type <> v_preview_return_type
           or v_existing_argument_name <> 'p_delivery_distance_km'
           or v_existing_result is distinct from
               pg_get_function_result(v_preview_source_oid)
           or position(
               'p_delivery_distance_km * 50'
               in lower(v_preview_definition)
           ) = 0
           or position('security definer' in lower(v_preview_definition)) = 0 then
            raise exception
                'Existing public.preview_store_checkout_with_delivery does not match the expected route-pricing definition; it was not changed';
        end if;
    end if;

    if v_create_route_oid is null then
        v_create_source := pg_get_functiondef(v_create_source_oid);

        v_create_definition := regexp_replace(
            v_create_source,
            'public\.create_store_order[[:space:]]*[(]',
            'public.create_store_order_with_delivery(',
            'i'
        );
        if v_create_definition = v_create_source then
            raise exception
                'Could not safely prepare the route-priced checkout function; no functions were changed';
        end if;

        v_original := v_create_definition;
        v_create_definition := regexp_replace(
            v_create_definition,
            'p_promo_code[[:space:]]+text[[:space:]]+DEFAULT[[:space:]]+NULL::text',
            'p_promo_code text DEFAULT NULL::text, p_delivery_distance_km numeric DEFAULT 0',
            'i'
        );
        if v_create_definition = v_original then
            raise exception
                'Could not safely add the route-distance argument to checkout; no functions were changed';
        end if;

        v_original := v_create_definition;
        v_create_definition := regexp_replace(
            v_create_definition,
            'v_delivery_charge[[:space:]]*:=[[:space:]]*coalesce[[:space:]]*[(][[:space:]]*v_delivery_charge[[:space:]]*,[[:space:]]*100[[:space:]]*[)][[:space:]]*;',
            $route$
if p_delivery_distance_km is null or p_delivery_distance_km < 0 then
        raise exception 'Invalid delivery route distance';
    end if;

    v_delivery_charge := coalesce(v_delivery_charge, 100)
        + (p_delivery_distance_km * 50);
$route$,
            'i'
        );
        if v_create_definition = v_original then
            raise exception
                'Could not safely add route pricing to checkout; no functions were changed';
        end if;

        execute v_create_definition;
        v_create_route_oid := to_regprocedure(v_create_route_signature);
        if v_create_route_oid is null then
            raise exception
                'The route-priced checkout function was not created; all migration changes were rolled back';
        end if;
    end if;

    if v_preview_route_oid is null then
        v_preview_source := pg_get_functiondef(v_preview_source_oid);

        v_preview_definition := regexp_replace(
            v_preview_source,
            'public\.preview_store_checkout[[:space:]]*[(]',
            'public.preview_store_checkout_with_delivery(',
            'i'
        );
        if v_preview_definition = v_preview_source then
            raise exception
                'Could not safely prepare the route-priced preview function; no functions were changed';
        end if;

        v_original := v_preview_definition;
        v_preview_definition := regexp_replace(
            v_preview_definition,
            'p_promo_code[[:space:]]+text[[:space:]]+DEFAULT[[:space:]]+NULL::text',
            'p_promo_code text DEFAULT NULL::text, p_delivery_distance_km numeric DEFAULT 0',
            'i'
        );
        if v_preview_definition = v_original then
            raise exception
                'Could not safely add the route-distance argument to preview; no functions were changed';
        end if;

        v_original := v_preview_definition;
        v_preview_definition := regexp_replace(
            v_preview_definition,
            'v_base_delivery_charge[[:space:]]*:=[[:space:]]*coalesce[[:space:]]*[(][[:space:]]*v_base_delivery_charge[[:space:]]*,[[:space:]]*100[[:space:]]*[)][[:space:]]*;',
            $route$
if p_delivery_distance_km is null or p_delivery_distance_km < 0 then
        raise exception 'Invalid delivery route distance';
    end if;

    v_base_delivery_charge := coalesce(v_base_delivery_charge, 100)
        + (p_delivery_distance_km * 50);
$route$,
            'i'
        );

        if v_preview_definition = v_original then
            v_preview_definition := regexp_replace(
                v_preview_definition,
                'v_base_delivery_charge[[:space:]]*:=[[:space:]]*greatest[[:space:]]*[(][[:space:]]*coalesce[[:space:]]*[(][[:space:]]*v_base_delivery_charge[[:space:]]*,[[:space:]]*100[[:space:]]*[)][[:space:]]*,[[:space:]]*0[[:space:]]*[)][[:space:]]*;',
                $route$
if p_delivery_distance_km is null or p_delivery_distance_km < 0 then
        raise exception 'Invalid delivery route distance';
    end if;

    v_base_delivery_charge := greatest(
        coalesce(v_base_delivery_charge, 100),
        0
    ) + (p_delivery_distance_km * 50);
$route$,
                'i'
            );
        end if;

        if v_preview_definition = v_original then
            raise exception
                'Could not safely add route pricing to preview; no functions were changed';
        end if;

        execute v_preview_definition;
        v_preview_route_oid := to_regprocedure(v_preview_route_signature);
        if v_preview_route_oid is null then
            raise exception
                'The route-priced preview function was not created; all migration changes were rolled back';
        end if;
    end if;

    execute format(
        'revoke all on function %s from public, anon, authenticated',
        v_create_route_signature
    );
    execute format(
        'grant execute on function %s to service_role',
        v_create_route_signature
    );
    execute format(
        'revoke all on function %s from public, anon, authenticated',
        v_preview_route_signature
    );
    execute format(
        'grant execute on function %s to service_role',
        v_preview_route_signature
    );
end;
$migration$;

notify pgrst, 'reload schema';
