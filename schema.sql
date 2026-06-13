-- ============================================================================
--  PULSE CHAT – Supabase Datenbankschema
--  Führe dieses gesamte Skript einmal im Supabase SQL-Editor aus
--  (Dashboard -> SQL Editor -> New query -> einfügen -> Run)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) EXTENSIONS
-- ----------------------------------------------------------------------------
create extension if not exists pgcrypto;   -- für gen_random_uuid()
create extension if not exists pg_cron;    -- für den täglichen Löschjob

-- ----------------------------------------------------------------------------
-- 2) TABELLEN
-- ----------------------------------------------------------------------------

-- Profile: 1 Zeile pro Auth-User
create table public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text not null,
  is_public    boolean not null default true,   -- true = über die Suche auffindbar
  private_code text not null unique,            -- 8-stelliger Code für private Profile
  created_at   timestamptz not null default now()
);

-- Chat-Räume
create table public.rooms (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  is_direct  boolean not null default false,    -- true = 1:1-Chat (kein Gruppenname)
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

-- Mitgliedschaften (wer ist in welchem Raum)
create table public.room_members (
  room_id  uuid not null references public.rooms (id) on delete cascade,
  user_id  uuid not null references public.profiles (id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id)
);

-- Nachrichten
create table public.messages (
  id         uuid primary key default gen_random_uuid(),
  room_id    uuid not null references public.rooms (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  content    text not null,
  created_at timestamptz not null default now()
);

create index messages_room_created_idx on public.messages (room_id, created_at);
create index room_members_user_idx     on public.room_members (user_id);

-- ----------------------------------------------------------------------------
-- 3) HILFSFUNKTIONEN
-- ----------------------------------------------------------------------------

-- Erzeugt einen zufälligen, eindeutigen 8-Zeichen-Code (ohne 0/O/1/I etc.)
create or replace function public.generate_private_code()
returns text
language plpgsql
as $$
declare
  chars  text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  result text;
  taken  boolean;
begin
  loop
    result := '';
    for i in 1..8 loop
      result := result || substr(chars, floor(random() * length(chars))::int + 1, 1);
    end loop;
    select exists (select 1 from public.profiles where private_code = result) into taken;
    exit when not taken;
  end loop;
  return result;
end;
$$;

-- Legt automatisch ein Profil an, sobald sich ein neuer Auth-User registriert
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, private_code, is_public)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'display_name', split_part(new.email, '@', 1)),
    public.generate_private_code(),
    true
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Prüft, ob der aktuell eingeloggte User Mitglied eines Raums ist
create or replace function public.is_room_member(_room_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.room_members
    where room_id = _room_id and user_id = auth.uid()
  );
$$;

-- Prüft, ob der aktuell eingeloggte User mit _other_user einen Raum teilt
-- (wird benötigt, damit man Anzeigenamen privater Mitglieder im gemeinsamen Chat sieht)
create or replace function public.shares_room_with(_other_user uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1
    from public.room_members rm1
    join public.room_members rm2 on rm1.room_id = rm2.room_id
    where rm1.user_id = _other_user and rm2.user_id = auth.uid()
  );
$$;

-- Generiert für den eingeloggten User einen neuen privaten Code
create or replace function public.regenerate_my_private_code()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  new_code text;
begin
  new_code := public.generate_private_code();
  update public.profiles set private_code = new_code where id = auth.uid();
  return new_code;
end;
$$;

-- Findet ein Profil (auch private!) über den 8-stelligen Code.
-- Dies ist der EINZIGE Weg, ein privates Profil zu finden.
create or replace function public.find_user_by_private_code(_code text)
returns table (id uuid, display_name text)
language sql
security definer
stable
set search_path = public
as $$
  select p.id, p.display_name
  from public.profiles p
  where p.private_code = upper(trim(_code))
    and p.id <> auth.uid();
$$;

