-- =====================================================================
-- Expo Village Tracker v1. Supabase setup.
-- Paste the whole file into Supabase > SQL Editor and press Run.
-- Safe to re-run: tables are created only if missing, functions and
-- policies are replaced. Placeholder lookups are inserted only if missing.
--
-- Design in one paragraph: every table is read-only to the app.
-- All writes go through the functions in section 4, which check the
-- signed-in staff member's role, apply the workflow rules and write the
-- history rows in the same transaction. The browser key (publishable)
-- therefore cannot bypass the rules even if someone calls the API directly.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------

create table if not exists public.staff (
  id          text primary key check (id ~ '^[A-Z0-9][A-Z0-9-]{0,19}$'),
  user_id     uuid unique references auth.users(id) on delete set null,
  role        text not null check (role in ('cleaner','reception','supervisor')),
  label       text not null default '',
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists public.departments (
  id      text primary key,
  sort    int not null default 0,
  active  boolean not null default true
);

create table if not exists public.priorities (
  level          int primary key check (level between 1 and 9),
  label          text not null,
  alert_minutes  int not null check (alert_minutes > 0)
);

create table if not exists public.categories (
  id                  text primary key check (id ~ '^[a-z0-9_]+$'),
  icon                text not null default '💬',
  label_en            text not null,
  label_sr            text not null default '',
  default_department  text not null references public.departments(id) on update cascade,
  default_priority    int  not null references public.priorities(level),
  sort                int  not null default 0,
  active              boolean not null default true
);

create table if not exists public.rooms (
  id         text primary key,
  building   text not null,
  floor      text not null,
  label      text not null,
  sort       int  not null default 0,
  status     text not null default 'dirty' check (status in ('dirty','clean','inspected','ooo')),
  status_at  timestamptz not null default now(),
  status_by  text,
  active     boolean not null default true
);

create sequence if not exists public.request_seq;

create table if not exists public.requests (
  id               text primary key,
  room_id          text not null references public.rooms(id) on update cascade,
  category_id      text not null references public.categories(id) on update cascade,
  source           text not null check (source in ('Guest call','Walk-in','Staff report','Housekeeping report')),
  description      text not null default '' check (length(description) <= 2000),
  priority         int  not null references public.priorities(level),
  department       text not null references public.departments(id) on update cascade,
  status           text not null default 'Open' check (status in ('Open','In Progress','On Hold','Closed')),
  room_unusable    boolean not null default false,
  photo_path       text,
  created_at       timestamptz not null default now(),
  created_by       text not null,
  updated_at       timestamptz not null default now(),
  closed_at        timestamptz,
  closure_reason   text check (closure_reason in ('Resolved','Duplicate','No action required','Reported in error')),
  duplicate_of     text references public.requests(id),
  -- Response clock (IMP rule): pauses while On Hold, stops at Closed,
  -- carries on from the same point after Reopen.
  clock_paused_at  timestamptz,
  paused_seconds   int not null default 0,
  constraint requests_closed_ck check ((status = 'Closed') = (closed_at is not null and closure_reason is not null)),
  constraint requests_dup_ck check (
    (closure_reason is distinct from 'Duplicate' and duplicate_of is null)
    or (closure_reason = 'Duplicate' and duplicate_of is not null))
);

create table if not exists public.request_events (
  id          bigint generated always as identity primary key,
  request_id  text not null references public.requests(id) on delete cascade,
  at          timestamptz not null default now(),
  by_staff    text not null,
  action      text not null
);

create table if not exists public.room_log (
  id           bigint generated always as identity primary key,
  at           timestamptz not null default now(),
  room_id      text not null references public.rooms(id) on update cascade on delete cascade,
  from_status  text not null,
  to_status    text not null,
  by_staff     text not null,
  note         text not null default '',
  request_id   text
);

create index if not exists requests_status_idx   on public.requests (status);
create index if not exists requests_room_idx     on public.requests (room_id);
create index if not exists requests_closed_idx   on public.requests (closed_at);
create index if not exists req_events_req_idx    on public.request_events (request_id, at);
create index if not exists room_log_room_idx     on public.room_log (room_id, at);
create index if not exists staff_user_idx        on public.staff (user_id);

-- ---------------------------------------------------------------------
-- 2. Placeholder lookups (mirror the demo; replace via the loader)
-- ---------------------------------------------------------------------

insert into public.departments (id, sort) values
  ('Reception',10),('Housekeeping',20),('Maintenance',30),('IT and AV',40),('Security',50)
on conflict (id) do nothing;

insert into public.priorities (level, label, alert_minutes) values
  (1,'P1 Urgent',15),(2,'P2 Today',120),(3,'P3 Routine',1440)
on conflict (level) do nothing;

insert into public.categories (id, icon, label_en, label_sr, default_department, default_priority, sort) values
  ('tv','📺','TV or remote','TV ili daljinski','IT and AV',3,10),
  ('water','🚿','Water or bathroom','Voda ili kupatilo','Maintenance',3,20),
  ('ac','❄️','AC or heating','Klima ili grejanje','Maintenance',3,30),
  ('power','💡','Lights or power','Svetlo ili struja','Maintenance',3,40),
  ('wifi','📶','Wi-Fi','Wi-Fi','IT and AV',3,50),
  ('damage','🛋️','Furniture or damage','Nameštaj ili oštećenje','Maintenance',3,60),
  ('pests','🐜','Insects or pests','Insekti ili štetočine','Housekeeping',2,70),
  ('lost','🎒','Lost property','Izgubljene stvari','Reception',3,80),
  ('safety','⚠️','Safety hazard','Opasnost','Maintenance',1,90),
  ('other','💬','Other','Ostalo','Reception',3,100)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 3. Identity helpers
-- ---------------------------------------------------------------------

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.staff where user_id = auth.uid() and active limit 1
$$;

create or replace function public.my_staff_id() returns text
language sql stable security definer set search_path = public as $$
  select id from public.staff where user_id = auth.uid() and active limit 1
$$;

create or replace function public.my_profile()
returns table (id text, role text, label text)
language sql stable security definer set search_path = public as $$
  select s.id, s.role, s.label from public.staff s where s.user_id = auth.uid() and s.active limit 1
$$;

create or replace function public.server_time() returns timestamptz
language sql stable as $$ select now() $$;

-- Internal: returns the caller's staff row or raises.
create or replace function public._actor(p_roles text[] default array['cleaner','reception','supervisor'])
returns public.staff
language plpgsql stable security definer set search_path = public as $$
declare s public.staff;
begin
  select * into s from public.staff where user_id = auth.uid() and active;
  if not found then
    raise exception 'You are not signed in as active staff.' using errcode = '42501';
  end if;
  if not (s.role = any (p_roles)) then
    raise exception 'Your role (%) cannot do this.', s.role using errcode = '42501';
  end if;
  return s;
end $$;

-- Internal: change a room's status and log it. No role checks here.
create or replace function public._set_room(p_room text, p_to text, p_by text, p_note text, p_request text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_from text;
begin
  select status into v_from from public.rooms where id = p_room for update;
  if v_from is null or v_from = p_to then return; end if;
  insert into public.room_log (room_id, from_status, to_status, by_staff, note, request_id)
  values (p_room, v_from, p_to, p_by, coalesce(p_note,''), p_request);
  update public.rooms set status = p_to, status_at = now(), status_by = p_by where id = p_room;
end $$;

-- Internal: next request ID, EXV-0001 style (no truncation past 9999).
create or replace function public._next_request_id() returns text
language plpgsql security definer set search_path = public as $$
declare n bigint := nextval('public.request_seq');
begin
  return 'EXV-' || case when n < 10000 then lpad(n::text, 4, '0') else n::text end;
end $$;

-- ---------------------------------------------------------------------
-- 4. Actions (the only way the app writes data)
-- ---------------------------------------------------------------------

-- Room status.
--   cleaner:    Dirty to Clean, and Clean back to Dirty (undo). Nothing else.
--   reception:  Dirty, Clean, Out of order (not Inspected).
--   supervisor: any state including Inspected.
create or replace function public.set_room_status(p_room text, p_status text, p_note text default '')
returns public.rooms
language plpgsql security definer set search_path = public as $$
declare s public.staff; r public.rooms;
begin
  s := public._actor();
  if p_status not in ('dirty','clean','inspected','ooo') then
    raise exception 'Unknown room status %.', p_status;
  end if;
  select * into r from public.rooms where id = p_room and active for update;
  if not found then raise exception 'Room % not found.', p_room; end if;
  if p_status = 'inspected' and s.role <> 'supervisor' then
    raise exception 'Only a supervisor can set Inspected.' using errcode = '42501';
  end if;
  if s.role = 'cleaner' and not (r.status in ('dirty','clean') and p_status in ('dirty','clean')) then
    raise exception 'Cleaners can only mark a Dirty room as Clean.' using errcode = '42501';
  end if;
  perform public._set_room(p_room, p_status, s.id, left(coalesce(p_note,''), 200), null);
  select * into r from public.rooms where id = p_room;
  return r;
end $$;

-- New request. Cleaners: source is always Housekeeping report and
-- priority/department come from the category. "Room cannot be used"
-- sets the room Out of order and lifts priority to at least P2.
create or replace function public.create_request(
  p_room text, p_category text, p_source text default null, p_description text default '',
  p_priority int default null, p_department text default null,
  p_unusable boolean default false, p_photo_path text default null)
returns public.requests
language plpgsql security definer set search_path = public as $$
declare s public.staff; c public.categories; v_src text; v_pri int; v_dept text; v_id text; t public.requests;
begin
  s := public._actor();
  perform 1 from public.rooms where id = p_room and active;
  if not found then raise exception 'Room % not found.', p_room; end if;
  select * into c from public.categories where id = p_category and active;
  if not found then raise exception 'Unknown category %.', p_category; end if;

  if s.role = 'cleaner' then
    v_src := 'Housekeeping report'; v_pri := c.default_priority; v_dept := c.default_department;
  else
    v_src := coalesce(nullif(p_source,''), 'Staff report');
    v_pri := coalesce(p_priority, c.default_priority);
    v_dept := coalesce(nullif(p_department,''), c.default_department);
  end if;
  if coalesce(p_unusable,false) and exists (select 1 from public.priorities where level = 2) then
    v_pri := least(v_pri, 2);
  end if;
  if p_photo_path is not null and left(p_photo_path, length(s.id) + 1) <> s.id || '/' then
    raise exception 'Photo path must start with your staff ID.';
  end if;

  v_id := public._next_request_id();
  insert into public.requests (id, room_id, category_id, source, description, priority, department,
                               room_unusable, photo_path, created_by)
  values (v_id, p_room, p_category, v_src, left(coalesce(trim(p_description),''), 2000), v_pri, v_dept,
          coalesce(p_unusable,false), p_photo_path, s.id)
  returning * into t;
  insert into public.request_events (request_id, by_staff, action)
  values (v_id, s.id, 'Created from ' || lower(v_src));
  if t.room_unusable then
    perform public._set_room(p_room, 'ooo', s.id, v_id, v_id);
  end if;
  return t;
end $$;

-- Priority or department change (reception, supervisor).
create or replace function public.update_request(p_id text, p_priority int default null, p_department text default null)
returns public.requests
language plpgsql security definer set search_path = public as $$
declare s public.staff; t public.requests; v_label text;
begin
  s := public._actor(array['reception','supervisor']);
  select * into t from public.requests where id = p_id for update;
  if not found then raise exception 'Request % not found.', p_id; end if;
  if t.status = 'Closed' then raise exception 'Request % is closed.', p_id; end if;
  if p_priority is not null and p_priority <> t.priority then
    select label into v_label from public.priorities where level = p_priority;
    if v_label is null then raise exception 'Unknown priority %.', p_priority; end if;
    update public.requests set priority = p_priority, updated_at = now() where id = p_id;
    insert into public.request_events (request_id, by_staff, action) values (p_id, s.id, 'Priority set to ' || v_label);
  end if;
  if p_department is not null and p_department <> t.department then
    perform 1 from public.departments where id = p_department;
    if not found then raise exception 'Unknown department %.', p_department; end if;
    update public.requests set department = p_department, updated_at = now() where id = p_id;
    insert into public.request_events (request_id, by_staff, action) values (p_id, s.id, 'Assigned to ' || p_department);
  end if;
  select * into t from public.requests where id = p_id;
  return t;
end $$;

-- Status moves: Open to In Progress or On Hold; In Progress to On Hold;
-- On Hold to In Progress. Closing and reopening have their own functions.
create or replace function public.set_request_status(p_id text, p_status text, p_reason text default '')
returns public.requests
language plpgsql security definer set search_path = public as $$
declare s public.staff; t public.requests; ok boolean; v_reason text := trim(coalesce(p_reason,''));
begin
  s := public._actor(array['reception','supervisor']);
  select * into t from public.requests where id = p_id for update;
  if not found then raise exception 'Request % not found.', p_id; end if;
  ok := (t.status = 'Open' and p_status in ('In Progress','On Hold'))
     or (t.status = 'In Progress' and p_status = 'On Hold')
     or (t.status = 'On Hold' and p_status = 'In Progress');
  if not ok then raise exception 'Cannot move % from % to %.', p_id, t.status, p_status; end if;

  if p_status = 'On Hold' then
    update public.requests set status = p_status, clock_paused_at = coalesce(clock_paused_at, now()), updated_at = now()
    where id = p_id;
  else
    update public.requests
       set status = p_status,
           paused_seconds = paused_seconds + coalesce(extract(epoch from now() - clock_paused_at)::int, 0),
           clock_paused_at = null, updated_at = now()
     where id = p_id;
  end if;
  insert into public.request_events (request_id, by_staff, action)
  values (p_id, s.id, 'Status changed to ' || p_status || case when p_status = 'On Hold' and v_reason <> '' then ': ' || left(v_reason,300) else '' end);
  select * into t from public.requests where id = p_id;
  return t;
end $$;

-- Close with one of the four IMP closure reasons. Optionally return an
-- Out of order room to service as Dirty.
create or replace function public.close_request(
  p_id text, p_reason text, p_duplicate_of text default null, p_note text default '', p_return_room boolean default false)
returns public.requests
language plpgsql security definer set search_path = public as $$
declare s public.staff; t public.requests; v_dup text := upper(trim(coalesce(p_duplicate_of,''))); v_note text := trim(coalesce(p_note,''));
begin
  s := public._actor(array['reception','supervisor']);
  select * into t from public.requests where id = p_id for update;
  if not found then raise exception 'Request % not found.', p_id; end if;
  if t.status = 'Closed' then raise exception 'Request % is already closed.', p_id; end if;
  if p_reason not in ('Resolved','Duplicate','No action required','Reported in error') then
    raise exception 'Unknown closure reason %.', p_reason;
  end if;
  if p_reason = 'Duplicate' then
    if v_dup = '' or v_dup = p_id then raise exception 'Enter the ID of the other request.'; end if;
    perform 1 from public.requests where id = v_dup;
    if not found then raise exception 'Request % not found.', v_dup; end if;
  else
    v_dup := null;
  end if;

  update public.requests
     set status = 'Closed', closed_at = now(), closure_reason = p_reason, duplicate_of = v_dup,
         clock_paused_at = coalesce(clock_paused_at, now()), updated_at = now()
   where id = p_id;
  insert into public.request_events (request_id, by_staff, action)
  values (p_id, s.id, 'Closed: ' || case when v_dup is not null then 'Duplicate of ' || v_dup else p_reason end
                      || case when v_note <> '' then '. ' || left(v_note,500) else '' end);
  if coalesce(p_return_room,false) and (select status from public.rooms where id = t.room_id) = 'ooo' then
    perform public._set_room(t.room_id, 'dirty', s.id, 'Returned to service by ' || p_id, p_id);
  end if;
  select * into t from public.requests where id = p_id;
  return t;
end $$;

-- Reopen: supervisor only. Same record, clock carries on from where it stopped.
create or replace function public.reopen_request(p_id text, p_note text default '')
returns public.requests
language plpgsql security definer set search_path = public as $$
declare s public.staff; t public.requests; v_note text := trim(coalesce(p_note,''));
begin
  s := public._actor(array['supervisor']);
  select * into t from public.requests where id = p_id for update;
  if not found then raise exception 'Request % not found.', p_id; end if;
  if t.status <> 'Closed' then raise exception 'Request % is not closed.', p_id; end if;
  update public.requests
     set status = 'Open', closed_at = null, closure_reason = null, duplicate_of = null,
         paused_seconds = paused_seconds + coalesce(extract(epoch from now() - clock_paused_at)::int, 0),
         clock_paused_at = null, updated_at = now()
   where id = p_id;
  insert into public.request_events (request_id, by_staff, action)
  values (p_id, s.id, 'Reopened by supervisor' || case when v_note <> '' then ': ' || left(v_note,300) else '' end);
  select * into t from public.requests where id = p_id;
  return t;
end $$;

-- Free-text note on the history (reception, supervisor).
create or replace function public.add_request_note(p_id text, p_note text)
returns public.requests
language plpgsql security definer set search_path = public as $$
declare s public.staff; t public.requests; v_note text := trim(coalesce(p_note,''));
begin
  s := public._actor(array['reception','supervisor']);
  if v_note = '' then raise exception 'Note is empty.'; end if;
  update public.requests set updated_at = now() where id = p_id returning * into t;
  if not found then raise exception 'Request % not found.', p_id; end if;
  insert into public.request_events (request_id, by_staff, action) values (p_id, s.id, 'Note: ' || left(v_note,1000));
  return t;
end $$;

-- ---------------------------------------------------------------------
-- 5. Grants and row level security
-- ---------------------------------------------------------------------

grant usage on schema public to authenticated, service_role;

do $$
declare t text;
begin
  foreach t in array array['staff','departments','priorities','categories','rooms','requests','request_events','room_log'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon, authenticated', t);
    execute format('grant select on table public.%I to authenticated', t);
    execute format('grant all on table public.%I to service_role', t);
  end loop;
end $$;
grant usage, select on sequence public.request_seq to service_role;

-- Read access: any active staff member reads everything except the staff table,
-- where each person sees only their own row. No write policies exist on purpose.
do $$
declare t text;
begin
  foreach t in array array['departments','priorities','categories','rooms','requests','request_events','room_log'] loop
    execute format('drop policy if exists "exv staff read" on public.%I', t);
    execute format('create policy "exv staff read" on public.%I for select to authenticated using ((select public.my_role()) is not null)', t);
  end loop;
end $$;
drop policy if exists "exv own row" on public.staff;
create policy "exv own row" on public.staff for select to authenticated using (user_id = (select auth.uid()));

-- Function access: public actions to signed-in users only; internals to nobody.
revoke execute on function public._actor(text[])                          from public, anon, authenticated;
revoke execute on function public._set_room(text,text,text,text,text)     from public, anon, authenticated;
revoke execute on function public._next_request_id()                      from public, anon, authenticated;

revoke execute on function public.my_role()                               from public, anon;
revoke execute on function public.my_staff_id()                           from public, anon;
revoke execute on function public.my_profile()                            from public, anon;
revoke execute on function public.server_time()                           from public, anon;
revoke execute on function public.set_room_status(text,text,text)         from public, anon;
revoke execute on function public.create_request(text,text,text,text,int,text,boolean,text) from public, anon;
revoke execute on function public.update_request(text,int,text)           from public, anon;
revoke execute on function public.set_request_status(text,text,text)      from public, anon;
revoke execute on function public.close_request(text,text,text,text,boolean) from public, anon;
revoke execute on function public.reopen_request(text,text)               from public, anon;
revoke execute on function public.add_request_note(text,text)             from public, anon;

grant execute on function public.my_role()                               to authenticated;
grant execute on function public.my_staff_id()                           to authenticated;
grant execute on function public.my_profile()                            to authenticated;
grant execute on function public.server_time()                           to authenticated;
grant execute on function public.set_room_status(text,text,text)         to authenticated;
grant execute on function public.create_request(text,text,text,text,int,text,boolean,text) to authenticated;
grant execute on function public.update_request(text,int,text)           to authenticated;
grant execute on function public.set_request_status(text,text,text)      to authenticated;
grant execute on function public.close_request(text,text,text,text,boolean) to authenticated;
grant execute on function public.reopen_request(text,text)               to authenticated;
grant execute on function public.add_request_note(text,text)             to authenticated;

-- ---------------------------------------------------------------------
-- 6. Realtime: push room and request changes to signed-in screens
-- ---------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'rooms') then
    alter publication supabase_realtime add table public.rooms;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'requests') then
    alter publication supabase_realtime add table public.requests;
  end if;
end $$;

commit;

-- ---------------------------------------------------------------------
-- 7. Photo storage: private bucket, staff can upload into their own
--    folder (STAFF-ID/...) and read all photos. No update or delete.
--    Runs after the commit above, so if this part errors the core setup
--    is still in place. See SETUP.md step 3 for the dashboard fallback.
-- ---------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('request-photos', 'request-photos', false, 2097152, array['image/jpeg'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "exv photos read" on storage.objects;
create policy "exv photos read" on storage.objects for select to authenticated
  using (bucket_id = 'request-photos' and (select public.my_role()) is not null);

drop policy if exists "exv photos upload" on storage.objects;
create policy "exv photos upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'request-photos'
              and (select public.my_role()) is not null
              and (storage.foldername(name))[1] = (select public.my_staff_id()));
