-- 1. Private schema for SECURITY DEFINER internals (not exposed through the API)
create schema if not exists private;
grant usage on schema private to authenticated, anon, service_role;

-- 2. Move SECURITY DEFINER functions out of the exposed `public` schema.
--    ALTER ... SET SCHEMA keeps the same OID, so RLS policies and triggers
--    that reference them keep working.
alter function public.has_role(uuid, public.app_role) set schema private;
alter function public.is_developer(uuid) set schema private;
alter function public.is_owner(uuid) set schema private;
alter function public.is_manager(uuid) set schema private;
alter function public.is_tenant(uuid) set schema private;
alter function public.current_tenant_id() set schema private;
alter function public.tenant_owns_unit(uuid) set schema private;
alter function public.tenant_owns_lease(uuid) set schema private;
alter function public.tenant_owns_building(uuid) set schema private;
alter function public.guard_user_roles() set schema private;
alter function public.validate_meter_reading() set schema private;
alter function public.prevent_last_developer_removal() set schema private;
alter function public.claim_invoice_number() set schema private;
alter function public.claim_developer_invite(uuid) set schema private;
alter function public.convert_inquiry_to_lease(uuid, uuid, date, numeric, numeric, integer, integer, uuid, text, text, text, text, date, text) set schema private;
alter function public.issue_invoice_for_charges(uuid[], date, text, numeric, boolean, jsonb, jsonb, jsonb, numeric, numeric, numeric, text, text) set schema private;
alter function public.analytics_summary(date, date) set schema private;

-- 3. Thin SECURITY INVOKER wrappers in `public` so application RPC calls and
--    existing function bodies keep resolving `public.<name>`.
create or replace function public.has_role(_user_id uuid, _role public.app_role)
returns boolean language sql stable security invoker set search_path = private, public
as $$ select private.has_role(_user_id, _role) $$;

create or replace function public.is_developer(_user_id uuid default auth.uid())
returns boolean language sql stable security invoker set search_path = private, public
as $$ select private.is_developer(_user_id) $$;

create or replace function public.is_owner(_user_id uuid default auth.uid())
returns boolean language sql stable security invoker set search_path = private, public
as $$ select private.is_owner(_user_id) $$;

create or replace function public.is_manager(_user_id uuid default auth.uid())
returns boolean language sql stable security invoker set search_path = private, public
as $$ select private.is_manager(_user_id) $$;

create or replace function public.is_tenant(_user_id uuid default auth.uid())
returns boolean language sql stable security invoker set search_path = private, public
as $$ select private.is_tenant(_user_id) $$;

create or replace function public.current_tenant_id()
returns uuid language sql stable security invoker set search_path = private, public
as $$ select private.current_tenant_id() $$;

create or replace function public.tenant_owns_unit(_unit_id uuid)
returns boolean language sql stable security invoker set search_path = private, public
as $$ select private.tenant_owns_unit(_unit_id) $$;

create or replace function public.tenant_owns_lease(_lease_id uuid)
returns boolean language sql stable security invoker set search_path = private, public
as $$ select private.tenant_owns_lease(_lease_id) $$;

create or replace function public.tenant_owns_building(_building_id uuid)
returns boolean language sql stable security invoker set search_path = private, public
as $$ select private.tenant_owns_building(_building_id) $$;

create or replace function public.claim_invoice_number()
returns table(series text, number integer) language sql security invoker set search_path = private, public
as $$ select * from private.claim_invoice_number() $$;

create or replace function public.claim_developer_invite(_invite_id uuid)
returns boolean language sql security invoker set search_path = private, public
as $$ select private.claim_developer_invite(_invite_id) $$;

create or replace function public.convert_inquiry_to_lease(
  _inquiry_id uuid, _unit_id uuid, _start_date date, _monthly_rent numeric,
  _deposit numeric, _payment_day integer, _notice_days integer,
  _tenant_id uuid default null, _first_name text default '', _last_name text default '',
  _phone text default '', _email text default '', _end_date date default null, _notes text default ''
) returns table(lease_id uuid, tenant_id uuid) language sql security invoker set search_path = private, public
as $$ select * from private.convert_inquiry_to_lease(_inquiry_id, _unit_id, _start_date, _monthly_rent,
  _deposit, _payment_day, _notice_days, _tenant_id, _first_name, _last_name, _phone, _email, _end_date, _notes) $$;

create or replace function public.issue_invoice_for_charges(
  _charge_ids uuid[], _issue_date date, _currency text, _vat_rate numeric, _is_vat_invoice boolean,
  _seller jsonb, _buyer jsonb, _line_items jsonb, _subtotal_net numeric, _vat_amount numeric,
  _total numeric, _notes text, _issued_by text
) returns table(invoice_id uuid, full_number text) language sql security invoker set search_path = private, public
as $$ select * from private.issue_invoice_for_charges(_charge_ids, _issue_date, _currency, _vat_rate,
  _is_vat_invoice, _seller, _buyer, _line_items, _subtotal_net, _vat_amount, _total, _notes, _issued_by) $$;

