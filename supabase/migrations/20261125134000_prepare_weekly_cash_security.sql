-- DRAFT: review before applying. This migration has not been run.
--
-- Cash rules:
-- - A bill remains in its original week until paid; unpaid balances are not
--   copied into a later bill.
-- - A bill insert creates one initial reminder per connected active Parent.
--   A separate scheduled function creates one overdue reminder only when
--   due_date has passed; NULL due dates are not overdue.
-- - Payment rows are recorded through record_cash_payment_with_allocations().
--   The caller must create one UUID per payment attempt and reuse it on retry.
-- - Payments are not directly updated or deleted. Admin corrections are
--   recorded in cash_payment_corrections and retain an audit trail.
-- - Allocation rows are append-only for authenticated users; allocation
--   reclassification needs a separately reviewed correction design.
-- - A correction changes the recorded amount and writes old/new values plus a
--   reason. It is not a refund transaction; refund handling is intentionally
--   not implemented in this draft.
-- - Reminder identities are encoded in notification_type; is_read is never
--   used as a substitute for is_active.

DO $preflight$
BEGIN
  IF current_setting('server_version_num')::integer < 150000 THEN
    RAISE EXCEPTION
      'PostgreSQL 15 or newer is required for the security-invoker balance view';
  END IF;

  IF to_regclass('public.cash_bills') IS NULL
     OR to_regclass('public.cash_payments') IS NULL
     OR to_regclass('public.cash_payment_allocations') IS NULL
     OR to_regclass('public.cash_expenses') IS NULL
     OR to_regclass('public.notifications') IS NULL
     OR to_regclass('public.parents') IS NULL
     OR to_regclass('public.student_parents') IS NULL
     OR to_regclass('public.students') IS NULL
     OR to_regclass('public.profiles') IS NULL THEN
    RAISE EXCEPTION
      'A required finance or Parent-link table is missing; inspect the database before applying';
  END IF;

  IF to_regprocedure('public.is_active_child_development_admin()') IS NULL
     OR to_regprocedure('public.is_active_child_development_guru()') IS NULL
     OR to_regprocedure('public.is_child_development_parent_for(uuid)') IS NULL
     OR to_regprocedure('public.is_active_parent()') IS NULL
     OR to_regprocedure('public.is_admin()') IS NULL THEN
    RAISE EXCEPTION
      'One or more audited role helpers are missing; this migration will not replace them';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM (
        VALUES
          ('cash_bills', 'id'),
          ('cash_bills', 'student_id'),
          ('cash_bills', 'week_start'),
          ('cash_bills', 'week_end'),
          ('cash_bills', 'due_date'),
          ('cash_bills', 'amount'),
          ('cash_bills', 'created_by'),
          ('cash_payments', 'id'),
          ('cash_payments', 'student_id'),
          ('cash_payments', 'parent_id'),
          ('cash_payments', 'payment_date'),
          ('cash_payments', 'amount'),
          ('cash_payments', 'payment_method'),
          ('cash_payments', 'receipt_url'),
          ('cash_payments', 'notes'),
          ('cash_payments', 'recorded_by'),
          ('cash_payment_allocations', 'id'),
          ('cash_payment_allocations', 'payment_id'),
          ('cash_payment_allocations', 'bill_id'),
          ('cash_payment_allocations', 'allocated_amount'),
          ('cash_expenses', 'recorded_by'),
          ('cash_expenses', 'amount'),
          ('notifications', 'user_id'),
          ('notifications', 'title'),
          ('notifications', 'message'),
          ('notifications', 'notification_type'),
          ('notifications', 'is_read'),
          ('parents', 'id'),
          ('parents', 'user_id'),
          ('student_parents', 'parent_id'),
          ('student_parents', 'student_id'),
          ('students', 'id'),
          ('students', 'full_name'),
          ('profiles', 'id'),
          ('profiles', 'role'),
          ('profiles', 'is_active')
      ) AS required_columns(table_name, column_name)
      LEFT JOIN information_schema.columns c
        ON c.table_schema = 'public'
       AND c.table_name = required_columns.table_name
       AND c.column_name = required_columns.column_name
     WHERE c.column_name IS NULL
  ) THEN
    RAISE EXCEPTION
      'A required audited column is missing; inspect the live schema before applying';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM information_schema.columns c
     WHERE c.table_schema = 'public'
       AND c.table_name = 'notifications'
       AND c.column_name = 'notification_type'
       AND c.character_maximum_length IS NOT NULL
       AND c.character_maximum_length < 46
  ) THEN
    RAISE EXCEPTION
      'notifications.notification_type is too short for reminder identifiers';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM information_schema.columns c
     WHERE c.table_schema = 'public'
       AND c.table_name = 'notifications'
       AND c.column_name = 'is_active'
  ) THEN
    RAISE EXCEPTION
      'notifications.is_active already exists; inspect its definition before applying';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_constraint c
     WHERE c.conrelid = 'public.cash_bills'::regclass
       AND c.contype = 'u'
       AND pg_get_constraintdef(c.oid) =
           'UNIQUE (student_id, week_start)'
  ) THEN
    RAISE EXCEPTION
      'The existing UNIQUE(student_id, week_start) constraint was not found';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename = 'cash_payments'
       AND policyname = 'admin_read_cash_payments'
       AND cmd = 'SELECT'
       AND 'authenticated' = ANY (roles)
       AND position('is_admin()' IN lower(coalesce(qual, ''))) > 0
  ) OR NOT EXISTS (
    SELECT 1
      FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename = 'cash_expenses'
       AND policyname = 'admin_read_cash_expenses'
       AND cmd = 'SELECT'
       AND 'authenticated' = ANY (roles)
       AND position('is_admin()' IN lower(coalesce(qual, ''))) > 0
  ) THEN
    RAISE EXCEPTION
      'An audited Admin SELECT policy is missing or differs; inspect it before applying';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename IN (
         'cash_bills',
         'cash_payments',
         'cash_payment_allocations',
         'cash_expenses',
         'notifications'
       )
       AND NOT (
         (tablename = 'cash_payments'
          AND policyname = 'admin_read_cash_payments')
         OR
         (tablename = 'cash_expenses'
          AND policyname = 'admin_read_cash_expenses')
       )
  ) THEN
    RAISE EXCEPTION
      'An unreviewed policy exists on a cash/notification table; inspect it before applying';
  END IF;

  IF to_regclass('public.cash_payment_corrections') IS NOT NULL
     OR to_regclass('public.cash_bill_balances') IS NOT NULL
     OR to_regclass('public.cash_payment_corrections_payment_idx') IS NOT NULL
     OR to_regclass('public.cash_payment_allocations_payment_bill_key') IS NOT NULL
     OR to_regclass('public.notifications_cash_reminder_user_type_key') IS NOT NULL THEN
    RAISE EXCEPTION
      'A planned cash object already exists; inspect it rather than replacing it';
  END IF;

  IF to_regprocedure(
       'public.record_cash_payment_with_allocations(uuid,uuid,uuid,date,numeric,character varying,text,text,jsonb)'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.correct_cash_payment_amount(uuid,uuid,numeric,text)'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.correct_cash_payment_amount(uuid,uuid,numeric,numeric,text)'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.enforce_cash_payment_allocation_limits()'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.guard_cash_bill_allocations()'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.guard_cash_payment_amount()'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.reject_cash_ledger_mutation()'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.prevent_cash_reminder_delete()'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.enforce_parent_notification_read_only()'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.sync_cash_bill_arrears_notification(uuid)'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.create_overdue_cash_reminders()'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.cash_bill_arrears_trigger()'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.cash_allocation_arrears_trigger()'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.cash_parent_link_arrears_trigger()'
     ) IS NOT NULL THEN
    RAISE EXCEPTION
      'A planned cash function already exists; inspect it rather than replacing it';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE NOT t.tgisinternal
       AND n.nspname = 'public'
       AND t.tgname IN (
         'cash_payment_allocation_limits',
         'cash_payment_allocations_immutable',
         'cash_payment_corrections_immutable',
         'cash_bill_allocation_guard',
         'cash_payment_amount_guard',
         'cash_expenses_no_delete',
         'cash_reminders_no_delete',
         'aaa_notifications_parent_read_only_guard',
         'cash_bills_sync_arrears',
         'cash_allocations_sync_arrears',
         'cash_parent_links_sync_arrears'
       )
  ) THEN
    RAISE EXCEPTION
      'A planned cash trigger name already exists; inspect it before applying';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM pg_trigger t
     WHERE t.tgrelid = 'public.notifications'::regclass
       AND NOT t.tgisinternal
       AND (t.tgtype::integer & 2) = 2
       AND (t.tgtype::integer & 16) = 16
  ) THEN
    RAISE EXCEPTION
      'An existing notification BEFORE UPDATE trigger may modify Parent updates; inspect trigger compatibility before applying';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.cash_payment_allocations
     GROUP BY payment_id, bill_id
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION
      'Duplicate payment/bill allocations exist; reconcile them before adding the unique index';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.cash_payment_allocations a
      JOIN public.cash_payments p ON p.id = a.payment_id
     GROUP BY p.id, p.amount
    HAVING sum(a.allocated_amount) > p.amount
  ) OR EXISTS (
    SELECT 1
      FROM public.cash_payment_allocations a
      JOIN public.cash_bills b ON b.id = a.bill_id
     GROUP BY b.id, b.amount
    HAVING sum(a.allocated_amount) > b.amount
  ) THEN
    RAISE EXCEPTION
      'Existing allocations exceed a payment or bill; reconcile before applying';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.cash_payment_allocations a
      JOIN public.cash_payments p ON p.id = a.payment_id
      JOIN public.cash_bills b ON b.id = a.bill_id
     WHERE p.student_id <> b.student_id
  ) THEN
    RAISE EXCEPTION
      'An allocation links different students; reconcile before applying';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.notifications
     WHERE left(notification_type, 9) = 'cash_due:'
        OR left(notification_type, 10) = 'cash_late:'
     GROUP BY user_id, notification_type
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION
      'Duplicate cash arrears notifications exist; reconcile before adding the unique index';
  END IF;
