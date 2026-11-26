create table if not exists public.school_holidays (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  start_date date not null,
  end_date date not null,
  description text,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint school_holidays_valid_range
    check (end_date >= start_date),

  constraint school_holidays_name_length
    check (char_length(btrim(name)) between 1 and 150),

  constraint school_holidays_description_length
    check (description is null or char_length(description) <= 2000)
);

create index if not exists school_holidays_start_date_idx
  on public.school_holidays (start_date);

create index if not exists school_holidays_end_date_idx
  on public.school_holidays (end_date);

create or replace function public.is_active_holiday_admin()
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

create or replace function public.is_active_holiday_reader()
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
      and p.role in ('admin', 'guru', 'parent')
      and p.is_active = true
  );
$$;

revoke execute on function public.is_active_holiday_admin()
  from public, anon;
revoke execute on function public.is_active_holiday_reader()
  from public, anon;

grant execute on function public.is_active_holiday_admin()
  to authenticated;
grant execute on function public.is_active_holiday_reader()
  to authenticated;

create or replace function public.set_school_holidays_audit_fields()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.created_by := old.created_by;
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

revoke all on function public.set_school_holidays_audit_fields()
  from public, anon, authenticated;

drop trigger if exists school_holidays_set_audit_fields
  on public.school_holidays;

create trigger school_holidays_set_audit_fields
before update on public.school_holidays
for each row
execute function public.set_school_holidays_audit_fields();

alter table public.school_holidays enable row level security;

drop policy if exists "school_holidays_select_active_reader"
  on public.school_holidays;
drop policy if exists "school_holidays_insert_active_admin"
  on public.school_holidays;
drop policy if exists "school_holidays_update_active_admin"
  on public.school_holidays;
drop policy if exists "school_holidays_delete_active_admin"
  on public.school_holidays;

create policy "school_holidays_select_active_reader"
  on public.school_holidays
  for select
  to authenticated
  using (public.is_active_holiday_reader());

create policy "school_holidays_insert_active_admin"
  on public.school_holidays
  for insert
  to authenticated
  with check (
    public.is_active_holiday_admin()
    and created_by = auth.uid()
  );

create policy "school_holidays_update_active_admin"
  on public.school_holidays
  for update
  to authenticated
  using (public.is_active_holiday_admin())
  with check (public.is_active_holiday_admin());

create policy "school_holidays_delete_active_admin"
  on public.school_holidays
  for delete
  to authenticated
  using (public.is_active_holiday_admin());

revoke all on table public.school_holidays
  from anon;

grant select, insert, update, delete
  on public.school_holidays
  to authenticated;
