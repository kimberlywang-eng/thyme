-- =====================================================================
-- Thyme shared events: database schema and access rules for Supabase.
-- Run this ONCE in the Supabase dashboard: SQL Editor > New query > paste > Run.
-- Safe to re-run (it uses "if not exists" / "create or replace").
--
-- How access works (no accounts):
--   * The three tables are locked down completely: Row Level Security is on and
--     there are NO policies, so the public "anon" key can never read or write
--     them directly.
--   * The app talks only to the functions below (called with supabase.rpc).
--     They run with elevated rights, but each one checks the secret it needs:
--       - the event CODE (like a room key) to read an event,
--       - a per-person member token (secret, kept on that person's device)
--         to change anything,
--       - a host member token for host-only actions.
--   * Live updates use Realtime "broadcast" on the topic  event:<CODE>  which
--     carries no recipe data, only a "something changed" ping.
-- Events expire after 14 days and are cleaned up automatically.
-- =====================================================================

create table if not exists public.events (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  title      text not null default 'Dinner',
  serve_at   timestamptz,
  cfg        jsonb not null default '{}'::jsonb,
  dishes     jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '14 days'),
  constraint events_title_len check (char_length(title) between 1 and 80),
  constraint events_dishes_array check (jsonb_typeof(dishes) = 'array'),
  constraint events_dishes_size check (pg_column_size(dishes) < 300000),
  constraint events_cfg_size check (pg_column_size(cfg) < 4000)
);
create index if not exists events_expires_idx on public.events (expires_at);

create table if not exists public.members (
  id        uuid primary key default gen_random_uuid(),
  event_id  uuid not null references public.events(id) on delete cascade,
  name      text not null,
  token     text not null,
  is_host   boolean not null default false,
  color     int  not null default 0,
  joined_at timestamptz not null default now(),
  constraint members_name_len check (char_length(name) between 1 and 40)
);
create index if not exists members_event_idx on public.members (event_id);

create table if not exists public.tasks (
  event_id   uuid not null references public.events(id) on delete cascade,
  task_key   text not null,
  assignee   uuid references public.members(id) on delete set null,
  status     text not null default 'pending',
  started_at timestamptz,
  done_at    timestamptz,
  updated_by uuid references public.members(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (event_id, task_key),
  constraint tasks_key_len check (char_length(task_key) between 1 and 80),
  constraint tasks_status check (status in ('pending','running','done'))
);

-- Lock the tables: RLS on, no policies, no direct privileges for the public roles.
alter table public.events  enable row level security;
alter table public.members enable row level security;
alter table public.tasks   enable row level security;
revoke all on table public.events, public.members, public.tasks from public, anon, authenticated;

-- ---------------------------------------------------------------- helpers
-- (internal; not callable from the app)
create or replace function public._thyme_code() returns text
language plpgsql set search_path = public, pg_temp as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';   -- no 0/O/1/I/L
  b bytea; c text; i int;
begin
  loop
    b := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
    c := '';
    for i in 0..7 loop
      c := c || substr(alphabet, 1 + (get_byte(b, i) % 31), 1);
    end loop;
    exit when not exists (select 1 from public.events e where e.code = c);
  end loop;
  return c;
end $$;

create or replace function public._thyme_token() returns text
language sql set search_path = public, pg_temp as $$
  select replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
$$;

create or replace function public._thyme_event(p_code text) returns public.events
language plpgsql set search_path = public, pg_temp as $$
declare e public.events;
begin
  select * into e from public.events
   where code = upper(btrim(coalesce(p_code, ''))) and expires_at > now();
  if not found then raise exception 'Event not found or expired' using errcode = 'P0002'; end if;
  return e;
end $$;

create or replace function public._thyme_member(p_event uuid, p_token text) returns public.members
language plpgsql set search_path = public, pg_temp as $$
declare m public.members;
begin
  select * into m from public.members
   where event_id = p_event and token = coalesce(p_token, '');
  if not found then raise exception 'You are not part of this event' using errcode = '42501'; end if;
  return m;
end $$;

create or replace function public._thyme_notify(p_code text) returns void
language plpgsql set search_path = public, pg_temp as $$
begin
  -- Broadcast a bare "changed" ping so open phones refresh. Never fatal.
  begin
    perform realtime.send(jsonb_build_object('t', extract(epoch from now())), 'changed', 'event:' || p_code, false);
  exception when others then null;
  end;
end $$;

-- ---------------------------------------------------------------- app functions
create or replace function public.create_event(
  p_title text, p_serve_at timestamptz, p_cfg jsonb, p_dishes jsonb, p_name text
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.events; m public.members; tok text;
begin
  if p_name is null or char_length(btrim(p_name)) not between 1 and 40 then raise exception 'Please enter your name (1-40 characters)'; end if;
  if jsonb_typeof(p_dishes) is distinct from 'array' then raise exception 'Dishes must be a list'; end if;
  if jsonb_array_length(p_dishes) > 40 then raise exception 'Too many dishes'; end if;
  if (select count(*) from public.events where expires_at > now()) > 20000 then raise exception 'Thyme is busy, try again later'; end if;
  delete from public.events where expires_at < now() - interval '1 day';   -- opportunistic cleanup
  insert into public.events (code, title, serve_at, cfg, dishes)
  values (public._thyme_code(), left(coalesce(nullif(btrim(p_title), ''), 'Dinner'), 80), p_serve_at,
          coalesce(p_cfg, '{}'::jsonb), p_dishes)
  returning * into e;
  tok := public._thyme_token();
  insert into public.members (event_id, name, token, is_host, color)
  values (e.id, left(btrim(p_name), 40), tok, true, 0) returning * into m;
  return jsonb_build_object('code', e.code, 'member_id', m.id, 'member_token', tok, 'is_host', true);
end $$;

create or replace function public.join_event(p_code text, p_name text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.events; m public.members; tok text; n int;
begin
  e := public._thyme_event(p_code);
  if p_name is null or char_length(btrim(p_name)) not between 1 and 40 then raise exception 'Please enter your name (1-40 characters)'; end if;
  select count(*) into n from public.members where event_id = e.id;
  if n >= 40 then raise exception 'This event is full'; end if;
  tok := public._thyme_token();
  insert into public.members (event_id, name, token, is_host, color)
  values (e.id, left(btrim(p_name), 40), tok, false, n % 8) returning * into m;
  perform public._thyme_notify(e.code);
  return jsonb_build_object('code', e.code, 'member_id', m.id, 'member_token', tok, 'is_host', false);
end $$;

-- Everything a phone needs to draw the event. Never returns tokens.
create or replace function public.event_state(p_code text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.events;
begin
  e := public._thyme_event(p_code);
  return jsonb_build_object(
    'event', jsonb_build_object('code', e.code, 'title', e.title, 'serve_at', e.serve_at, 'cfg', e.cfg,
                                'dishes', e.dishes, 'updated_at', e.updated_at, 'expires_at', e.expires_at),
    'members', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'color', m.color, 'is_host', m.is_host) order by m.joined_at)
                           from public.members m where m.event_id = e.id), '[]'::jsonb),
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('task_key', t.task_key, 'assignee', t.assignee, 'status', t.status,
                                'started_at', t.started_at, 'done_at', t.done_at, 'updated_by', t.updated_by))
                         from public.tasks t where t.event_id = e.id), '[]'::jsonb),
    'server_time', now());
