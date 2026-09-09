CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ============ 0. SHARED ============
CREATE OR REPLACE FUNCTION public.touch_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

CREATE TYPE public.app_role AS ENUM ('developer','owner','manager','tenant');

CREATE TABLE public.user_roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  role public.app_role NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, role)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_roles TO authenticated;
GRANT ALL ON public.user_roles TO service_role;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.has_role(_user_id uuid, _role public.app_role)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles ur
    WHERE ur.user_id = _user_id
      AND CASE _role
        WHEN 'developer' THEN ur.role = 'developer'
        WHEN 'owner'     THEN ur.role IN ('developer','owner')
        WHEN 'manager'   THEN ur.role IN ('developer','owner','manager')
        WHEN 'tenant'    THEN ur.role = 'tenant'
      END
  )
$$;
CREATE OR REPLACE FUNCTION public.is_developer(_user_id uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.has_role(_user_id, 'developer'::public.app_role)
$$;
CREATE OR REPLACE FUNCTION public.is_owner(_user_id uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.has_role(_user_id, 'owner'::public.app_role)
$$;
CREATE OR REPLACE FUNCTION public.is_manager(_user_id uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.has_role(_user_id, 'manager'::public.app_role)
$$;
CREATE OR REPLACE FUNCTION public.is_tenant(_user_id uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.has_role(_user_id, 'tenant'::public.app_role)
$$;
REVOKE ALL ON FUNCTION public.has_role(uuid, public.app_role) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.is_developer(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.is_owner(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.is_manager(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.is_tenant(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.has_role(uuid, public.app_role) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_developer(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_owner(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_manager(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_tenant(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.guard_user_roles()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  service boolean := coalesce(auth.role(), '') = 'service_role';
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') AND OLD.role = 'developer'
     AND NOT public.is_developer(auth.uid()) AND NOT service THEN
    RAISE EXCEPTION 'Developer accounts cannot be modified.';
  END IF;
  IF TG_OP IN ('INSERT','UPDATE') AND NEW.role = 'developer'
     AND NOT public.is_developer(auth.uid()) AND NOT service THEN
    RAISE EXCEPTION 'The developer role cannot be granted.';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER guard_user_roles_changes
BEFORE INSERT OR UPDATE OR DELETE ON public.user_roles
FOR EACH ROW EXECUTE FUNCTION public.guard_user_roles();

CREATE OR REPLACE FUNCTION public.prevent_last_developer_removal()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _remaining int;
BEGIN
  IF OLD.role <> 'developer' THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.role = 'developer' AND NEW.user_id = OLD.user_id THEN
    RETURN NEW;
  END IF;
  SELECT count(DISTINCT user_id) INTO _remaining
    FROM public.user_roles WHERE role = 'developer' AND id <> OLD.id;
  IF _remaining = 0 THEN
    RAISE EXCEPTION 'Cannot remove the last developer account.';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
CREATE TRIGGER prevent_last_developer_removal_trg
  BEFORE UPDATE OR DELETE ON public.user_roles
  FOR EACH ROW EXECUTE FUNCTION public.prevent_last_developer_removal();
REVOKE ALL ON FUNCTION public.prevent_last_developer_removal() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.guard_user_roles() FROM PUBLIC, anon;

CREATE POLICY "Owners read user_roles" ON public.user_roles
  FOR SELECT TO authenticated USING (public.is_owner(auth.uid()));
CREATE POLICY "Users read own roles" ON public.user_roles
  FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "Owners insert user_roles" ON public.user_roles
  FOR INSERT TO authenticated
  WITH CHECK (public.is_owner(auth.uid()) AND (role <> 'developer' OR public.is_developer(auth.uid())));
CREATE POLICY "Owners update user_roles" ON public.user_roles
  FOR UPDATE TO authenticated
  USING (public.is_owner(auth.uid()) AND (role <> 'developer' OR user_id = auth.uid()))
  WITH CHECK (public.is_owner(auth.uid()) AND (role <> 'developer' OR public.is_developer(auth.uid())));
CREATE POLICY "Owners delete user_roles" ON public.user_roles
  FOR DELETE TO authenticated
  USING (public.is_owner(auth.uid()) AND (role <> 'developer' OR user_id = auth.uid()));

-- ============ 1. PLATFORM TABLES ============
CREATE TABLE public.page_views (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  path text NOT NULL DEFAULT '',
  referrer text NOT NULL DEFAULT '',
  session_id text NOT NULL DEFAULT '',
  user_agent text NOT NULL DEFAULT '',
  country text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT INSERT ON public.page_views TO anon, authenticated;
GRANT SELECT ON public.page_views TO authenticated;
GRANT ALL ON public.page_views TO service_role;
ALTER TABLE public.page_views ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone logs a page view" ON public.page_views
  FOR INSERT TO anon, authenticated WITH CHECK (true);
CREATE POLICY "Owners read page_views" ON public.page_views
  FOR SELECT TO authenticated USING (public.is_owner(auth.uid()));
CREATE INDEX page_views_created_idx ON public.page_views (created_at DESC);

CREATE TABLE public.app_secrets (
  key text PRIMARY KEY,
  value text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT ALL ON public.app_secrets TO service_role;
ALTER TABLE public.app_secrets ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.api_clients (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  key_hash text NOT NULL,
  key_prefix text NOT NULL,
  allowed_origins text[] NOT NULL DEFAULT '{}',
  is_active boolean NOT NULL DEFAULT true,
  last_used_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.api_clients TO authenticated;
GRANT ALL ON public.api_clients TO service_role;
ALTER TABLE public.api_clients ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER api_clients_touch BEFORE UPDATE ON public.api_clients
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
CREATE POLICY "Owners manage api_clients" ON public.api_clients
  FOR ALL TO authenticated USING (public.is_owner(auth.uid())) WITH CHECK (public.is_owner(auth.uid()));

CREATE TABLE public.api_request_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  api_client_id uuid REFERENCES public.api_clients(id) ON DELETE SET NULL,
  ip text NOT NULL DEFAULT '',
  path text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.api_request_log TO authenticated;
GRANT ALL ON public.api_request_log TO service_role;
ALTER TABLE public.api_request_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Owners read api_request_log" ON public.api_request_log
  FOR SELECT TO authenticated USING (public.is_owner(auth.uid()));
CREATE INDEX api_request_log_ip_created_idx ON public.api_request_log (ip, created_at DESC);

CREATE TABLE public.content_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  template_name text NOT NULL UNIQUE,
  category text NOT NULL DEFAULT 'general',
  subject text NOT NULL DEFAULT '',
  content text NOT NULL DEFAULT '',
  fields jsonb NOT NULL DEFAULT '[]'::jsonb,
  is_enabled boolean NOT NULL DEFAULT true,
  updated_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.content_templates TO authenticated;
GRANT ALL ON public.content_templates TO service_role;
ALTER TABLE public.content_templates ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER content_templates_touch BEFORE UPDATE ON public.content_templates
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
CREATE POLICY "Owners manage content_templates" ON public.content_templates
  FOR ALL TO authenticated USING (public.is_owner(auth.uid())) WITH CHECK (public.is_owner(auth.uid()));
CREATE POLICY "Managers read content_templates" ON public.content_templates
  FOR SELECT TO authenticated USING (public.is_manager(auth.uid()));

CREATE TABLE public.content_translations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type text NOT NULL,
  entity_id text NOT NULL,
  field text NOT NULL,
  lang text NOT NULL,
  value text NOT NULL DEFAULT '',
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (entity_type, entity_id, field, lang)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.content_translations TO authenticated;
GRANT ALL ON public.content_translations TO service_role;
ALTER TABLE public.content_translations ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER content_translations_touch BEFORE UPDATE ON public.content_translations
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
CREATE POLICY "Owners manage content_translations" ON public.content_translations
  FOR ALL TO authenticated USING (public.is_owner(auth.uid())) WITH CHECK (public.is_owner(auth.uid()));
CREATE POLICY "Managers read content_translations" ON public.content_translations
  FOR SELECT TO authenticated USING (public.is_manager(auth.uid()));

CREATE TABLE public.contract_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  kind text NOT NULL DEFAULT 'lease',
  language text NOT NULL DEFAULT 'lt',
  content text NOT NULL DEFAULT '',
  is_active boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT contract_templates_kind_check CHECK (kind IN ('rental','privacy','lease'))
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.contract_templates TO authenticated;
GRANT ALL ON public.contract_templates TO service_role;
ALTER TABLE public.contract_templates ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER contract_templates_touch BEFORE UPDATE ON public.contract_templates
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
CREATE UNIQUE INDEX contract_templates_one_active
  ON public.contract_templates (kind, language) WHERE is_active;
CREATE POLICY "Owners manage contract_templates" ON public.contract_templates
  FOR ALL TO authenticated USING (public.is_owner(auth.uid())) WITH CHECK (public.is_owner(auth.uid()));
CREATE POLICY "Managers read contract templates" ON public.contract_templates
  FOR SELECT TO authenticated USING (public.is_manager(auth.uid()));

-- ============ 2. BUILDINGS + UNITS ============
CREATE TABLE public.buildings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  address text NOT NULL DEFAULT '',
  city text NOT NULL DEFAULT '',
  postal_code text NOT NULL DEFAULT '',
  country text NOT NULL DEFAULT 'LT',
  kind text NOT NULL DEFAULT 'apartment_building'
    CHECK (kind IN ('apartment_building','dormitory','house','other')),
  lat numeric, lng numeric,
  notes text NOT NULL DEFAULT '',
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.buildings TO authenticated;
GRANT ALL ON public.buildings TO service_role;
ALTER TABLE public.buildings ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER buildings_touch BEFORE UPDATE ON public.buildings
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE public.units (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  building_id uuid REFERENCES public.buildings(id) ON DELETE SET NULL,
  name text NOT NULL DEFAULT '',
  unit_number text NOT NULL DEFAULT '',
  description text NOT NULL DEFAULT '',
  address text NOT NULL DEFAULT '',
  city text NOT NULL DEFAULT '',
  country text NOT NULL DEFAULT 'LT',
  location_note text NOT NULL DEFAULT '',
  lat numeric, lng numeric,
  area_m2 numeric,
  floor integer,
  room_count integer NOT NULL DEFAULT 1,
  monthly_rent numeric(10,2) NOT NULL DEFAULT 0,
  deposit numeric(10,2) NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'vacant'
    CHECK (status IN ('vacant','occupied','reserved','renovation','inactive')),
  amenities jsonb NOT NULL DEFAULT '[]'::jsonb,
  features jsonb NOT NULL DEFAULT '[]'::jsonb,
  cover_image_url text NOT NULL DEFAULT '',
  image_urls jsonb NOT NULL DEFAULT '[]'::jsonb,
  is_active boolean NOT NULL DEFAULT true,
  is_listed boolean NOT NULL DEFAULT false,
  sort_order integer NOT NULL DEFAULT 0,
  notes text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.units TO authenticated;
GRANT ALL ON public.units TO service_role;
ALTER TABLE public.units ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER units_touch BEFORE UPDATE ON public.units
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
CREATE INDEX idx_units_building ON public.units(building_id);
CREATE INDEX idx_units_status ON public.units(status);

CREATE TABLE public.unit_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  unit_id uuid NOT NULL REFERENCES public.units(id) ON DELETE CASCADE,
  kind text NOT NULL DEFAULT 'other'
    CHECK (kind IN ('occupied','vacated','renovation','inspection','other')),
  started_at date NOT NULL DEFAULT CURRENT_DATE,
  ended_at date,
  cost numeric(10,2),
  note text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.unit_events TO authenticated;
GRANT ALL ON public.unit_events TO service_role;
ALTER TABLE public.unit_events ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER unit_events_touch BEFORE UPDATE ON public.unit_events
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE public.property_investments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  unit_id uuid NOT NULL REFERENCES public.units(id) ON DELETE CASCADE,
  category text NOT NULL DEFAULT 'other',
  amount numeric(10,2) NOT NULL DEFAULT 0,
  purchase_date date NOT NULL DEFAULT CURRENT_DATE,
  note text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.property_investments TO authenticated;
GRANT ALL ON public.property_investments TO service_role;
ALTER TABLE public.property_investments ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER property_investments_touch BEFORE UPDATE ON public.property_investments
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE public.property_maintenance (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  unit_id uuid NOT NULL REFERENCES public.units(id) ON DELETE CASCADE,
  type text NOT NULL DEFAULT 'other',
  due_date date,
  last_done_at date,
  note text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.property_maintenance TO authenticated;
GRANT ALL ON public.property_maintenance TO service_role;
ALTER TABLE public.property_maintenance ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER property_maintenance_touch BEFORE UPDATE ON public.property_maintenance
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE public.expenses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  unit_id uuid REFERENCES public.units(id) ON DELETE SET NULL,
  category text NOT NULL DEFAULT 'other',
  amount numeric(10,2) NOT NULL DEFAULT 0,
  expense_date date NOT NULL DEFAULT CURRENT_DATE,
  note text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.expenses TO authenticated;
GRANT ALL ON public.expenses TO service_role;
ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER expenses_touch BEFORE UPDATE ON public.expenses
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- ============ 3. TENANTS + LEASES ============
CREATE TABLE public.tenants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  first_name text NOT NULL DEFAULT '',
  last_name text NOT NULL DEFAULT '',
  phone text NOT NULL DEFAULT '',
  email text NOT NULL DEFAULT '',
  notes text NOT NULL DEFAULT '',
  user_id uuid UNIQUE,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.tenants TO authenticated;
GRANT ALL ON public.tenants TO service_role;
ALTER TABLE public.tenants ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER tenants_touch BEFORE UPDATE ON public.tenants
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE public.tenant_identity (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL UNIQUE REFERENCES public.tenants(id) ON DELETE CASCADE,
  personal_code text NOT NULL DEFAULT '',
  id_doc_type text NOT NULL DEFAULT '',
  id_doc_number text NOT NULL DEFAULT '',
  issued_by text NOT NULL DEFAULT '',
  valid_until date,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.tenant_identity TO authenticated;
GRANT ALL ON public.tenant_identity TO service_role;
ALTER TABLE public.tenant_identity ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER tenant_identity_touch BEFORE UPDATE ON public.tenant_identity
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE public.leases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  unit_id uuid NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
  tenant_id uuid NOT NULL REFERENCES public.tenants(id) ON DELETE RESTRICT,
  start_date date NOT NULL,
  end_date date,
  monthly_rent numeric(10,2) NOT NULL DEFAULT 0,
  deposit numeric(10,2) NOT NULL DEFAULT 0,
  deposit_paid numeric(10,2) NOT NULL DEFAULT 0,
  payment_day integer NOT NULL DEFAULT 10 CHECK (payment_day BETWEEN 1 AND 28),
  notice_days integer NOT NULL DEFAULT 30,
  status text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft','active','ending','expired','terminated')),
  renewal boolean NOT NULL DEFAULT true,
  terminated_at timestamptz,
  termination_reason text NOT NULL DEFAULT '',
  notes text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT leases_dates_check CHECK (end_date IS NULL OR end_date >= start_date),
  CONSTRAINT leases_no_overlap EXCLUDE USING gist (
    unit_id WITH =,
    daterange(start_date, COALESCE(end_date, 'infinity'::date), '[]') WITH &&
  ) WHERE (status <> 'terminated')
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.leases TO authenticated;
GRANT ALL ON public.leases TO service_role;
ALTER TABLE public.leases ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER leases_touch BEFORE UPDATE ON public.leases
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
CREATE INDEX idx_leases_unit ON public.leases(unit_id);
CREATE INDEX idx_leases_tenant ON public.leases(tenant_id);

CREATE TABLE public.lease_occupants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lease_id uuid NOT NULL REFERENCES public.leases(id) ON DELETE CASCADE,
  tenant_id uuid REFERENCES public.tenants(id) ON DELETE SET NULL,
  full_name text NOT NULL DEFAULT '',
  phone text NOT NULL DEFAULT '',
  email text NOT NULL DEFAULT '',
  relation text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.lease_occupants TO authenticated;
GRANT ALL ON public.lease_occupants TO service_role;
ALTER TABLE public.lease_occupants ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER lease_occupants_touch BEFORE UPDATE ON public.lease_occupants
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE public.documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  unit_id uuid REFERENCES public.units(id) ON DELETE CASCADE,
  lease_id uuid REFERENCES public.leases(id) ON DELETE CASCADE,
  tenant_id uuid REFERENCES public.tenants(id) ON DELETE CASCADE,
  bucket text NOT NULL DEFAULT 'documents',
  title text NOT NULL DEFAULT '',
  kind text NOT NULL DEFAULT 'other',
  file_path text NOT NULL DEFAULT '',
  mime_type text NOT NULL DEFAULT '',
  size_bytes bigint NOT NULL DEFAULT 0,
  expires_at date,
  uploaded_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT documents_kind_check CHECK (kind IN ('lease_contract','act','id_document','invoice','insurance','inspection','house_rules','other')),
  CONSTRAINT documents_attached_check CHECK (unit_id IS NOT NULL OR lease_id IS NOT NULL OR tenant_id IS NOT NULL)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.documents TO authenticated;
GRANT ALL ON public.documents TO service_role;
ALTER TABLE public.documents ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER documents_touch BEFORE UPDATE ON public.documents
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- ============ 4. METERS ============
CREATE TABLE public.meters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  unit_id uuid REFERENCES public.units(id) ON DELETE CASCADE,
  building_id uuid REFERENCES public.buildings(id) ON DELETE CASCADE,
  type text NOT NULL
    CHECK (type IN ('electricity_day','electricity_night','cold_water','hot_water','gas','heating')),
  serial_number text NOT NULL DEFAULT '',
  uom text NOT NULL DEFAULT 'kWh',
  initial_reading numeric(12,3) NOT NULL DEFAULT 0,
  digits integer,
  is_active boolean NOT NULL DEFAULT true,
  notes text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT meters_owner_check CHECK (num_nonnulls(unit_id, building_id) = 1)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.meters TO authenticated;
GRANT ALL ON public.meters TO service_role;
ALTER TABLE public.meters ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER meters_touch BEFORE UPDATE ON public.meters
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE public.meter_readings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  meter_id uuid NOT NULL REFERENCES public.meters(id) ON DELETE CASCADE,
  period date NOT NULL,
  value numeric(12,3) NOT NULL,
  consumption numeric(12,3) NOT NULL DEFAULT 0,
  photo_path text NOT NULL DEFAULT '',
  submitted_by uuid,
  submitted_at timestamptz NOT NULL DEFAULT now(),
  status text NOT NULL DEFAULT 'submitted'
    CHECK (status IN ('submitted','approved','rejected')),
  needs_review boolean NOT NULL DEFAULT false,
  reviewed_by uuid,
  reviewed_at timestamptz,
  note text NOT NULL DEFAULT '',
  superseded_by uuid REFERENCES public.meter_readings(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT meter_readings_period_check CHECK (period = date_trunc('month', period)::date)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.meter_readings TO authenticated;
GRANT ALL ON public.meter_readings TO service_role;
ALTER TABLE public.meter_readings ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER meter_readings_touch BEFORE UPDATE ON public.meter_readings
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
CREATE UNIQUE INDEX meter_readings_one_per_period
  ON public.meter_readings(meter_id, period) WHERE status <> 'rejected';

CREATE OR REPLACE FUNCTION public.validate_meter_reading()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  baseline numeric(12,3);
  prev_consumption numeric(12,3);
BEGIN
  IF NEW.status = 'rejected' THEN
    RETURN NEW;
  END IF;

  SELECT r.value INTO baseline
  FROM public.meter_readings r
  WHERE r.meter_id = NEW.meter_id
    AND r.status = 'approved'
    AND r.period < NEW.period
    AND (TG_OP = 'INSERT' OR r.id <> NEW.id)
  ORDER BY r.period DESC
  LIMIT 1;

  IF baseline IS NULL THEN
    SELECT m.initial_reading INTO baseline FROM public.meters m WHERE m.id = NEW.meter_id;
  END IF;
  baseline := COALESCE(baseline, 0);

  IF NEW.value < baseline THEN
    RAISE EXCEPTION 'Rodmuo (%) negali buti mazesnis uz ankstesni patvirtinta rodmeni (%).', NEW.value, baseline;
  END IF;

  NEW.consumption := NEW.value - baseline;

  SELECT r.consumption INTO prev_consumption
  FROM public.meter_readings r
  WHERE r.meter_id = NEW.meter_id
    AND r.status = 'approved'
    AND r.period < NEW.period
    AND (TG_OP = 'INSERT' OR r.id <> NEW.id)
  ORDER BY r.period DESC
  LIMIT 1;

  NEW.needs_review := prev_consumption IS NOT NULL
    AND prev_consumption > 0
    AND NEW.consumption > prev_consumption * 5;

  RETURN NEW;
END;
$$;
CREATE TRIGGER meter_readings_validate
  BEFORE INSERT OR UPDATE OF value, status, period ON public.meter_readings
  FOR EACH ROW EXECUTE FUNCTION public.validate_meter_reading();
REVOKE EXECUTE ON FUNCTION public.validate_meter_reading() FROM PUBLIC, anon;

CREATE TABLE public.utility_rates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type text NOT NULL
    CHECK (type IN ('electricity_day','electricity_night','cold_water','hot_water','gas','heating')),
  effective_from date NOT NULL,
  price_per_unit numeric(10,4) NOT NULL DEFAULT 0,
  fixed_monthly numeric(10,2) NOT NULL DEFAULT 0,
  note text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (type, effective_from)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.utility_rates TO authenticated;
GRANT ALL ON public.utility_rates TO service_role;
ALTER TABLE public.utility_rates ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER utility_rates_touch BEFORE UPDATE ON public.utility_rates
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- ============ 5. MONEY ============
CREATE TABLE public.invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lease_id uuid REFERENCES public.leases(id) ON DELETE SET NULL,
  invoice_series text NOT NULL DEFAULT '',
  invoice_number integer NOT NULL,
  full_number text NOT NULL,
  issue_date date NOT NULL DEFAULT CURRENT_DATE,
  currency text NOT NULL DEFAULT 'EUR',
  vat_rate numeric NOT NULL DEFAULT 21,
  is_vat_invoice boolean NOT NULL DEFAULT false,
  seller jsonb NOT NULL DEFAULT '{}'::jsonb,
  buyer jsonb NOT NULL DEFAULT '{}'::jsonb,
  line_items jsonb NOT NULL DEFAULT '[]'::jsonb,
  subtotal_net numeric(10,2) NOT NULL DEFAULT 0,
  vat_amount numeric(10,2) NOT NULL DEFAULT 0,
  total numeric(10,2) NOT NULL DEFAULT 0,
  notes text NOT NULL DEFAULT '',
  issued_by text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.invoices TO authenticated;
GRANT ALL ON public.invoices TO service_role;
ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;
CREATE INDEX invoices_lease_id_idx ON public.invoices (lease_id);
CREATE INDEX invoices_issue_date_idx ON public.invoices (issue_date DESC);
CREATE UNIQUE INDEX invoices_full_number_idx ON public.invoices (full_number);

CREATE TABLE public.charges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lease_id uuid NOT NULL REFERENCES public.leases(id) ON DELETE CASCADE,
  period date NOT NULL,
  kind text NOT NULL CHECK (kind IN ('rent','utility','fixed','one_off','penalty')),
  meter_reading_id uuid REFERENCES public.meter_readings(id) ON DELETE SET NULL,
  utility_rate_id uuid REFERENCES public.utility_rates(id) ON DELETE SET NULL,
  description text NOT NULL DEFAULT '',
  quantity numeric(12,3) NOT NULL DEFAULT 1,
  unit_price numeric(10,4) NOT NULL DEFAULT 0,
  amount numeric(10,2) NOT NULL DEFAULT 0,
  invoice_id uuid REFERENCES public.invoices(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.charges TO authenticated;
GRANT ALL ON public.charges TO service_role;
ALTER TABLE public.charges ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER charges_touch BEFORE UPDATE ON public.charges
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
CREATE UNIQUE INDEX charges_one_rent_per_lease_period
  ON public.charges (lease_id, period) WHERE kind = 'rent';
CREATE UNIQUE INDEX charges_one_utility_per_reading
  ON public.charges (meter_reading_id, lease_id) WHERE meter_reading_id IS NOT NULL;
CREATE UNIQUE INDEX charges_one_fixed_per_lease_period_rate
  ON public.charges (lease_id, period, utility_rate_id) WHERE kind = 'fixed';

CREATE TABLE public.payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lease_id uuid NOT NULL REFERENCES public.leases(id) ON DELETE CASCADE,
  paid_at date NOT NULL DEFAULT CURRENT_DATE,
  amount numeric(10,2) NOT NULL,
  method text NOT NULL DEFAULT 'bank' CHECK (method IN ('bank','cash','other')),
  reference text NOT NULL DEFAULT '',
  note text NOT NULL DEFAULT '',
  recorded_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.payments TO authenticated;
GRANT ALL ON public.payments TO service_role;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER payments_touch BEFORE UPDATE ON public.payments
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- ============ 6. ISSUES ============
CREATE TABLE public.issues (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  unit_id uuid NOT NULL REFERENCES public.units(id) ON DELETE CASCADE,
  lease_id uuid REFERENCES public.leases(id) ON DELETE SET NULL,
  reported_by uuid,
  reporter_name text NOT NULL DEFAULT '',
  category text NOT NULL DEFAULT 'other',
  title text NOT NULL,
  description text NOT NULL DEFAULT '',
  photo_paths jsonb NOT NULL DEFAULT '[]'::jsonb,
  priority text NOT NULL DEFAULT 'normal' CHECK (priority IN ('low','normal','high','urgent')),
  status text NOT NULL DEFAULT 'new'
    CHECK (status IN ('new','acknowledged','in_progress','waiting','resolved','rejected')),
  assigned_to uuid,
  cost numeric(10,2),
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.issues TO authenticated;
GRANT ALL ON public.issues TO service_role;
ALTER TABLE public.issues ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER issues_touch BEFORE UPDATE ON public.issues
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE public.issue_comments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  issue_id uuid NOT NULL REFERENCES public.issues(id) ON DELETE CASCADE,
  author_id uuid,
  author_role text NOT NULL DEFAULT '',
  body text NOT NULL,
  photo_paths jsonb NOT NULL DEFAULT '[]'::jsonb,
  is_internal boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.issue_comments TO authenticated;
GRANT ALL ON public.issue_comments TO service_role;
ALTER TABLE public.issue_comments ENABLE ROW LEVEL SECURITY;

-- ============ 7. RENTAL INQUIRIES ============
CREATE TABLE public.rental_inquiries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  unit_id uuid REFERENCES public.units(id) ON DELETE SET NULL,
  name text NOT NULL,
  phone text NOT NULL DEFAULT '',
  email text NOT NULL DEFAULT '',
  move_in_date date,
  message text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'new'
    CHECK (status IN ('new','contacted','viewing_scheduled','converted','dismissed')),
  handled_by uuid,
  converted_lease_id uuid REFERENCES public.leases(id) ON DELETE SET NULL,
  source text NOT NULL DEFAULT 'public_site',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.rental_inquiries TO authenticated;
GRANT INSERT ON public.rental_inquiries TO anon;
GRANT ALL ON public.rental_inquiries TO service_role;
ALTER TABLE public.rental_inquiries ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER rental_inquiries_touch BEFORE UPDATE ON public.rental_inquiries
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

-- ============ 8. ORG SETTINGS ============
CREATE TABLE public.org_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  singleton boolean NOT NULL DEFAULT true UNIQUE CHECK (singleton),
  display_name text,
  tagline text NOT NULL DEFAULT 'Ilgalaikė nuoma',
  address text, city text, postal_code text, country text NOT NULL DEFAULT 'LT',
  lat numeric, lng numeric,
  timezone text NOT NULL DEFAULT 'Europe/Vilnius',
  currency text NOT NULL DEFAULT 'EUR',
  default_language text NOT NULL DEFAULT 'lt',
  phone text, email text,
  vat_rate numeric NOT NULL DEFAULT 21,
  payment_methods jsonb NOT NULL DEFAULT '["bank"]'::jsonb,
  payment_due_day integer NOT NULL DEFAULT 10,
  default_notice_days integer NOT NULL DEFAULT 30,
  reading_window_from_day integer NOT NULL DEFAULT 25,
  reading_window_to_day integer NOT NULL DEFAULT 5,
  require_meter_photo boolean NOT NULL DEFAULT true,
  invoice_series text,
  invoice_next_number integer NOT NULL DEFAULT 1,
  invoice_issuer_name text NOT NULL DEFAULT '',
  invoice_logo_url text,
  invoice_notes text,
  company_name text, company_code text, company_vat_code text, company_address text,
  iban text, bank_name text,
  brand_primary_color text NOT NULL DEFAULT '#1f2937',
  brand_secondary_color text NOT NULL DEFAULT '#6b7280',
  brand_logo_url text, brand_email_logo_url text, brand_pdf_logo_url text,
  notify_reading_reminder boolean NOT NULL DEFAULT true,
  notify_lease_expiring boolean NOT NULL DEFAULT true,
  notify_payment_overdue boolean NOT NULL DEFAULT true,
  notify_issue_update boolean NOT NULL DEFAULT true,
  notify_new_inquiry boolean NOT NULL DEFAULT true,
  integrations jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.org_settings TO authenticated;
GRANT ALL ON public.org_settings TO service_role;
ALTER TABLE public.org_settings ENABLE ROW LEVEL SECURITY;
CREATE TRIGGER org_settings_touch BEFORE UPDATE ON public.org_settings
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();
INSERT INTO public.org_settings (singleton) VALUES (true);

-- ============ 9. DEVELOPER INVITES ============
CREATE TABLE public.developer_invites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL,
  full_name text NOT NULL DEFAULT '',
  proposed_by uuid NOT NULL,
  status text NOT NULL DEFAULT 'pending',
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '14 days'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT developer_invites_status_check CHECK (status IN ('pending','approved','rejected','expired'))
);
CREATE UNIQUE INDEX developer_invites_one_pending_per_email
  ON public.developer_invites (lower(email)) WHERE status = 'pending';
GRANT SELECT, INSERT, UPDATE ON public.developer_invites TO authenticated;
GRANT ALL ON public.developer_invites TO service_role;
ALTER TABLE public.developer_invites ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Developers read developer_invites" ON public.developer_invites
  FOR SELECT TO authenticated USING (public.is_developer(auth.uid()));
CREATE POLICY "Developers create developer_invites" ON public.developer_invites
  FOR INSERT TO authenticated WITH CHECK (public.is_developer(auth.uid()) AND proposed_by = auth.uid());
CREATE POLICY "Developers update developer_invites" ON public.developer_invites
  FOR UPDATE TO authenticated USING (public.is_developer(auth.uid())) WITH CHECK (public.is_developer(auth.uid()));
CREATE TRIGGER update_developer_invites_updated_at
  BEFORE UPDATE ON public.developer_invites
  FOR EACH ROW EXECUTE FUNCTION public.touch_updated_at();

CREATE TABLE public.developer_invite_approvals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invite_id uuid NOT NULL REFERENCES public.developer_invites(id) ON DELETE CASCADE,
  approver_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (invite_id, approver_id)
);
GRANT SELECT, INSERT ON public.developer_invite_approvals TO authenticated;
GRANT ALL ON public.developer_invite_approvals TO service_role;
ALTER TABLE public.developer_invite_approvals ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Developers read invite approvals" ON public.developer_invite_approvals
  FOR SELECT TO authenticated USING (public.is_developer(auth.uid()));
CREATE POLICY "Developers approve invites" ON public.developer_invite_approvals
  FOR INSERT TO authenticated WITH CHECK (public.is_developer(auth.uid()) AND approver_id = auth.uid());

CREATE OR REPLACE FUNCTION public.claim_developer_invite(_invite_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _inv public.developer_invites;
  _devs int;
  _approvals int;
BEGIN
  IF NOT public.is_developer(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;

  SELECT * INTO _inv FROM public.developer_invites WHERE id = _invite_id FOR UPDATE;
  IF _inv.id IS NULL OR _inv.status <> 'pending' THEN
    RETURN false;
  END IF;
  IF _inv.expires_at < now() THEN
    UPDATE public.developer_invites SET status = 'expired' WHERE id = _invite_id;
    RETURN false;
  END IF;

  SELECT count(DISTINCT user_id) INTO _devs FROM public.user_roles WHERE role = 'developer';
  SELECT count(*) INTO _approvals
    FROM public.developer_invite_approvals a
    JOIN public.user_roles ur ON ur.user_id = a.approver_id AND ur.role = 'developer'
    WHERE a.invite_id = _invite_id;

  IF _approvals >= _devs THEN
    UPDATE public.developer_invites SET status = 'approved' WHERE id = _invite_id;
    RETURN true;
  END IF;
  RETURN false;
END;
$$;
REVOKE ALL ON FUNCTION public.claim_developer_invite(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_developer_invite(uuid) TO authenticated, service_role;

-- ============ 10. FUNCTIONS ============
CREATE OR REPLACE FUNCTION public.claim_invoice_number()
RETURNS TABLE(series text, number integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_series text;
  v_number integer;
BEGIN
  UPDATE public.org_settings
  SET invoice_next_number = invoice_next_number + 1
  WHERE singleton
  RETURNING invoice_series, invoice_next_number - 1 INTO v_series, v_number;

  IF v_number IS NULL THEN
    RAISE EXCEPTION 'org_settings eilute nerasta.';
  END IF;

  RETURN QUERY SELECT v_series, v_number;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.claim_invoice_number() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_invoice_number() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.current_tenant_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT t.id FROM public.tenants t WHERE t.user_id = auth.uid() LIMIT 1
$$;
CREATE OR REPLACE FUNCTION public.tenant_owns_lease(_lease_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.leases l
    WHERE l.id = _lease_id
      AND l.tenant_id = public.current_tenant_id()
      AND l.status IN ('active','ending')
  )
$$;
CREATE OR REPLACE FUNCTION public.tenant_owns_unit(_unit_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.leases l
    WHERE l.unit_id = _unit_id
      AND l.tenant_id = public.current_tenant_id()
      AND l.status IN ('active','ending')
  )
$$;
CREATE OR REPLACE FUNCTION public.tenant_owns_building(_building_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.leases l
    JOIN public.units u ON u.id = l.unit_id
    WHERE u.building_id = _building_id
      AND l.tenant_id = public.current_tenant_id()
      AND l.status IN ('active','ending')
  )
$$;
COMMENT ON FUNCTION public.tenant_owns_lease(uuid) IS
  'v1: true only for the PRIMARY tenant (leases.tenant_id) on an active/ending lease. lease_occupants are intentionally not covered.';
COMMENT ON FUNCTION public.tenant_owns_unit(uuid) IS
  'v1: true only for the PRIMARY tenant (leases.tenant_id) holding the unit via an active/ending lease. lease_occupants are intentionally not covered.';
REVOKE EXECUTE ON FUNCTION public.current_tenant_id() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.tenant_owns_lease(uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.tenant_owns_unit(uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.tenant_owns_building(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.current_tenant_id() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.tenant_owns_lease(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.tenant_owns_unit(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.tenant_owns_building(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.convert_inquiry_to_lease(
  _inquiry_id uuid,
  _unit_id uuid,
  _start_date date,
  _monthly_rent numeric,
  _deposit numeric,
  _payment_day integer,
  _notice_days integer,
  _tenant_id uuid DEFAULT NULL,
  _first_name text DEFAULT '',
  _last_name text DEFAULT '',
  _phone text DEFAULT '',
  _email text DEFAULT '',
  _end_date date DEFAULT NULL,
  _notes text DEFAULT ''
)
RETURNS TABLE (lease_id uuid, tenant_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_tenant uuid;
  v_lease uuid;
BEGIN
  IF NOT public.is_manager(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;

  IF _tenant_id IS NOT NULL THEN
    v_tenant := _tenant_id;
  ELSE
    INSERT INTO public.tenants (first_name, last_name, phone, email, notes)
    VALUES (
      COALESCE(NULLIF(btrim(_first_name), ''), 'Nuomininkas'),
      COALESCE(_last_name, ''),
      COALESCE(_phone, ''),
      COALESCE(_email, ''),
      COALESCE(_notes, '')
    )
    RETURNING id INTO v_tenant;
  END IF;

  INSERT INTO public.leases (
    unit_id, tenant_id, start_date, end_date, monthly_rent, deposit,
    payment_day, notice_days, status, renewal
  )
  VALUES (
    _unit_id, v_tenant, _start_date, _end_date, COALESCE(_monthly_rent, 0),
    COALESCE(_deposit, 0), COALESCE(_payment_day, 1), COALESCE(_notice_days, 30),
    'draft', true
  )
  RETURNING id INTO v_lease;

  UPDATE public.rental_inquiries
     SET status = 'converted',
         converted_lease_id = v_lease,
         handled_by = auth.uid(),
         unit_id = COALESCE(unit_id, _unit_id),
         updated_at = now()
   WHERE id = _inquiry_id;

  RETURN QUERY SELECT v_lease, v_tenant;
END;
$$;
REVOKE ALL ON FUNCTION public.convert_inquiry_to_lease(uuid, uuid, date, numeric, numeric, integer, integer, uuid, text, text, text, text, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.convert_inquiry_to_lease(uuid, uuid, date, numeric, numeric, integer, integer, uuid, text, text, text, text, date, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.round_money_products(_items jsonb)
RETURNS numeric[] LANGUAGE sql IMMUTABLE SET search_path = public
AS $$
  SELECT coalesce(
    array_agg(
      round(((i->>'a')::numeric * (i->>'b')::numeric) / coalesce(nullif(i->>'div','')::numeric, 1), 2)
      ORDER BY ord
    ),
    '{}'::numeric[]
  )
  FROM jsonb_array_elements(coalesce(_items, '[]'::jsonb)) WITH ORDINALITY AS t(i, ord)
$$;
REVOKE EXECUTE ON FUNCTION public.round_money_products(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.round_money_products(jsonb) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.issue_invoice_for_charges(_charge_ids uuid[], _issue_date date, _currency text, _vat_rate numeric, _is_vat_invoice boolean, _seller jsonb, _buyer jsonb, _line_items jsonb, _subtotal_net numeric, _vat_amount numeric, _total numeric, _notes text, _issued_by text)
 RETURNS TABLE(invoice_id uuid, full_number text)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  v_lease uuid;
  v_lease_count int;
  v_locked int;
  v_invoiced int;
  v_series text;
  v_number integer;
  v_full text;
  v_invoice uuid;
  v_updated int;
  v_expected int;
BEGIN
  IF NOT public.is_manager(auth.uid()) THEN
    RAISE EXCEPTION 'Forbidden';
  END IF;

  v_expected := COALESCE(array_length(_charge_ids, 1), 0);
  IF v_expected = 0 THEN
    RAISE EXCEPTION 'No charges selected';
  END IF;

  SELECT count(*), count(DISTINCT c.lease_id), count(*) FILTER (WHERE c.invoice_id IS NOT NULL), min(c.lease_id::text)::uuid
    INTO v_locked, v_lease_count, v_invoiced, v_lease
  FROM (SELECT ch.id, ch.lease_id, ch.invoice_id FROM public.charges ch WHERE ch.id = ANY(_charge_ids) FOR UPDATE) c;

  IF v_locked <> v_expected THEN
    RAISE EXCEPTION 'Charge not found (% of % rows)', v_locked, v_expected;
  END IF;
  IF v_lease_count <> 1 THEN
    RAISE EXCEPTION 'Charges belong to % leases; one invoice covers one lease', v_lease_count;
  END IF;
  IF v_invoiced > 0 THEN
    RAISE EXCEPTION 'ChargeAlreadyInvoiced: % charge(s) already on an invoice', v_invoiced;
  END IF;

  SELECT cin.series, cin.number INTO v_series, v_number FROM public.claim_invoice_number() cin;
  v_full := CASE WHEN COALESCE(v_series, '') <> '' THEN v_series || '-' || v_number ELSE v_number::text END;

  INSERT INTO public.invoices (
    lease_id, invoice_series, invoice_number, full_number, issue_date, currency,
    vat_rate, is_vat_invoice, seller, buyer, line_items, subtotal_net, vat_amount, total, notes, issued_by
  ) VALUES (
    v_lease, COALESCE(v_series, ''), v_number, v_full, _issue_date, _currency,
    _vat_rate, _is_vat_invoice, _seller, _buyer, _line_items, _subtotal_net, _vat_amount, _total,
    COALESCE(_notes, ''), COALESCE(_issued_by, '')
  ) RETURNING id INTO v_invoice;

  UPDATE public.charges ch SET invoice_id = v_invoice
  WHERE ch.id = ANY(_charge_ids) AND ch.invoice_id IS NULL;
  GET DIAGNOSTICS v_updated = ROW_COUNT;

  IF v_updated <> v_expected THEN
    RAISE EXCEPTION 'Linked % of % charges — rolled back', v_updated, v_expected;
  END IF;

  RETURN QUERY SELECT v_invoice, v_full;
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.issue_invoice_for_charges(uuid[], date, text, numeric, boolean, jsonb, jsonb, jsonb, numeric, numeric, numeric, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.issue_invoice_for_charges(uuid[], date, text, numeric, boolean, jsonb, jsonb, jsonb, numeric, numeric, numeric, text, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.analytics_summary(_from date, _to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $function$
DECLARE
  result jsonb;
BEGIN
  IF NOT public.is_owner(auth.uid()) THEN
    RAISE EXCEPTION 'not authorised';
  END IF;

  IF _from IS NULL OR _to IS NULL OR _to < _from OR (_to - _from) > 400 THEN
    RAISE EXCEPTION 'invalid date range';
  END IF;

  WITH pv AS (
    SELECT
      (created_at AT TIME ZONE 'utc')::date AS day,
      path,
      session_id,
      CASE
        WHEN coalesce(referrer, '') = '' THEN 'direct'
        WHEN referrer ILIKE '%google.%' THEN 'google'
        WHEN referrer ILIKE '%bing.%' OR referrer ILIKE '%duckduckgo.%' OR referrer ILIKE '%yahoo.%' THEN 'search'
        WHEN referrer ILIKE '%facebook.%' OR referrer ILIKE '%fb.%' THEN 'facebook'
        WHEN referrer ILIKE '%instagram.%' THEN 'instagram'
        ELSE 'other'
      END AS source,
      CASE
        WHEN user_agent ILIKE '%ipad%' OR user_agent ILIKE '%tablet%' THEN 'tablet'
        WHEN user_agent ILIKE '%mobi%' OR user_agent ILIKE '%iphone%' OR user_agent ILIKE '%android%' THEN 'mobile'
        WHEN coalesce(user_agent, '') = '' THEN 'unknown'
        ELSE 'desktop'
      END AS device
    FROM public.page_views
    WHERE (created_at AT TIME ZONE 'utc')::date BETWEEN _from AND _to
  )
  SELECT jsonb_build_object(
    'totals', (SELECT jsonb_build_object('views', count(*), 'visitors', count(DISTINCT session_id)) FROM pv),
    'previous', (
      SELECT jsonb_build_object('views', count(*), 'visitors', count(DISTINCT session_id))
      FROM public.page_views
      WHERE (created_at AT TIME ZONE 'utc')::date BETWEEN (_from - (_to - _from) - 1) AND (_from - 1)
    ),
    'daily', COALESCE((
      SELECT jsonb_agg(row_to_json(d) ORDER BY d.day)
      FROM (SELECT day, count(*) AS views, count(DISTINCT session_id) AS visitors FROM pv GROUP BY day) d
    ), '[]'::jsonb),
    'top_pages', COALESCE((
      SELECT jsonb_agg(row_to_json(p))
      FROM (SELECT path, count(*) AS views FROM pv GROUP BY path ORDER BY count(*) DESC LIMIT 15) p
    ), '[]'::jsonb),
    'sources', COALESCE((
      SELECT jsonb_agg(row_to_json(s))
      FROM (SELECT source, count(*) AS views FROM pv GROUP BY source ORDER BY count(*) DESC) s
    ), '[]'::jsonb),
    'devices', COALESCE((
      SELECT jsonb_agg(row_to_json(v))
      FROM (SELECT device, count(*) AS views FROM pv GROUP BY device) v
    ), '[]'::jsonb),
    'leads', (
      SELECT count(*) FROM public.rental_inquiries
      WHERE (created_at AT TIME ZONE 'utc')::date BETWEEN _from AND _to
    )
  ) INTO result;

  RETURN result;
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.analytics_summary(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.analytics_summary(date, date) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.unit_availability_calc(
  _status text,
  _created_at date,
  _holding_end_date date,
  _holding_renewal boolean,
  _last_finished_end date
)
RETURNS TABLE (available_from date, vacant_since date, vacant_days integer)
LANGUAGE sql STABLE SET search_path = public
AS $$
  SELECT
    CASE
      WHEN _status = 'vacant' THEN CURRENT_DATE
      WHEN _status = 'occupied' AND _holding_renewal = false AND _holding_end_date IS NOT NULL
        THEN _holding_end_date + 1
      ELSE NULL
    END AS available_from,
    CASE WHEN _status = 'vacant' THEN COALESCE(_last_finished_end, _created_at) END AS vacant_since,
    CASE WHEN _status = 'vacant'
      THEN GREATEST(0, CURRENT_DATE - COALESCE(_last_finished_end, _created_at))
    END AS vacant_days;
$$;
REVOKE ALL ON FUNCTION public.unit_availability_calc(text, date, date, boolean, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.unit_availability_calc(text, date, date, boolean, date) TO anon, authenticated, service_role;

-- ============ 11. VIEWS ============
CREATE VIEW public.unit_availability
WITH (security_invoker = true) AS
SELECT
  u.id AS unit_id,
  u.status,
  u.is_active,
  u.is_listed,
  h.id          AS holding_lease_id,
  h.tenant_id   AS holding_tenant_id,
  h.start_date  AS holding_start_date,
  h.end_date    AS holding_end_date,
  h.renewal     AS holding_renewal,
  h.monthly_rent AS holding_monthly_rent,
  EXISTS (
    SELECT 1 FROM public.leases f
    WHERE f.unit_id = u.id
      AND f.status IN ('draft','active','ending')
      AND f.start_date > CURRENT_DATE
  ) AS has_future_lease,
  c.available_from,
  c.vacant_since,
  c.vacant_days
FROM public.units u
LEFT JOIN LATERAL (
  SELECT l.id, l.tenant_id, l.start_date, l.end_date, l.renewal, l.monthly_rent
  FROM public.leases l
  WHERE l.unit_id = u.id
    AND l.status IN ('active','ending')
    AND l.start_date <= CURRENT_DATE
    AND (l.end_date IS NULL OR l.end_date >= CURRENT_DATE)
  ORDER BY l.end_date NULLS LAST
  LIMIT 1
) h ON true
LEFT JOIN LATERAL (
  SELECT MAX(x.end_date) AS end_date
  FROM public.leases x
  WHERE x.unit_id = u.id AND x.status IN ('expired','terminated')
) fin ON true
CROSS JOIN LATERAL public.unit_availability_calc(
  u.status, u.created_at::date, h.end_date, h.renewal, fin.end_date
) c;
REVOKE ALL ON public.unit_availability FROM PUBLIC, anon;
GRANT SELECT ON public.unit_availability TO authenticated, service_role;

CREATE VIEW public.public_vacancies
WITH (security_invoker = off) AS
SELECT u.id, u.name, u.unit_number, u.description, u.city, u.address,
       b.name AS building_name, u.area_m2, u.room_count, u.floor,
       u.monthly_rent, u.deposit, u.amenities, u.cover_image_url, u.image_urls,
       c.available_from,
       (u.status = 'vacant') AS vacant_now
FROM public.units u
LEFT JOIN public.buildings b ON b.id = u.building_id
LEFT JOIN LATERAL (
  SELECT l.end_date, l.renewal
  FROM public.leases l
  WHERE l.unit_id = u.id
    AND l.status IN ('active','ending')
    AND l.start_date <= CURRENT_DATE
    AND (l.end_date IS NULL OR l.end_date >= CURRENT_DATE)
  ORDER BY l.end_date NULLS LAST
  LIMIT 1
) h ON true
CROSS JOIN LATERAL public.unit_availability_calc(
  u.status, u.created_at::date, h.end_date, h.renewal, NULL::date
) c
WHERE u.is_active AND u.is_listed
  AND c.available_from IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.leases f
    WHERE f.unit_id = u.id
      AND f.status IN ('draft','active','ending')
      AND f.start_date > CURRENT_DATE
  );
GRANT SELECT ON public.public_vacancies TO anon, authenticated;

-- ============ 12. POLICIES ============
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'units','buildings','tenants','leases','lease_occupants','meters','meter_readings',
    'charges','payments','issues','issue_comments','documents','unit_events',
    'expenses','property_investments','property_maintenance'
  ] LOOP
    EXECUTE format('CREATE POLICY "Managers read %1$s" ON public.%1$I FOR SELECT TO authenticated USING (public.is_manager(auth.uid()))', t);
    EXECUTE format('CREATE POLICY "Managers insert %1$s" ON public.%1$I FOR INSERT TO authenticated WITH CHECK (public.is_manager(auth.uid()))', t);
    EXECUTE format('CREATE POLICY "Managers update %1$s" ON public.%1$I FOR UPDATE TO authenticated USING (public.is_manager(auth.uid())) WITH CHECK (public.is_manager(auth.uid()))', t);
    EXECUTE format('CREATE POLICY "Owners delete %1$s" ON public.%1$I FOR DELETE TO authenticated USING (public.is_owner(auth.uid()))', t);
  END LOOP;
END $$;

CREATE POLICY "Owners manage tenant identity" ON public.tenant_identity
  FOR ALL TO authenticated USING (public.is_owner(auth.uid())) WITH CHECK (public.is_owner(auth.uid()));

CREATE POLICY "Managers read utility rates" ON public.utility_rates
  FOR SELECT TO authenticated USING (public.is_manager(auth.uid()));
CREATE POLICY "Owners manage utility rates" ON public.utility_rates
  FOR ALL TO authenticated USING (public.is_owner(auth.uid())) WITH CHECK (public.is_owner(auth.uid()));

CREATE POLICY "Owners manage org settings" ON public.org_settings
  FOR ALL TO authenticated USING (public.is_owner(auth.uid())) WITH CHECK (public.is_owner(auth.uid()));
CREATE POLICY "Managers read org settings" ON public.org_settings
  FOR SELECT TO authenticated USING (public.is_manager(auth.uid()));

CREATE POLICY "Managers read invoices" ON public.invoices
  FOR SELECT TO authenticated USING (public.is_manager(auth.uid()));
CREATE POLICY "Tenants read invoices of own lease" ON public.invoices
  FOR SELECT TO authenticated USING (lease_id IS NOT NULL AND public.tenant_owns_lease(lease_id));

CREATE POLICY "Anyone can submit an inquiry" ON public.rental_inquiries
  FOR INSERT TO anon, authenticated WITH CHECK (status = 'new' AND handled_by IS NULL AND converted_lease_id IS NULL);
CREATE POLICY "Managers read inquiries" ON public.rental_inquiries
  FOR SELECT TO authenticated USING (public.is_manager(auth.uid()));
CREATE POLICY "Managers update inquiries" ON public.rental_inquiries
  FOR UPDATE TO authenticated USING (public.is_manager(auth.uid())) WITH CHECK (public.is_manager(auth.uid()));
CREATE POLICY "Owners delete inquiries" ON public.rental_inquiries
  FOR DELETE TO authenticated USING (public.is_owner(auth.uid()));

CREATE POLICY "Tenants read own unit" ON public.units
  FOR SELECT TO authenticated USING (public.tenant_owns_unit(id));
CREATE POLICY "Tenants read own building" ON public.buildings
  FOR SELECT TO authenticated USING (EXISTS (
    SELECT 1 FROM public.units u WHERE u.building_id = buildings.id AND public.tenant_owns_unit(u.id)));
CREATE POLICY "Tenants read own record" ON public.tenants
  FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "Tenants read own leases" ON public.leases
  FOR SELECT TO authenticated USING (tenant_id = public.current_tenant_id());
CREATE POLICY "Tenants read own lease occupants" ON public.lease_occupants
  FOR SELECT TO authenticated USING (public.tenant_owns_lease(lease_id));
CREATE POLICY "Tenants read own meters" ON public.meters
  FOR SELECT TO authenticated
  USING (
    (unit_id IS NOT NULL AND public.tenant_owns_unit(unit_id))
    OR (unit_id IS NULL AND building_id IS NOT NULL AND public.tenant_owns_building(building_id))
  );
CREATE POLICY "Tenants read own readings" ON public.meter_readings
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.meters m
    WHERE m.id = meter_readings.meter_id
      AND (
        (m.unit_id IS NOT NULL AND public.tenant_owns_unit(m.unit_id))
        OR (m.unit_id IS NULL AND m.building_id IS NOT NULL AND public.tenant_owns_building(m.building_id))
      )
  ));
CREATE POLICY "Tenants submit readings" ON public.meter_readings
  FOR INSERT TO authenticated
  WITH CHECK (
    status = 'submitted'
    AND submitted_by = auth.uid()
    AND EXISTS (
      SELECT 1 FROM public.meters m
      WHERE m.id = meter_readings.meter_id
        AND (
          (m.unit_id IS NOT NULL AND public.tenant_owns_unit(m.unit_id))
          OR (m.unit_id IS NULL AND m.building_id IS NOT NULL AND public.tenant_owns_building(m.building_id))
        )
    )
  );
CREATE POLICY "Tenants read own charges" ON public.charges
  FOR SELECT TO authenticated USING (public.tenant_owns_lease(lease_id));
CREATE POLICY "Tenants read own payments" ON public.payments
  FOR SELECT TO authenticated USING (public.tenant_owns_lease(lease_id));
CREATE POLICY "Tenants read own issues" ON public.issues
  FOR SELECT TO authenticated USING (public.tenant_owns_unit(unit_id));
CREATE POLICY "Tenants report issues" ON public.issues
  FOR INSERT TO authenticated WITH CHECK (
    reported_by = auth.uid() AND status = 'new' AND public.tenant_owns_unit(unit_id));
CREATE POLICY "Tenants update own new issues" ON public.issues
  FOR UPDATE TO authenticated
  USING (reported_by = auth.uid() AND status = 'new' AND public.tenant_owns_unit(unit_id))
  WITH CHECK (reported_by = auth.uid() AND status = 'new');
CREATE POLICY "Tenants read own issue comments" ON public.issue_comments
  FOR SELECT TO authenticated USING (is_internal = false AND EXISTS (
    SELECT 1 FROM public.issues i WHERE i.id = issue_comments.issue_id AND public.tenant_owns_unit(i.unit_id)));
CREATE POLICY "Tenants comment on own issues" ON public.issue_comments
  FOR INSERT TO authenticated WITH CHECK (
    author_id = auth.uid() AND is_internal = false AND EXISTS (
      SELECT 1 FROM public.issues i WHERE i.id = issue_comments.issue_id AND public.tenant_owns_unit(i.unit_id)));
CREATE POLICY "Tenants read own documents" ON public.documents
  FOR SELECT TO authenticated USING (
    (tenant_id IS NOT NULL AND tenant_id = public.current_tenant_id())
    OR (lease_id IS NOT NULL AND public.tenant_owns_lease(lease_id))
    OR (unit_id IS NOT NULL AND public.tenant_owns_unit(unit_id)));

-- ============ 13. STORAGE POLICIES ============
CREATE POLICY "Managers manage documents bucket" ON storage.objects
  FOR ALL TO authenticated
  USING (bucket_id = 'documents' AND public.is_manager(auth.uid()))
  WITH CHECK (bucket_id = 'documents' AND public.is_manager(auth.uid()));
CREATE POLICY "Tenants read own documents files" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'documents' AND (
    (storage.foldername(name))[1] = 'tenant' AND (storage.foldername(name))[2] = public.current_tenant_id()::text
    OR ((storage.foldername(name))[1] = 'lease' AND public.tenant_owns_lease(((storage.foldername(name))[2])::uuid))
  ));
CREATE POLICY "Managers manage meter photos" ON storage.objects
  FOR ALL TO authenticated
  USING (bucket_id = 'meter-photos' AND public.is_manager(auth.uid()))
  WITH CHECK (bucket_id = 'meter-photos' AND public.is_manager(auth.uid()));
CREATE POLICY "Tenants read own meter photos" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'meter-photos' AND public.tenant_owns_unit(((storage.foldername(name))[1])::uuid));
CREATE POLICY "Tenants upload meter photos" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'meter-photos' AND public.tenant_owns_unit(((storage.foldername(name))[1])::uuid));
CREATE POLICY "Managers manage issue photos" ON storage.objects
  FOR ALL TO authenticated
  USING (bucket_id = 'issue-photos' AND public.is_manager(auth.uid()))
  WITH CHECK (bucket_id = 'issue-photos' AND public.is_manager(auth.uid()));
CREATE POLICY "Tenants read own issue photos" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'issue-photos' AND public.tenant_owns_unit(((storage.foldername(name))[1])::uuid));
CREATE POLICY "Tenants upload issue photos" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'issue-photos' AND public.tenant_owns_unit(((storage.foldername(name))[1])::uuid));
CREATE POLICY "Public read unit photos" ON storage.objects
  FOR SELECT TO anon, authenticated USING (bucket_id = 'unit-photos');
CREATE POLICY "Managers manage unit photos" ON storage.objects
  FOR ALL TO authenticated
  USING (bucket_id = 'unit-photos' AND public.is_manager(auth.uid()))
  WITH CHECK (bucket_id = 'unit-photos' AND public.is_manager(auth.uid()));