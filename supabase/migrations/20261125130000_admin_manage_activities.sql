-- Add write access for active Admins without changing existing read policies.
DO $$
DECLARE
  activities_rls_enabled boolean;
BEGIN
  IF to_regclass('public.activities') IS NULL THEN
    RAISE EXCEPTION
      'public.activities does not exist; inspect the database before applying this migration';
  END IF;

  SELECT relrowsecurity
    INTO activities_rls_enabled
    FROM pg_class
   WHERE oid = to_regclass('public.activities');

  IF activities_rls_enabled IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION
      'RLS must already be enabled on public.activities';
  END IF;

  IF to_regprocedure('public.is_admin()') IS NULL THEN
    RAISE EXCEPTION
      'public.is_admin() is required before adding activity policies';
  END IF;

  IF to_regprocedure(
    'public.is_active_child_development_admin()'
  ) IS NULL THEN
    RAISE EXCEPTION
      'public.is_active_child_development_admin() is required before adding activity policies';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename = 'activities'
       AND policyname = 'admin_read_activities'
       AND cmd = 'SELECT'
  ) THEN
    RAISE EXCEPTION
      'Existing admin_read_activities SELECT policy was not found; inspect it before applying this migration';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename = 'activities'
       AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  ) THEN
    RAISE EXCEPTION
      'An existing write or ALL policy was found on public.activities; inspect it before applying this migration';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename = 'activities'
       AND policyname IN (
         'activities_admin_insert_active',
         'activities_admin_update_active',
         'activities_admin_delete_active'
       )
  ) THEN
    RAISE EXCEPTION
      'An activity write policy with the planned name already exists; inspect it before applying this migration';
  END IF;
END;
$$;

GRANT INSERT, UPDATE, DELETE
  ON TABLE public.activities
  TO authenticated;

CREATE POLICY activities_admin_insert_active
  ON public.activities
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.is_admin()
    AND public.is_active_child_development_admin()
    AND created_by = auth.uid()
  );

CREATE POLICY activities_admin_update_active
  ON public.activities
  FOR UPDATE
  TO authenticated
  USING (
    public.is_admin()
    AND public.is_active_child_development_admin()
  )
  WITH CHECK (
    public.is_admin()
    AND public.is_active_child_development_admin()
  );

CREATE POLICY activities_admin_delete_active
  ON public.activities
  FOR DELETE
  TO authenticated
  USING (
    public.is_admin()
    AND public.is_active_child_development_admin()
  );
