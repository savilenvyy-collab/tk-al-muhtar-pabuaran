-- ============================================================
-- RLS untuk public.daily_reports
-- ============================================================

alter table public.daily_reports enable row level security;

drop policy if exists "daily_reports_select_admin"
  on public.daily_reports;

drop policy if exists "daily_reports_select_guru"
  on public.daily_reports;

drop policy if exists "daily_reports_select_parent"
  on public.daily_reports;

drop policy if exists "daily_reports_insert_guru"
  on public.daily_reports;

drop policy if exists "daily_reports_update_guru"
  on public.daily_reports;

-- Admin aktif dapat membaca seluruh laporan harian.
create policy "daily_reports_select_admin"
  on public.daily_reports
  for select
  to authenticated
  using (
    public.is_active_child_development_admin()
  );

-- Guru aktif dapat membaca seluruh laporan harian.
create policy "daily_reports_select_guru"
  on public.daily_reports
  for select
  to authenticated
  using (
    public.is_active_child_development_guru()
  );

-- Parent aktif hanya dapat membaca laporan anak yang terhubung.
create policy "daily_reports_select_parent"
  on public.daily_reports
  for select
  to authenticated
  using (
    public.is_child_development_parent_for(student_id)
  );

-- Guru aktif dapat membuat laporan harian miliknya.
create policy "daily_reports_insert_guru"
  on public.daily_reports
  for insert
  to authenticated
  with check (
    public.is_active_child_development_guru()
    and recorded_by = auth.uid()
  );

-- Guru aktif dapat mengedit laporan harian apa pun.
create policy "daily_reports_update_guru"
  on public.daily_reports
  for update
  to authenticated
  using (
    public.is_active_child_development_guru()
  )
  with check (
    public.is_active_child_development_guru()
  );

-- Privilege tabel
REVOKE ALL
ON TABLE public.daily_reports
FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE
ON TABLE public.daily_reports
TO authenticated;

REVOKE DELETE
ON TABLE public.daily_reports
FROM PUBLIC, anon, authenticated;