END;
$preflight$;

CREATE TABLE public.cash_payment_corrections (
  id uuid PRIMARY KEY,
  payment_id uuid NOT NULL
    REFERENCES public.cash_payments(id) ON DELETE RESTRICT,
  old_amount numeric NOT NULL CHECK (old_amount > 0),
  new_amount numeric NOT NULL CHECK (new_amount > 0),
  correction_type text NOT NULL DEFAULT 'amount_correction'
    CHECK (correction_type = 'amount_correction'),
  reason text NOT NULL CHECK (char_length(btrim(reason)) > 0),
  corrected_by uuid NOT NULL
    REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT cash_payment_corrections_amount_changed
    CHECK (old_amount <> new_amount)
);

COMMENT ON TABLE public.cash_payment_corrections IS
  'Append-only audit for recorded amount corrections only; not a refund ledger.';

CREATE INDEX cash_payment_corrections_payment_idx
  ON public.cash_payment_corrections (payment_id, created_at);

CREATE UNIQUE INDEX cash_payment_allocations_payment_bill_key
  ON public.cash_payment_allocations (payment_id, bill_id);

CREATE UNIQUE INDEX notifications_cash_reminder_user_type_key
  ON public.notifications (user_id, notification_type)
  WHERE left(notification_type, 9) = 'cash_due:'
     OR left(notification_type, 10) = 'cash_late:';

ALTER TABLE public.notifications
  ADD COLUMN is_active boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.notifications.is_active IS
  'Whether the notification is an active reminder; independent of is_read.';