-- Erstellt (oder findet wieder) einen 1:1-Chat zwischen dem eingeloggten
-- User und _other_user.
create or replace function public.start_direct_chat(_other_user uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  existing_room uuid;
  new_room      uuid;
begin
  select rm1.room_id into existing_room
  from public.room_members rm1
  join public.room_members rm2 on rm1.room_id = rm2.room_id
  join public.rooms r on r.id = rm1.room_id
  where rm1.user_id = auth.uid()
    and rm2.user_id = _other_user
    and r.is_direct = true
  limit 1;

  if existing_room is not null then
    return existing_room;
  end if;

  insert into public.rooms (name, is_direct, created_by)
  values ('Direktnachricht', true, auth.uid())
  returning id into new_room;

  insert into public.room_members (room_id, user_id) values (new_room, auth.uid());
  insert into public.room_members (room_id, user_id) values (new_room, _other_user);

  return new_room;
end;
$$;

-- ----------------------------------------------------------------------------
-- 4) ROW LEVEL SECURITY
-- ----------------------------------------------------------------------------

alter table public.profiles     enable row level security;
alter table public.rooms        enable row level security;
alter table public.room_members enable row level security;
alter table public.messages     enable row level security;

-- PROFILES --------------------------------------------------------------
-- Sichtbar sind: öffentliche Profile, das eigene Profil, sowie Profile von
-- Leuten, mit denen man bereits einen Raum teilt (damit Anzeigenamen im
-- Chat sichtbar sind, auch wenn das Profil privat ist).
-- => Private Profile fremder Nutzer tauchen NIE in der normalen Suche auf.
create policy "profiles_select" on public.profiles
  for select using (
    is_public = true
    or id = auth.uid()
    or public.shares_room_with(id)
  );

create policy "profiles_update_own" on public.profiles
  for update using (id = auth.uid());

-- Nur display_name und is_public dürfen vom Client geändert werden.
-- private_code kann nur über regenerate_my_private_code() geändert werden.
revoke update on public.profiles from authenticated;
grant update (display_name, is_public) on public.profiles to authenticated;

-- ROOMS -------------------------------------------------------------------
create policy "rooms_select_member" on public.rooms
  for select using (public.is_room_member(id));

create policy "rooms_insert_own" on public.rooms
  for insert with check (created_by = auth.uid());

-- ROOM_MEMBERS --------------------------------------------------------------
create policy "room_members_select_member" on public.room_members
  for select using (public.is_room_member(room_id));

-- Self-Join: Über einen Einladungslink kann sich jeder eingeloggte User
-- selbst zu einem Raum hinzufügen (Raum-ID = "Einladung").
create policy "room_members_insert_self" on public.room_members
  for insert with check (user_id = auth.uid());

create policy "room_members_delete_self" on public.room_members
  for delete using (user_id = auth.uid());

-- MESSAGES --------------------------------------------------------------
create policy "messages_select_member" on public.messages
  for select using (public.is_room_member(room_id));

create policy "messages_insert_member" on public.messages
  for insert with check (
    public.is_room_member(room_id) and user_id = auth.uid()
  );

-- ----------------------------------------------------------------------------
-- 5) REALTIME AKTIVIEREN
-- ----------------------------------------------------------------------------
alter publication supabase_realtime add table public.messages;

-- ----------------------------------------------------------------------------
-- 6) AUTOMATISCHES LÖSCHEN VON NACHRICHTEN NACH 30 TAGEN
-- ----------------------------------------------------------------------------

create or replace function public.delete_old_messages()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.messages
  where created_at < now() - interval '30 days';
$$;

-- Führt den Löschjob täglich um 03:00 UTC aus.
-- Falls der Job schon existiert, vorher löschen (verhindert Duplikate
-- beim erneuten Ausführen dieses Skripts).
select cron.unschedule(jobid)
from cron.job
where jobname = 'delete-old-messages-daily';

select cron.schedule(
  'delete-old-messages-daily',
  '0 3 * * *',
  $$ select public.delete_old_messages(); $$
);

-- ============================================================================
-- FERTIG. Die App ist nun einsatzbereit.
-- ============================================================================
