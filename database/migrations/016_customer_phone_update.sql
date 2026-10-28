-- Atomically keep the customer's phone number synchronized between
-- profiles and customers for account display and checkout autofill.
-- This migration does not alter or delete existing customer data.
do $migration$
declare
    v_function_oid oid;
    v_overload_count integer;
    v_function_definition text;
    v_function_argument_names text[];
    v_function_result text;
    v_signature constant text :=
        'public.update_store_customer_phone(uuid,text)';
    v_expected_argument_names constant text[] := array[
        'p_user_id',
        'p_phone'
    ];
begin
    if to_regclass('public.profiles') is null
       or to_regclass('public.customers') is null then
        raise exception
            'Required public.profiles or public.customers table is missing';
    end if;

    v_function_oid := to_regprocedure(v_signature);
    select count(*)
    into v_overload_count
    from pg_proc as p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'update_store_customer_phone';

    if v_overload_count > 1
       or (v_function_oid is null and v_overload_count > 0) then
        raise exception
            'A conflicting update_store_customer_phone function exists; it was not changed';
    end if;

    if v_function_oid is not null then
        select
            pg_get_functiondef(p.oid),
            p.proargnames[1:2],
            pg_get_function_result(p.oid)
        into
            v_function_definition,
            v_function_argument_names,
            v_function_result
        from pg_proc as p
        where p.oid = v_function_oid;

        if v_function_argument_names is distinct from v_expected_argument_names
           or v_function_result is distinct from 'boolean'
           or position('update public.profiles' in lower(v_function_definition)) = 0
           or position('update public.customers' in lower(v_function_definition)) = 0
           or position('security definer' in lower(v_function_definition)) = 0 then
            raise exception
                'The existing update_store_customer_phone function does not match this migration; it was not changed';
        end if;
    else
        execute $create$
            create function public.update_store_customer_phone(
                p_user_id uuid,
                p_phone text
            )
            returns boolean
            language plpgsql
            security definer
            set search_path = public
            as $body$
            declare
                v_phone text;
                v_updated_rows integer;
                v_profile_role text;
                v_profile_active boolean;
            begin
                v_phone := trim(coalesce(p_phone, ''));
                if length(v_phone) < 7 or length(v_phone) > 30 then
                    raise exception
                        'Phone number must be 7 to 30 characters';
                end if;

                select p.role::text, p.is_active
                into v_profile_role, v_profile_active
                from public.profiles as p
                where p.id = p_user_id
                for update;

                if not found
                   or v_profile_role <> 'customer'
                   or not v_profile_active then
                    raise exception
                        'Active customer profile not found';
                end if;

                perform 1
                from public.customers as c
                where c.user_id = p_user_id
                for update;

                if not found then
                    raise exception
                        'Customer account not found';
                end if;

                update public.profiles
                set phone = v_phone
                where id = p_user_id;

                get diagnostics v_updated_rows = row_count;
                if v_updated_rows <> 1 then
                    raise exception
                        'Could not update customer profile phone';
                end if;

                update public.customers
                set phone = v_phone
                where user_id = p_user_id;

                get diagnostics v_updated_rows = row_count;
                if v_updated_rows <> 1 then
                    raise exception
                        'Could not update customer account phone';
                end if;

                return true;
            end;
            $body$;
        $create$;
    end if;

    execute format(
        'revoke all on function %s from public, anon, authenticated',
        v_signature
    );
    execute format(
        'grant execute on function %s to service_role',
        v_signature
    );
end;
$migration$;

notify pgrst, 'reload schema';