ALTER TABLE public.cash_bills ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cash_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cash_payment_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cash_expenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cash_payment_corrections ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE
  public.cash_bills,
  public.cash_payments,
  public.cash_payment_allocations,
  public.cash_expenses,
  public.notifications,
  public.cash_payment_corrections
FROM PUBLIC, anon, authenticated;

GRANT SELECT ON TABLE
  public.cash_bills,
  public.cash_payments,
  public.cash_payment_allocations,
  public.cash_expenses,
  public.notifications,
  public.cash_payment_corrections
TO authenticated;

GRANT INSERT, DELETE ON TABLE
  public.notifications
TO authenticated;

GRANT UPDATE (is_read) ON TABLE
  public.notifications
TO authenticated;

GRANT INSERT, UPDATE ON TABLE
  public.cash_bills,
  public.cash_expenses
TO authenticated;

CREATE POLICY cash_bills_select_by_role
  ON public.cash_bills
  FOR SELECT
  TO authenticated
  USING (
    public.is_active_child_development_admin()
    OR public.is_active_child_development_guru()
    OR public.is_child_development_parent_for(student_id)
  );

CREATE POLICY cash_bills_insert_active_staff
  ON public.cash_bills
  FOR INSERT
  TO authenticated
  WITH CHECK (
    (
      public.is_active_child_development_admin()
      OR public.is_active_child_development_guru()
    )
    AND created_by = auth.uid()
  );

CREATE POLICY cash_bills_update_active_staff
  ON public.cash_bills
  FOR UPDATE
  TO authenticated
  USING (
    public.is_active_child_development_admin()
    OR public.is_active_child_development_guru()
  )
  WITH CHECK (
    public.is_active_child_development_admin()
    OR public.is_active_child_development_guru()
  );

CREATE POLICY cash_payments_select_active_staff
  ON public.cash_payments
  FOR SELECT
  TO authenticated
  USING (
    public.is_active_child_development_admin()
    OR public.is_active_child_development_guru()
  );

CREATE POLICY cash_payments_select_linked_parent
  ON public.cash_payments
  FOR SELECT
  TO authenticated
  USING (
    public.is_child_development_parent_for(student_id)
  );

-- This restrictive policy keeps the existing permissive admin_read policy
-- from widening access to inactive or unrelated users.
CREATE POLICY cash_payments_select_active_scope
  ON public.cash_payments
  AS RESTRICTIVE
  FOR SELECT
  TO authenticated
  USING (
    public.is_active_child_development_admin()
    OR public.is_active_child_development_guru()
    OR public.is_child_development_parent_for(student_id)
  );

CREATE POLICY cash_payment_allocations_select_by_role
  ON public.cash_payment_allocations
  FOR SELECT
  TO authenticated
  USING (
    public.is_active_child_development_admin()
    OR public.is_active_child_development_guru()
    OR EXISTS (
      SELECT 1
        FROM public.cash_bills b
       WHERE b.id = cash_payment_allocations.bill_id
         AND public.is_child_development_parent_for(b.student_id)
    )
  );

CREATE POLICY cash_expenses_select_active_staff
  ON public.cash_expenses
  FOR SELECT
  TO authenticated
  USING (
    public.is_active_child_development_admin()
    OR public.is_active_child_development_guru()
  );

CREATE POLICY cash_expenses_select_active_scope
  ON public.cash_expenses
  AS RESTRICTIVE
  FOR SELECT
  TO authenticated
  USING (
    public.is_active_child_development_admin()
    OR public.is_active_child_development_guru()
  );

CREATE POLICY cash_expenses_insert_active_staff
  ON public.cash_expenses
  FOR INSERT
  TO authenticated
  WITH CHECK (
    (
      public.is_active_child_development_admin()
      OR public.is_active_child_development_guru()
    )
    AND recorded_by = auth.uid()
  );

CREATE POLICY cash_expenses_update_active_staff
  ON public.cash_expenses
  FOR UPDATE
  TO authenticated
  USING (
    public.is_active_child_development_admin()
    OR public.is_active_child_development_guru()
  )
  WITH CHECK (
    public.is_active_child_development_admin()
    OR public.is_active_child_development_guru()
  );

CREATE POLICY notifications_select_by_role
  ON public.notifications
  FOR SELECT
  TO authenticated
  USING (
    public.is_active_child_development_admin()
    OR public.is_active_child_development_guru()
    OR (
      public.is_active_parent()
      AND is_active = true
      AND user_id = auth.uid()
    )
  );

CREATE POLICY notifications_insert_active_staff
  ON public.notifications
  FOR INSERT
  TO authenticated
  WITH CHECK (
    public.is_active_child_development_admin()
    OR public.is_active_child_development_guru()
  );

CREATE POLICY notifications_update_active_staff
  ON public.notifications
  FOR UPDATE
  TO authenticated
  USING (
    public.is_active_child_development_admin()
    OR public.is_active_child_development_guru()
  )
  WITH CHECK (
    public.is_active_child_development_admin()
    OR public.is_active_child_development_guru()
  );

CREATE POLICY notifications_update_own_parent_read_state
  ON public.notifications
  FOR UPDATE
  TO authenticated
  USING (
    public.is_active_parent()
    AND is_active = true
    AND user_id = auth.uid()
  )
  WITH CHECK (
    public.is_active_parent()
    AND is_active = true
    AND user_id = auth.uid()
  );

CREATE POLICY notifications_delete_active_staff
  ON public.notifications
  FOR DELETE
  TO authenticated
  USING (
    public.is_active_child_development_admin()
    OR public.is_active_child_development_guru()
  );

CREATE POLICY cash_payment_corrections_select_admin
  ON public.cash_payment_corrections
  FOR SELECT
  TO authenticated
  USING (
    public.is_active_child_development_admin()
  );

