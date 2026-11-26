-- ============================================================
-- Laporan Perkembangan Anak per Semester
-- ============================================================

create table if not exists public.child_development_reports (
  id uuid primary key default gen_random_uuid(),

  student_id uuid not null,
  academic_year text not null,
  semester smallint not null,

  religious_moral text not null,
  physical_motor text not null,
  cognitive text not null,
  language text not null,
  social_emotional text not null,
  art text not null,

  teacher_notes text,

  recorded_by uuid not null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint child_development_reports_student_fk
    foreign key (student_id)
    references public.students(id)
    on delete restrict,

  constraint child_development_reports_recorded_by_fk
    foreign key (recorded_by)
    references public.profiles(id)
    on delete restrict,

  constraint child_development_reports_semester_check
    check (semester in (1, 2)),

  constraint child_development_reports_academic_year_check
    check (
      char_length(btrim(academic_year)) = 9
      and academic_year ~ '^[0-9]{4}/[0-9]{4}$'
    ),

  constraint child_development_reports_religious_moral_check
    check (char_length(btrim(religious_moral)) > 0),

  constraint child_development_reports_physical_motor_check
    check (char_length(btrim(physical_motor)) > 0),

  constraint child_development_reports_cognitive_check
    check (char_length(btrim(cognitive)) > 0),

  constraint child_development_reports_language_check
    check (char_length(btrim(language)) > 0),

  constraint child_development_reports_social_emotional_check
    check (char_length(btrim(social_emotional)) > 0),

  constraint child_development_reports_art_check
    check (char_length(btrim(art)) > 0),

  constraint child_development_reports_unique_period
    unique (student_id, academic_year, semester)
);

create index if not exists child_development_reports_student_period_idx
  on public.child_development_reports (
    student_id,
    academic_year,
    semester
  );

-- ============================================================
-- Helper RLS
-- ============================================================

create or replace function public.is_active_child_development_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.role = 'admin'
      and p.is_active = true
  );
$$;

create or replace function public.is_active_child_development_guru()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.role = 'guru'
      and p.is_active = true
  );
$$;

create or replace function public.is_child_development_parent_for(
  report_student_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.parents pa
    join public.student_parents sp
      on sp.parent_id = pa.id
    join public.profiles p
      on p.id = pa.user_id
    where pa.user_id = auth.uid()
      and p.role = 'parent'
      and p.is_active = true
      and sp.student_id = report_student_id
  );
$$;

revoke execute on function
  public.is_active_child_development_admin()
  from public, anon;

revoke execute on function
  public.is_active_child_development_guru()
  from public, anon;

revoke execute on function
  public.is_child_development_parent_for(uuid)
  from public, anon;

grant execute on function
  public.is_active_child_development_admin()
  to authenticated;

grant execute on function
  public.is_active_child_development_guru()
  to authenticated;

grant execute on function
  public.is_child_development_parent_for(uuid)
  to authenticated;

-- ============================================================
-- Perlindungan identitas dan audit laporan
-- ============================================================

create or replace function
  public.set_child_development_report_audit_fields()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.id := old.id;
  new.created_at := old.created_at;

  new.recorded_by := old.recorded_by;
  new.student_id := old.student_id;
  new.academic_year := old.academic_year;
  new.semester := old.semester;
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

revoke all on function
  public.set_child_development_report_audit_fields()
  from public, anon, authenticated;

drop trigger if exists
  child_development_reports_set_audit_fields
  on public.child_development_reports;

create trigger child_development_reports_set_audit_fields
before update on public.child_development_reports
for each row
execute function
  public.set_child_development_report_audit_fields();

-- ============================================================
-- Aktifkan RLS
-- ============================================================

alter table public.child_development_reports
enable row level security;

drop policy if exists
  "child_development_reports_select_admin"
  on public.child_development_reports;

drop policy if exists
  "child_development_reports_select_guru"
  on public.child_development_reports;

drop policy if exists
  "child_development_reports_select_parent"
  on public.child_development_reports;

drop policy if exists
  "child_development_reports_insert_guru"
  on public.child_development_reports;

drop policy if exists
  "child_development_reports_update_guru"
  on public.child_development_reports;

-- Admin aktif dapat membaca seluruh laporan.
create policy "child_development_reports_select_admin"
  on public.child_development_reports
  for select
  to authenticated
  using (
    public.is_active_child_development_admin()
  );

-- Guru aktif dapat membaca seluruh laporan.
create policy "child_development_reports_select_guru"
  on public.child_development_reports
  for select
  to authenticated
  using (
    public.is_active_child_development_guru()
  );

-- Ayah atau Ibu aktif hanya dapat membaca laporan anak yang terhubung.
create policy "child_development_reports_select_parent"
  on public.child_development_reports
  for select
  to authenticated
  using (
    public.is_child_development_parent_for(student_id)
  );

-- Guru aktif dapat membuat satu laporan per periode.
create policy "child_development_reports_insert_guru"
  on public.child_development_reports
  for insert
  to authenticated
  with check (
    public.is_active_child_development_guru()
    and recorded_by = auth.uid()
  );

-- Guru aktif dapat mengedit laporan apa pun.
create policy "child_development_reports_update_guru"
  on public.child_development_reports
  for update
  to authenticated
  using (
    public.is_active_child_development_guru()
  )
  with check (
    public.is_active_child_development_guru()
  );

-- ============================================================
-- Privilege dasar dan pembatasan akses efektif
-- ============================================================

revoke all
  on table public.child_development_reports
  from anon;

revoke all
  on table public.child_development_reports
  from authenticated;

grant select
  on table public.child_development_reports
  to authenticated;

grant insert, update
  on table public.child_development_reports
  to authenticated;