end $$;

-- Host only: replace the shared menu and settings.
create or replace function public.update_plan(
  p_code text, p_member_token text, p_title text, p_serve_at timestamptz, p_cfg jsonb, p_dishes jsonb
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.events; m public.members;
begin
  e := public._thyme_event(p_code);
  m := public._thyme_member(e.id, p_member_token);
  if not m.is_host then raise exception 'Only the host can change the plan' using errcode = '42501'; end if;
  if jsonb_typeof(p_dishes) is distinct from 'array' then raise exception 'Dishes must be a list'; end if;
  if jsonb_array_length(p_dishes) > 40 then raise exception 'Too many dishes'; end if;
  update public.events
     set title = left(coalesce(nullif(btrim(p_title), ''), title), 80), serve_at = p_serve_at,
         cfg = coalesce(p_cfg, cfg), dishes = p_dishes, updated_at = now()
   where id = e.id;
  perform public._thyme_notify(e.code);
end $$;

-- Assign (or unassign) tasks. The host can assign anyone; others can only take
-- a task for themselves or release one they hold.
create or replace function public.set_assignee(
  p_code text, p_member_token text, p_task_keys text[], p_assignee uuid
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.events; m public.members; k text; cur uuid;
begin
  e := public._thyme_event(p_code);
  m := public._thyme_member(e.id, p_member_token);
  if p_task_keys is null or array_length(p_task_keys, 1) is null or array_length(p_task_keys, 1) > 200 then raise exception 'Nothing to assign'; end if;
  if p_assignee is not null and not exists (select 1 from public.members x where x.id = p_assignee and x.event_id = e.id) then
    raise exception 'That person is not in this event';
  end if;
  if (select count(*) from public.tasks where event_id = e.id) > 1000 then raise exception 'Too many tasks'; end if;
  foreach k in array p_task_keys loop
    if char_length(k) not between 1 and 80 then raise exception 'Bad task'; end if;
    select assignee into cur from public.tasks where event_id = e.id and task_key = k;
    if not m.is_host then
      if p_assignee is not null and p_assignee <> m.id then raise exception 'You can only take tasks for yourself' using errcode = '42501'; end if;
      if cur is not null and cur <> m.id then raise exception 'That task belongs to someone else' using errcode = '42501'; end if;
    end if;
    insert into public.tasks (event_id, task_key, assignee, updated_by, updated_at)
    values (e.id, k, p_assignee, m.id, now())
    on conflict (event_id, task_key) do update set assignee = excluded.assignee, updated_by = m.id, updated_at = now();
  end loop;
  perform public._thyme_notify(e.code);
end $$;

-- Mark a task pending / running / done. Allowed for the assignee, the host,
-- or anyone if the task has no assignee yet.
create or replace function public.set_status(
  p_code text, p_member_token text, p_task_key text, p_status text
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.events; m public.members; cur uuid; has boolean;
begin
  e := public._thyme_event(p_code);
  m := public._thyme_member(e.id, p_member_token);
  if p_status not in ('pending', 'running', 'done') then raise exception 'Bad status'; end if;
  if p_task_key is null or char_length(p_task_key) not between 1 and 80 then raise exception 'Bad task'; end if;
  select assignee, true into cur, has from public.tasks where event_id = e.id and task_key = p_task_key;
  if coalesce(has, false) and cur is not null and cur <> m.id and not m.is_host then
    raise exception 'That task belongs to someone else' using errcode = '42501';
  end if;
  insert into public.tasks (event_id, task_key, assignee, status, started_at, done_at, updated_by, updated_at)
  values (e.id, p_task_key, null, p_status,
          case when p_status in ('running', 'done') then now() end,
          case when p_status = 'done' then now() end, m.id, now())
  on conflict (event_id, task_key) do update set
    status     = excluded.status,
    started_at = case when excluded.status = 'pending' then null else coalesce(public.tasks.started_at, now()) end,
    done_at    = case when excluded.status = 'done' then now() else null end,
    updated_by = m.id, updated_at = now();
  perform public._thyme_notify(e.code);
end $$;

create or replace function public.update_member(p_code text, p_member_token text, p_name text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.events; m public.members;
begin
  e := public._thyme_event(p_code);
  m := public._thyme_member(e.id, p_member_token);
  if p_name is null or char_length(btrim(p_name)) not between 1 and 40 then raise exception 'Please enter a name (1-40 characters)'; end if;
  update public.members set name = left(btrim(p_name), 40) where id = m.id;
  perform public._thyme_notify(e.code);
end $$;

create or replace function public.reset_progress(p_code text, p_member_token text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.events; m public.members;
begin
  e := public._thyme_event(p_code);
  m := public._thyme_member(e.id, p_member_token);
  if not m.is_host then raise exception 'Only the host can reset progress' using errcode = '42501'; end if;
  update public.tasks set status = 'pending', started_at = null, done_at = null, updated_by = m.id, updated_at = now() where event_id = e.id;
  perform public._thyme_notify(e.code);
end $$;

create or replace function public.leave_event(p_code text, p_member_token text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.events; m public.members;
begin
  e := public._thyme_event(p_code);
  m := public._thyme_member(e.id, p_member_token);
  if m.is_host then raise exception 'The host ends the event instead of leaving' using errcode = '42501'; end if;
  delete from public.members where id = m.id;
  perform public._thyme_notify(e.code);
end $$;

create or replace function public.delete_event(p_code text, p_member_token text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.events; m public.members;
begin
  e := public._thyme_event(p_code);
  m := public._thyme_member(e.id, p_member_token);
  if not m.is_host then raise exception 'Only the host can end the event' using errcode = '42501'; end if;
  perform public._thyme_notify(e.code);
  delete from public.events where id = e.id;
end $$;

-- ---------------------------------------------------------------- permissions
-- Internal helpers: nobody calls these from the app.
revoke all on function public._thyme_code(), public._thyme_token(), public._thyme_event(text),
                       public._thyme_member(uuid, text), public._thyme_notify(text) from public, anon, authenticated;
-- App functions: callable with the public anon key.
revoke all on function public.create_event(text, timestamptz, jsonb, jsonb, text),
                       public.join_event(text, text), public.event_state(text),
                       public.update_plan(text, text, text, timestamptz, jsonb, jsonb),
                       public.set_assignee(text, text, text[], uuid), public.set_status(text, text, text, text),
                       public.update_member(text, text, text), public.reset_progress(text, text),
                       public.leave_event(text, text), public.delete_event(text, text) from public;
grant execute on function public.create_event(text, timestamptz, jsonb, jsonb, text),
                          public.join_event(text, text), public.event_state(text),
                          public.update_plan(text, text, text, timestamptz, jsonb, jsonb),
                          public.set_assignee(text, text, text[], uuid), public.set_status(text, text, text, text),
                          public.update_member(text, text, text), public.reset_progress(text, text),
                          public.leave_event(text, text), public.delete_event(text, text) to anon, authenticated;

-- Make the API see the new functions right away.
notify pgrst, 'reload schema';