CREATE VIEW public.cash_bill_balances
WITH (security_invoker = true)
AS
SELECT
  b.id AS bill_id,
  b.student_id,
  b.week_start,
  b.week_end,
  b.due_date,
  b.description,
  b.amount AS bill_amount,
  coalesce(a.allocated_amount, 0) AS allocated_amount,
  b.amount - coalesce(a.allocated_amount, 0) AS outstanding_amount,
  CASE
    WHEN coalesce(a.allocated_amount, 0) = b.amount THEN 'lunas'
    WHEN coalesce(a.allocated_amount, 0) = 0 THEN 'belum_lunas'
    ELSE 'dibayar_sebagian'
  END AS payment_status
FROM public.cash_bills b
LEFT JOIN (
  SELECT bill_id, sum(allocated_amount) AS allocated_amount
    FROM public.cash_payment_allocations
   GROUP BY bill_id
) a ON a.bill_id = b.id;

GRANT SELECT ON public.cash_bill_balances TO authenticated;

CREATE FUNCTION public.guard_cash_bill_allocations()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_allocated numeric;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.id IS DISTINCT FROM OLD.id THEN
      RAISE EXCEPTION 'A bill id cannot be changed';
    END IF;

    SELECT coalesce(sum(a.allocated_amount), 0)
      INTO v_allocated
      FROM public.cash_payment_allocations a
     WHERE a.bill_id = OLD.id;

    IF NEW.amount < v_allocated THEN
      RAISE EXCEPTION
        'Bill amount cannot be lower than its allocated payments';
    END IF;

    IF NEW.student_id IS DISTINCT FROM OLD.student_id
       AND v_allocated > 0 THEN
      RAISE EXCEPTION
        'A bill with allocations cannot be reassigned to another student';
    END IF;

    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'Bills cannot be deleted; preserve financial history';
END;
$function$;

REVOKE ALL ON FUNCTION public.guard_cash_bill_allocations()
  FROM PUBLIC, anon, authenticated;

CREATE TRIGGER cash_bill_allocation_guard
BEFORE UPDATE OR DELETE ON public.cash_bills
FOR EACH ROW
EXECUTE FUNCTION public.guard_cash_bill_allocations();

CREATE FUNCTION public.guard_cash_payment_amount()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_allocated numeric;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Payments cannot be deleted; preserve financial history';
  END IF;

  IF (to_jsonb(NEW) - 'amount')
     IS DISTINCT FROM (to_jsonb(OLD) - 'amount') THEN
    RAISE EXCEPTION
      'Payment details are immutable; only an audited amount correction is supported';
  END IF;

  IF NEW.amount IS DISTINCT FROM OLD.amount
     AND NOT EXISTS (
       SELECT 1
         FROM public.cash_payment_corrections c
        WHERE c.payment_id = OLD.id
          AND c.old_amount = OLD.amount
          AND c.new_amount = NEW.amount
          AND c.correction_type = 'amount_correction'
          AND c.corrected_by = auth.uid()
     ) THEN
    RAISE EXCEPTION
      'Payment amount changes require an Admin correction audit row';
  END IF;

  SELECT coalesce(sum(a.allocated_amount), 0)
    INTO v_allocated
    FROM public.cash_payment_allocations a
   WHERE a.payment_id = OLD.id;

  IF NEW.amount < v_allocated THEN
    RAISE EXCEPTION
      'Payment amount cannot be lower than its allocated total';
  END IF;

  IF NEW.student_id IS DISTINCT FROM OLD.student_id
     AND v_allocated > 0 THEN
    RAISE EXCEPTION
      'A payment with allocations cannot be reassigned to another student';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.guard_cash_payment_amount()
  FROM PUBLIC, anon, authenticated;

CREATE TRIGGER cash_payment_amount_guard
BEFORE UPDATE OR DELETE ON public.cash_payments
FOR EACH ROW
EXECUTE FUNCTION public.guard_cash_payment_amount();

CREATE FUNCTION public.enforce_cash_payment_allocation_limits()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_payment_amount numeric;
  v_payment_student uuid;
  v_bill_amount numeric;
  v_bill_student uuid;
  v_payment_allocated numeric;
  v_bill_allocated numeric;
BEGIN
  SELECT p.amount, p.student_id
    INTO v_payment_amount, v_payment_student
    FROM public.cash_payments p
   WHERE p.id = NEW.payment_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payment % does not exist', NEW.payment_id;
  END IF;

  SELECT b.amount, b.student_id
    INTO v_bill_amount, v_bill_student
    FROM public.cash_bills b
   WHERE b.id = NEW.bill_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Bill % does not exist', NEW.bill_id;
  END IF;

  IF v_payment_student IS DISTINCT FROM v_bill_student THEN
    RAISE EXCEPTION
      'A payment can only be allocated to a bill for the same student';
  END IF;

  SELECT coalesce(sum(a.allocated_amount), 0)
    INTO v_payment_allocated
    FROM public.cash_payment_allocations a
   WHERE a.payment_id = NEW.payment_id;

  SELECT coalesce(sum(a.allocated_amount), 0)
    INTO v_bill_allocated
    FROM public.cash_payment_allocations a
   WHERE a.bill_id = NEW.bill_id;

  IF v_payment_allocated + NEW.allocated_amount > v_payment_amount THEN
    RAISE EXCEPTION
      'Total allocations cannot exceed the payment amount';
  END IF;

  IF v_bill_allocated + NEW.allocated_amount > v_bill_amount THEN
    RAISE EXCEPTION
      'Total allocations cannot exceed the bill amount';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.enforce_cash_payment_allocation_limits()
  FROM PUBLIC, anon, authenticated;

CREATE TRIGGER cash_payment_allocation_limits
BEFORE INSERT ON public.cash_payment_allocations
FOR EACH ROW
EXECUTE FUNCTION public.enforce_cash_payment_allocation_limits();

CREATE FUNCTION public.reject_cash_ledger_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  RAISE EXCEPTION
    '% on % is blocked; this migration has no audited correction workflow for it',
    TG_OP,
    TG_TABLE_NAME;
END;
$function$;

REVOKE ALL ON FUNCTION public.reject_cash_ledger_mutation()
  FROM PUBLIC, anon, authenticated;