create or replace function public.analytics_summary(_from date, _to date)
returns jsonb language sql security invoker set search_path = private, public
as $$ select private.analytics_summary(_from, _to) $$;

revoke all on function public.has_role(uuid, public.app_role) from public;
revoke all on function public.is_developer(uuid) from public;
revoke all on function public.is_owner(uuid) from public;
revoke all on function public.is_manager(uuid) from public;
revoke all on function public.is_tenant(uuid) from public;
revoke all on function public.current_tenant_id() from public;
revoke all on function public.tenant_owns_unit(uuid) from public;
revoke all on function public.tenant_owns_lease(uuid) from public;
revoke all on function public.tenant_owns_building(uuid) from public;
revoke all on function public.claim_invoice_number() from public;
revoke all on function public.claim_developer_invite(uuid) from public;
revoke all on function public.convert_inquiry_to_lease(uuid, uuid, date, numeric, numeric, integer, integer, uuid, text, text, text, text, date, text) from public;
revoke all on function public.issue_invoice_for_charges(uuid[], date, text, numeric, boolean, jsonb, jsonb, jsonb, numeric, numeric, numeric, text, text) from public;
revoke all on function public.analytics_summary(date, date) from public;

grant execute on function public.has_role(uuid, public.app_role) to authenticated, service_role;
grant execute on function public.is_developer(uuid) to authenticated, service_role;
grant execute on function public.is_owner(uuid) to authenticated, service_role;
grant execute on function public.is_manager(uuid) to authenticated, service_role;
grant execute on function public.is_tenant(uuid) to authenticated, service_role;
grant execute on function public.current_tenant_id() to authenticated, service_role;
grant execute on function public.tenant_owns_unit(uuid) to authenticated, service_role;
grant execute on function public.tenant_owns_lease(uuid) to authenticated, service_role;
grant execute on function public.tenant_owns_building(uuid) to authenticated, service_role;
grant execute on function public.claim_invoice_number() to authenticated, service_role;
grant execute on function public.claim_developer_invite(uuid) to authenticated, service_role;
grant execute on function public.convert_inquiry_to_lease(uuid, uuid, date, numeric, numeric, integer, integer, uuid, text, text, text, text, date, text) to authenticated, service_role;
grant execute on function public.issue_invoice_for_charges(uuid[], date, text, numeric, boolean, jsonb, jsonb, jsonb, numeric, numeric, numeric, text, text) to authenticated, service_role;
grant execute on function public.analytics_summary(date, date) to authenticated, service_role;

-- 4. Replace the SECURITY DEFINER view with a SECURITY INVOKER view over a
--    private definer function, so no view in the exposed schema bypasses RLS.
create or replace function private.public_vacancies_rows()
returns table(
  id uuid, name text, unit_number text, description text, city text, address text,
  building_name text, area_m2 numeric, room_count integer, floor integer,
  monthly_rent numeric, deposit numeric, amenities jsonb, cover_image_url text,
  image_urls jsonb, available_from date, vacant_now boolean
)
language sql stable security definer set search_path = public
as $$
  select u.id, u.name, u.unit_number, u.description, u.city, u.address,
         b.name as building_name, u.area_m2, u.room_count, u.floor,
         u.monthly_rent, u.deposit, u.amenities, u.cover_image_url, u.image_urls,
         c.available_from, (u.status = 'vacant') as vacant_now
  from public.units u
  left join public.buildings b on b.id = u.building_id
  left join lateral (
    select l.end_date, l.renewal
    from public.leases l
    where l.unit_id = u.id
      and l.status in ('active','ending')
      and l.start_date <= current_date
      and (l.end_date is null or l.end_date >= current_date)
    order by l.end_date
    limit 1
  ) h on true
  cross join lateral public.unit_availability_calc(u.status, u.created_at::date, h.end_date, h.renewal, null::date)
    c(available_from, vacant_since, vacant_days)
  where u.is_active and u.is_listed and c.available_from is not null
    and not exists (
      select 1 from public.leases f
      where f.unit_id = u.id
        and f.status in ('draft','active','ending')
        and f.start_date > current_date
    )
$$;

revoke all on function private.public_vacancies_rows() from public;
grant execute on function private.public_vacancies_rows() to anon, authenticated, service_role;

drop view if exists public.public_vacancies;
create view public.public_vacancies with (security_invoker = true) as
  select * from private.public_vacancies_rows();

grant select on public.public_vacancies to anon, authenticated, service_role;