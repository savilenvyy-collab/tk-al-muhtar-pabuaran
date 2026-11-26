-- School-wide settings: a single row shared by the application.
-- This migration intentionally stops if the table already exists so it can
-- be inspected before any existing database object is changed.
DO $$
BEGIN
  IF to_regclass('public.school_settings') IS NOT NULL THEN
    RAISE EXCEPTION
      'public.school_settings already exists; inspect it before applying this migration';
  END IF;

  IF to_regprocedure(
    'public.set_school_settings_audit_fields()'
  ) IS NOT NULL THEN
    RAISE EXCEPTION
      'public.set_school_settings_audit_fields() already exists; inspect it before applying this migration';
  END IF;

  IF to_regprocedure('public.is_admin()') IS NULL THEN
    RAISE EXCEPTION
      'public.is_admin() is required before creating school settings';
  END IF;

  IF to_regprocedure(
    'public.is_active_child_development_admin()'
  ) IS NULL THEN
    RAISE EXCEPTION
      'public.is_active_child_development_admin() is required before creating school settings';
  END IF;
END;
$$;

CREATE TABLE public.school_settings (
  id smallint PRIMARY KEY DEFAULT 1,
  school_name text NOT NULL DEFAULT 'TK AL-Muhtar Pabuaran',
  school_address text NOT NULL DEFAULT '',
  school_phone text NOT NULL DEFAULT '',
  principal_name text NOT NULL DEFAULT '',
  academic_year text,
  semester text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid NOT NULL,

  CONSTRAINT school_settings_singleton_check
    CHECK (id = 1),
  CONSTRAINT school_settings_school_name_check
    CHECK (char_length(btrim(school_name)) BETWEEN 1 AND 150),
  CONSTRAINT school_settings_address_length_check
    CHECK (char_length(school_address) <= 500),
  CONSTRAINT school_settings_phone_length_check
    CHECK (char_length(school_phone) <= 50),
  CONSTRAINT school_settings_principal_length_check
    CHECK (char_length(principal_name) <= 150),
  CONSTRAINT school_settings_academic_year_check
    CHECK (
      academic_year IS NULL
      OR (
        char_length(btrim(academic_year)) = 9
        AND academic_year ~ '^[0-9]{4}/[0-9]{4}$'
      )
    ),
  CONSTRAINT school_settings_semester_check
    CHECK (semester IS NULL OR semester IN ('Ganjil', 'Genap'))
);

CREATE FUNCTION public.set_school_settings_audit_fields()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    NEW.id := OLD.id;
  END IF;

  NEW.updated_at := pg_catalog.clock_timestamp();
  NEW.updated_by := auth.uid();
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.set_school_settings_audit_fields()
  FROM PUBLIC, anon, authenticated;

CREATE TRIGGER school_settings_set_audit_fields
BEFORE INSERT OR UPDATE ON public.school_settings
FOR EACH ROW
EXECUTE FUNCTION public.set_school_settings_audit_fields();

ALTER TABLE public.school_settings ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.school_settings
  FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE
  ON TABLE public.school_settings
  TO authenticated;

CREATE POLICY school_settings_select_active_admin
  ON public.school_settings
  FOR SELECT
  TO authenticated
  USING (
    public.is_admin()
    AND public.is_active_child_development_admin()
  );

CREATE POLICY school_settings_insert_active_admin
  ON public.school_settings
  FOR INSERT
  TO authenticated
  WITH CHECK (
    id = 1
    AND updated_by = auth.uid()
    AND public.is_admin()
    AND public.is_active_child_development_admin()
  );

CREATE POLICY school_settings_update_active_admin
  ON public.school_settings
  FOR UPDATE
  TO authenticated
  USING (
    id = 1
    AND public.is_admin()
    AND public.is_active_child_development_admin()
  )
  WITH CHECK (
    id = 1
    AND updated_by = auth.uid()
    AND public.is_admin()
    AND public.is_active_child_development_admin()
  );

NOTIFY pgrst, 'reload schema';