CREATE TRIGGER cash_payment_allocations_immutable
BEFORE UPDATE OR DELETE ON public.cash_payment_allocations
FOR EACH ROW
EXECUTE FUNCTION public.reject_cash_ledger_mutation();

CREATE TRIGGER cash_payment_corrections_immutable
BEFORE UPDATE OR DELETE ON public.cash_payment_corrections
FOR EACH ROW
EXECUTE FUNCTION public.reject_cash_ledger_mutation();

CREATE TRIGGER cash_expenses_no_delete
BEFORE DELETE ON public.cash_expenses
FOR EACH ROW
EXECUTE FUNCTION public.reject_cash_ledger_mutation();

CREATE FUNCTION public.prevent_cash_reminder_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF left(OLD.notification_type, 9) = 'cash_due:'
     OR left(OLD.notification_type, 10) = 'cash_late:' THEN
    RAISE EXCEPTION
      'Cash reminder history is retained; deactivate it instead of deleting it';
  END IF;

  RETURN OLD;
END;
$function$;

REVOKE ALL ON FUNCTION public.prevent_cash_reminder_delete()
  FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.enforce_parent_notification_read_only()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF public.is_active_parent()
     AND (
       (to_jsonb(NEW) - 'is_read')
       IS DISTINCT FROM
       (to_jsonb(OLD) - 'is_read')
     ) THEN
    RAISE EXCEPTION
      'Parents may only change is_read on their own notifications';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.enforce_parent_notification_read_only()
  FROM PUBLIC, anon, authenticated;

CREATE TRIGGER aaa_notifications_parent_read_only_guard
BEFORE UPDATE ON public.notifications
FOR EACH ROW
EXECUTE FUNCTION public.enforce_parent_notification_read_only();

CREATE TRIGGER cash_reminders_no_delete
BEFORE DELETE ON public.notifications
FOR EACH ROW
EXECUTE FUNCTION public.prevent_cash_reminder_delete();

CREATE FUNCTION public.record_cash_payment_with_allocations(
  p_payment_id uuid,
  p_student_id uuid,
  p_parent_id uuid,
  p_payment_date date,
  p_amount numeric,
  p_payment_method character varying,
  p_receipt_url text,
  p_notes text,
  p_allocations jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_inserted_id uuid;
  v_existing public.cash_payments%ROWTYPE;
  v_requested_allocations jsonb;
  v_existing_allocations jsonb;
  v_total_allocated numeric;
  v_item record;
BEGIN
  IF NOT (
    public.is_active_child_development_admin()
    OR public.is_active_child_development_guru()
  ) THEN
    RAISE EXCEPTION 'Only active Admin or Guru may record payments';
  END IF;

  IF p_payment_id IS NULL
     OR p_student_id IS NULL
     OR p_payment_date IS NULL
     OR p_amount IS NULL
     OR p_amount <= 0 THEN
    RAISE EXCEPTION
      'Payment id, student, date, and a positive amount are required';
  END IF;

  IF p_allocations IS NULL
     OR pg_catalog.jsonb_typeof(p_allocations) <> 'array' THEN
    RAISE EXCEPTION 'Allocations must be a JSON array';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM pg_catalog.jsonb_to_recordset(p_allocations)
           AS a(bill_id uuid, allocated_amount numeric)
     WHERE a.bill_id IS NULL
        OR a.allocated_amount IS NULL
        OR a.allocated_amount <= 0
  ) THEN
    RAISE EXCEPTION
      'Each allocation needs a bill id and a positive amount';
  END IF;

  SELECT coalesce(sum(a.allocated_amount), 0)
    INTO v_total_allocated
    FROM pg_catalog.jsonb_to_recordset(p_allocations)
         AS a(bill_id uuid, allocated_amount numeric);

  IF v_total_allocated > p_amount THEN
    RAISE EXCEPTION
      'Total allocations cannot exceed the payment amount';
  END IF;

  SELECT coalesce(
           jsonb_agg(
             jsonb_build_object(
               'bill_id', a.bill_id,
               'allocated_amount', a.total_amount
             )
             ORDER BY a.bill_id
           ),
           '[]'::jsonb
         )
    INTO v_requested_allocations
    FROM (
      SELECT r.bill_id, sum(r.allocated_amount) AS total_amount
        FROM pg_catalog.jsonb_to_recordset(p_allocations)
             AS r(bill_id uuid, allocated_amount numeric)
       GROUP BY r.bill_id
    ) a;

  INSERT INTO public.cash_payments (
    id,
    student_id,
    parent_id,
    payment_date,
    amount,
    payment_method,
    receipt_url,
    notes,
    recorded_by
  )
  VALUES (
    p_payment_id,
    p_student_id,
    p_parent_id,
    p_payment_date,
    p_amount,
    p_payment_method,
    p_receipt_url,
    p_notes,
    auth.uid()
  )
  ON CONFLICT (id) DO NOTHING
  RETURNING id INTO v_inserted_id;

  IF v_inserted_id IS NULL THEN
    SELECT p.*
      INTO v_existing
      FROM public.cash_payments p
     WHERE p.id = p_payment_id
     FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Payment idempotency key could not be resolved';
    END IF;

    IF v_existing.student_id IS DISTINCT FROM p_student_id
       OR v_existing.parent_id IS DISTINCT FROM p_parent_id
       OR v_existing.payment_date IS DISTINCT FROM p_payment_date
       OR (
         v_existing.amount IS DISTINCT FROM p_amount
         AND NOT EXISTS (
           SELECT 1
             FROM (
               SELECT c.old_amount
                 FROM public.cash_payment_corrections c
                WHERE c.payment_id = p_payment_id
                ORDER BY c.created_at, c.id
                LIMIT 1
             ) first_correction
            WHERE first_correction.old_amount = p_amount
         )
       )
       OR v_existing.payment_method IS DISTINCT FROM p_payment_method
       OR v_existing.receipt_url IS DISTINCT FROM p_receipt_url
       OR v_existing.notes IS DISTINCT FROM p_notes
       OR v_existing.recorded_by IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION
        'Payment id was already used with different details';
    END IF;

    SELECT coalesce(
             jsonb_agg(
               jsonb_build_object(
                 'bill_id', a.bill_id,
                 'allocated_amount', a.total_amount
               )
               ORDER BY a.bill_id
             ),
             '[]'::jsonb
           )
      INTO v_existing_allocations
      FROM (
        SELECT a.bill_id, sum(a.allocated_amount) AS total_amount
          FROM public.cash_payment_allocations a
         WHERE a.payment_id = p_payment_id
         GROUP BY a.bill_id
      ) a;

    IF v_existing_allocations IS DISTINCT FROM v_requested_allocations THEN
      RAISE EXCEPTION
        'Payment id was already used with different allocations';
    END IF;

    RETURN p_payment_id;
  END IF;

  IF p_parent_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
         FROM public.parents pa
         JOIN public.student_parents sp ON sp.parent_id = pa.id
        WHERE pa.id = p_parent_id
          AND sp.student_id = p_student_id
     ) THEN
    RAISE EXCEPTION
      'The selected Parent is not linked to this student';
  END IF;

  FOR v_item IN
    SELECT r.bill_id, sum(r.allocated_amount) AS allocated_amount
      FROM pg_catalog.jsonb_to_recordset(p_allocations)
           AS r(bill_id uuid, allocated_amount numeric)
     GROUP BY r.bill_id
     ORDER BY r.bill_id
  LOOP
    INSERT INTO public.cash_payment_allocations (
      payment_id,
      bill_id,
      allocated_amount
    )
    VALUES (
      p_payment_id,
      v_item.bill_id,
      v_item.allocated_amount
    );
  END LOOP;

  RETURN p_payment_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.record_cash_payment_with_allocations(
  uuid, uuid, uuid, date, numeric, character varying, text, text, jsonb
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_cash_payment_with_allocations(
  uuid, uuid, uuid, date, numeric, character varying, text, text, jsonb
) TO authenticated;

CREATE FUNCTION public.correct_cash_payment_amount(
  p_correction_id uuid,
  p_payment_id uuid,
  p_old_amount numeric,
  p_new_amount numeric,
  p_reason text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_old_amount numeric;
  v_allocated numeric;
  v_inserted_id uuid;
  v_existing public.cash_payment_corrections%ROWTYPE;
BEGIN
  IF NOT public.is_active_child_development_admin() THEN
    RAISE EXCEPTION 'Only an active Admin may correct a payment';
  END IF;

  IF p_correction_id IS NULL
     OR p_payment_id IS NULL
     OR p_old_amount IS NULL
     OR p_old_amount <= 0
     OR p_new_amount IS NULL
     OR p_new_amount <= 0
     OR p_reason IS NULL
     OR char_length(btrim(p_reason)) = 0 THEN
    RAISE EXCEPTION
      'Correction id, payment id, positive old/new amounts, and reason are required';
  END IF;

  SELECT c.*
    INTO v_existing
    FROM public.cash_payment_corrections c
   WHERE c.id = p_correction_id
   FOR UPDATE;

  IF FOUND THEN
    IF v_existing.payment_id IS DISTINCT FROM p_payment_id
       OR v_existing.old_amount IS DISTINCT FROM p_old_amount
       OR v_existing.new_amount IS DISTINCT FROM p_new_amount
       OR v_existing.correction_type IS DISTINCT FROM 'amount_correction'
       OR v_existing.reason IS DISTINCT FROM btrim(p_reason)
       OR v_existing.corrected_by IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION
        'Correction id was already used with different details';
    END IF;
    RETURN p_correction_id;
  END IF;

  SELECT p.amount
    INTO v_old_amount
    FROM public.cash_payments p
   WHERE p.id = p_payment_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payment % does not exist', p_payment_id;
  END IF;

  IF v_old_amount IS DISTINCT FROM p_old_amount THEN
    RAISE EXCEPTION
      'Expected payment amount does not match the current recorded amount';
  END IF;

  -- Recheck after locking the payment so concurrent retries are idempotent.
  SELECT c.*
    INTO v_existing
    FROM public.cash_payment_corrections c
   WHERE c.id = p_correction_id
   FOR UPDATE;

  IF FOUND THEN
    IF v_existing.payment_id IS DISTINCT FROM p_payment_id
       OR v_existing.old_amount IS DISTINCT FROM p_old_amount
       OR v_existing.new_amount IS DISTINCT FROM p_new_amount
       OR v_existing.correction_type IS DISTINCT FROM 'amount_correction'
       OR v_existing.reason IS DISTINCT FROM btrim(p_reason)
       OR v_existing.corrected_by IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION
        'Correction id was already used with different details';
    END IF;
    RETURN p_correction_id;
  END IF;

  IF p_new_amount = v_old_amount THEN
    RAISE EXCEPTION 'The corrected amount must differ from the current amount';
  END IF;

  SELECT coalesce(sum(a.allocated_amount), 0)
    INTO v_allocated
    FROM public.cash_payment_allocations a
   WHERE a.payment_id = p_payment_id;

  IF v_allocated > p_new_amount THEN
    RAISE EXCEPTION
      'Corrected payment amount cannot be lower than its allocated total';
  END IF;

  INSERT INTO public.cash_payment_corrections (
    id,
    payment_id,
    old_amount,
    new_amount,
    correction_type,
    reason,
    corrected_by
  )
  VALUES (
    p_correction_id,
    p_payment_id,
    v_old_amount,
    p_new_amount,
    'amount_correction',
    btrim(p_reason),
    auth.uid()
  )
  ON CONFLICT (id) DO NOTHING
  RETURNING id INTO v_inserted_id;

  IF v_inserted_id IS NULL THEN
    SELECT c.*
      INTO v_existing
      FROM public.cash_payment_corrections c
     WHERE c.id = p_correction_id;

    IF v_existing.payment_id IS DISTINCT FROM p_payment_id
       OR v_existing.old_amount IS DISTINCT FROM v_old_amount
       OR v_existing.new_amount IS DISTINCT FROM p_new_amount
       OR v_existing.correction_type IS DISTINCT FROM 'amount_correction'
       OR v_existing.reason IS DISTINCT FROM btrim(p_reason)
       OR v_existing.corrected_by IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION
        'Correction id was already used with different details';
    END IF;
    RETURN p_correction_id;
  END IF;

  UPDATE public.cash_payments
     SET amount = p_new_amount
   WHERE id = p_payment_id;

  RETURN p_correction_id;
END;
$function$;

COMMENT ON FUNCTION public.correct_cash_payment_amount(
  uuid, uuid, numeric, numeric, text
) IS
  'Admin-only clerical amount correction with audit; not a refund transaction.';

REVOKE ALL ON FUNCTION public.correct_cash_payment_amount(
  uuid, uuid, numeric, numeric, text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.correct_cash_payment_amount(
  uuid, uuid, numeric, numeric, text
) TO authenticated;

CREATE FUNCTION public.sync_cash_bill_arrears_notification(
  p_bill_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_student_id uuid;
  v_student_name text;
  v_week_start date;
  v_due_date date;
  v_bill_amount numeric;
  v_allocated_amount numeric;
  v_outstanding numeric;
  v_initial_type varchar;
  v_overdue_type varchar;
  v_message text;
BEGIN
  SELECT b.student_id, s.full_name, b.week_start, b.due_date, b.amount
    INTO v_student_id, v_student_name, v_week_start, v_due_date, v_bill_amount
    FROM public.cash_bills b
    JOIN public.students s ON s.id = b.student_id
   WHERE b.id = p_bill_id;

  v_initial_type := 'cash_due:' || p_bill_id::text;
  v_overdue_type := 'cash_late:' || p_bill_id::text;

  IF NOT FOUND THEN
    UPDATE public.notifications n
       SET is_active = false
     WHERE n.notification_type IN (v_initial_type, v_overdue_type);
    RETURN;
  END IF;

  SELECT coalesce(sum(a.allocated_amount), 0)
    INTO v_allocated_amount
    FROM public.cash_payment_allocations a
   WHERE a.bill_id = p_bill_id;

  v_outstanding := v_bill_amount - v_allocated_amount;

  IF v_outstanding <= 0 THEN
    UPDATE public.notifications n
       SET is_active = false
     WHERE n.notification_type IN (v_initial_type, v_overdue_type);
    RETURN;
  END IF;

  UPDATE public.notifications n
     SET is_active = false
   WHERE n.notification_type IN (v_initial_type, v_overdue_type)
     AND NOT EXISTS (
       SELECT 1
         FROM public.student_parents sp
         JOIN public.parents pa ON pa.id = sp.parent_id
         JOIN public.profiles pr ON pr.id = pa.user_id
        WHERE sp.student_id = v_student_id
          AND pr.id = n.user_id
          AND pr.role = 'parent'
          AND pr.is_active = true
     );

  v_message := pg_catalog.format(
    'Tagihan minggu %s untuk %s belum lunas. Sisa tagihan: %s.',
    pg_catalog.to_char(v_week_start, 'YYYY-MM-DD'),
    coalesce(v_student_name, 'anak Anda'),
    v_outstanding::text
  );

  INSERT INTO public.notifications AS existing_notification (
    user_id,
    title,
    message,
    notification_type,
    is_active
  )
  SELECT DISTINCT
    pr.id,
    'Pengingat Kas Mingguan',
    v_message,
    v_initial_type,
    true
  FROM public.student_parents sp
  JOIN public.parents pa ON pa.id = sp.parent_id
  JOIN public.profiles pr ON pr.id = pa.user_id
  WHERE sp.student_id = v_student_id
    AND pr.role = 'parent'
    AND pr.is_active = true
  ON CONFLICT (user_id, notification_type)
    WHERE left(notification_type, 9) = 'cash_due:'
       OR left(notification_type, 10) = 'cash_late:'
  DO UPDATE
     SET title = EXCLUDED.title,
         message = EXCLUDED.message,
         is_active = true;

  IF v_due_date IS NOT NULL AND v_due_date < current_date THEN
    UPDATE public.notifications n
       SET is_active = true
     WHERE n.notification_type = v_overdue_type
       AND EXISTS (
         SELECT 1
           FROM public.student_parents sp
           JOIN public.parents pa ON pa.id = sp.parent_id
           JOIN public.profiles pr ON pr.id = pa.user_id
          WHERE sp.student_id = v_student_id
            AND pr.id = n.user_id
            AND pr.role = 'parent'
            AND pr.is_active = true
       );
  ELSE
    UPDATE public.notifications n
       SET is_active = false
     WHERE n.notification_type = v_overdue_type;
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.sync_cash_bill_arrears_notification(uuid)
  FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.create_overdue_cash_reminders()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_bill record;
  v_notification_type varchar;
  v_message text;
  v_rows_inserted integer;
  v_total_inserted integer := 0;
BEGIN
  FOR v_bill IN
    SELECT
      b.id,
      b.student_id,
      s.full_name,
      b.week_start,
      b.amount - coalesce(sum(a.allocated_amount), 0) AS outstanding_amount
    FROM public.cash_bills b
    JOIN public.students s ON s.id = b.student_id
    LEFT JOIN public.cash_payment_allocations a ON a.bill_id = b.id
    WHERE b.due_date IS NOT NULL
      AND b.due_date < current_date
    GROUP BY
      b.id,
      b.student_id,
      s.full_name,
      b.week_start,
      b.amount,
      b.due_date
    HAVING b.amount > coalesce(sum(a.allocated_amount), 0)
    ORDER BY b.due_date, b.id
  LOOP
    PERFORM public.sync_cash_bill_arrears_notification(v_bill.id);

    v_notification_type := 'cash_late:' || v_bill.id::text;
    v_message := pg_catalog.format(
      'Tagihan minggu %s untuk %s telah melewati jatuh tempo. Sisa tagihan: %s.',
      pg_catalog.to_char(v_bill.week_start, 'YYYY-MM-DD'),
      coalesce(v_bill.full_name, 'anak Anda'),
      v_bill.outstanding_amount::text
    );

    INSERT INTO public.notifications (
      user_id,
      title,
      message,
      notification_type,
      is_active
    )
    SELECT DISTINCT
      pr.id,
      'Tunggakan Kas Mingguan',
      v_message,
      v_notification_type,
      true
    FROM public.student_parents sp
    JOIN public.parents pa ON pa.id = sp.parent_id
    JOIN public.profiles pr ON pr.id = pa.user_id
    WHERE sp.student_id = v_bill.student_id
      AND pr.role = 'parent'
      AND pr.is_active = true
    ON CONFLICT (user_id, notification_type)
      WHERE left(notification_type, 9) = 'cash_due:'
         OR left(notification_type, 10) = 'cash_late:'
    DO NOTHING;

    GET DIAGNOSTICS v_rows_inserted = ROW_COUNT;
    v_total_inserted := v_total_inserted + v_rows_inserted;
  END LOOP;

  RETURN v_total_inserted;
END;
$function$;

COMMENT ON FUNCTION public.create_overdue_cash_reminders() IS
  'Call once daily from a trusted server-side scheduler. Creates one reminder per Parent/bill only when due_date is non-NULL, earlier than current_date, and an outstanding balance remains.';

REVOKE ALL ON FUNCTION public.create_overdue_cash_reminders()
  FROM PUBLIC, anon, authenticated;

DO $scheduler_grant$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE
      'GRANT EXECUTE ON FUNCTION public.create_overdue_cash_reminders() TO service_role';
  END IF;
END;
$scheduler_grant$;

DO $scheduler_check$
DECLARE
  v_available boolean;
  v_installed boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron'
  ) INTO v_available;

  SELECT EXISTS (
    SELECT 1 FROM pg_extension WHERE extname = 'pg_cron'
  ) INTO v_installed;

  IF v_installed THEN
    RAISE NOTICE
      'pg_cron is installed. No job was created; schedule public.create_overdue_cash_reminders() once daily after review.';
  ELSIF v_available THEN
    RAISE NOTICE
      'pg_cron is available but not installed. Enable it only after review, or use a trusted external scheduler.';
  ELSE
    RAISE NOTICE
      'pg_cron is unavailable. Use a trusted server-side scheduler or Supabase Edge Function to invoke public.create_overdue_cash_reminders() once daily.';
  END IF;
END;
$scheduler_check$;

-- Scheduling is deliberately not automatic. If pg_cron is enabled and approved,
-- a DBA can schedule once daily, for example:
-- SELECT cron.schedule(
--   'cash-overdue-reminders',
--   '0 8 * * *',
--   'SELECT public.create_overdue_cash_reminders();'
-- );
-- Without pg_cron, invoke the function once daily from a trusted server-side
-- scheduler/Edge Function; confirm the scheduler timezone and never call it
-- from an unauthenticated frontend.

CREATE FUNCTION public.cash_bill_arrears_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM public.sync_cash_bill_arrears_notification(OLD.id);
  ELSE
    PERFORM public.sync_cash_bill_arrears_notification(NEW.id);
  END IF;

  RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.cash_bill_arrears_trigger()
  FROM PUBLIC, anon, authenticated;

CREATE TRIGGER cash_bills_sync_arrears
AFTER INSERT OR UPDATE OR DELETE ON public.cash_bills
FOR EACH ROW
EXECUTE FUNCTION public.cash_bill_arrears_trigger();

CREATE FUNCTION public.cash_allocation_arrears_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  PERFORM public.sync_cash_bill_arrears_notification(NEW.bill_id);
  RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.cash_allocation_arrears_trigger()
  FROM PUBLIC, anon, authenticated;

CREATE TRIGGER cash_allocations_sync_arrears
AFTER INSERT ON public.cash_payment_allocations
FOR EACH ROW
EXECUTE FUNCTION public.cash_allocation_arrears_trigger();

CREATE FUNCTION public.cash_parent_link_arrears_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_student_id uuid;
  v_bill_id uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_student_id := OLD.student_id;
  ELSE
    IF TG_OP = 'UPDATE'
       AND OLD.student_id IS DISTINCT FROM NEW.student_id THEN
      FOR v_bill_id IN
        SELECT b.id
          FROM public.cash_bills b
         WHERE b.student_id = OLD.student_id
      LOOP
        PERFORM public.sync_cash_bill_arrears_notification(v_bill_id);
      END LOOP;
    END IF;
    v_student_id := NEW.student_id;
  END IF;

  FOR v_bill_id IN
    SELECT b.id
      FROM public.cash_bills b
     WHERE b.student_id = v_student_id
  LOOP
    PERFORM public.sync_cash_bill_arrears_notification(v_bill_id);
  END LOOP;

  RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.cash_parent_link_arrears_trigger()
  FROM PUBLIC, anon, authenticated;

CREATE TRIGGER cash_parent_links_sync_arrears
AFTER INSERT OR UPDATE OR DELETE ON public.student_parents
FOR EACH ROW
EXECUTE FUNCTION public.cash_parent_link_arrears_trigger();

DO $backfill$
DECLARE
  v_bill_id uuid;
BEGIN
  FOR v_bill_id IN
    SELECT b.id
      FROM public.cash_bills b
     ORDER BY b.id
  LOOP
    PERFORM public.sync_cash_bill_arrears_notification(v_bill_id);
  END LOOP;
END;
$backfill$;

NOTIFY pgrst, 'reload schema';
