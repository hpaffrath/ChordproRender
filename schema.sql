-- ============================================================
--  ChordPro Editor — Complete Database Schema v3
--
--  Changes from v2:
--    - songs: artist, key columns consolidated
--    - Indexes added for performance at scale
--    - All group tables with correct RLS policies
--    - shared_items for sharing songs/setlists
--    - grpDelete now explicitly removes children first
--
--  Safe to re-run:
--    CREATE TABLE uses IF NOT EXISTS
--    All policies use DROP IF EXISTS before CREATE
--    Trigger function checks for existence before creating
--    ALTER TABLE ADD COLUMN IF NOT EXISTS for upgrades
--
--  Run in Supabase SQL Editor.
-- ============================================================


-- ─── TRIGGER FUNCTION ─────────────────────────────────────────────────────────
do $$ begin
  if not exists (select 1 from pg_proc where proname = 'update_updated_at') then
    execute $func$
      create function update_updated_at()
      returns trigger language plpgsql as $inner$
      begin new.updated_at = now(); return new; end;
      $inner$
    $func$;
  end if;
end $$;


-- ─── RLS HELPER FUNCTIONS (security definer — no recursion) ───────────────────
create or replace function is_group_member(p_group_id uuid, p_user_id uuid)
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from group_members
    where group_id = p_group_id and user_id = p_user_id
  );
$$;

create or replace function is_group_admin(p_group_id uuid, p_user_id uuid)
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from group_members
    where group_id = p_group_id and user_id = p_user_id and role = 'admin'
  );
$$;


-- ============================================================
--  PERSONAL TABLES
-- ============================================================

-- ─── SONGS ────────────────────────────────────────────────────────────────────
create table if not exists songs (
  id          uuid        default gen_random_uuid() primary key,
  user_id     uuid        references auth.users(id) on delete cascade not null,
  filename    text        not null,
  title       text,
  artist      text,
  key         text,
  content     text        not null default '',
  tags        text[]      default '{}',
  created_at  timestamptz default now(),
  updated_at  timestamptz default now(),
  unique (user_id, filename)
);

drop trigger if exists songs_updated_at on songs;
create trigger songs_updated_at
  before update on songs
  for each row execute procedure update_updated_at();

alter table songs enable row level security;

drop policy if exists "Users can manage their own songs" on songs;
create policy "Users can manage their own songs"
  on songs for all
  using  (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Upgrade helpers — safe to run on existing schemas
alter table songs add column if not exists artist text;
alter table songs add column if not exists key    text;
alter table songs add column if not exists tags   text[] default '{}';


-- ─── SETLISTS ─────────────────────────────────────────────────────────────────
create table if not exists setlists (
  id              uuid        default gen_random_uuid() primary key,
  user_id         uuid        references auth.users(id) on delete cascade not null,
  name            text        not null,
  song_filenames  text[]      default '{}',
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

drop trigger if exists setlists_updated_at on setlists;
create trigger setlists_updated_at
  before update on setlists
  for each row execute procedure update_updated_at();

alter table setlists enable row level security;

drop policy if exists "Users can manage their own setlists" on setlists;
create policy "Users can manage their own setlists"
  on setlists for all
  using  (auth.uid() = user_id)
  with check (auth.uid() = user_id);


-- ─── SHARED ITEMS ─────────────────────────────────────────────────────────────
create table if not exists shared_items (
  id                uuid        default gen_random_uuid() primary key,
  token             text        unique not null
                                default substr(md5(random()::text || clock_timestamp()::text), 1, 24),
  owner_id          uuid        references auth.users(id) on delete cascade not null,
  item_type         text        not null check (item_type in ('song', 'setlist')),
  title             text        not null,
  content           text,
  setlist_contents  jsonb,
  created_at        timestamptz default now(),
  expires_at        timestamptz default (now() + interval '90 days')
);

alter table shared_items enable row level security;

drop policy if exists "Owners can manage their shares" on shared_items;
create policy "Owners can manage their shares"
  on shared_items for all
  using  (auth.uid() = owner_id)
  with check (auth.uid() = owner_id);

drop policy if exists "Anyone can read shares" on shared_items;
create policy "Anyone can read shares"
  on shared_items for select using (true);


-- ============================================================
--  GROUP / COLLABORATION TABLES
-- ============================================================

-- ─── GROUPS ───────────────────────────────────────────────────────────────────
create table if not exists groups (
  id           uuid        default gen_random_uuid() primary key,
  name         text        not null,
  created_by   uuid        references auth.users(id) on delete set null,
  invite_token text        unique not null
                           default substr(md5(random()::text || clock_timestamp()::text), 1, 16),
  created_at   timestamptz default now()
);

alter table groups enable row level security;

drop policy if exists "Members can view their groups"             on groups;
drop policy if exists "Creators can view their new group"         on groups;
drop policy if exists "Anyone can look up group by invite token"  on groups;
drop policy if exists "Authenticated users can create groups"     on groups;
drop policy if exists "Admins can update their groups"            on groups;
drop policy if exists "Admins can delete their groups"            on groups;

create policy "Members can view their groups"
  on groups for select using (is_group_member(id, auth.uid()));

create policy "Creators can view their new group"
  on groups for select using (auth.uid() = created_by);

create policy "Anyone can look up group by invite token"
  on groups for select using (auth.role() = 'authenticated');

create policy "Authenticated users can create groups"
  on groups for insert with check (auth.role() = 'authenticated');

create policy "Admins can update their groups"
  on groups for update using (is_group_admin(id, auth.uid()));

create policy "Admins can delete their groups"
  on groups for delete using (is_group_admin(id, auth.uid()));


-- ─── GROUP MEMBERS ────────────────────────────────────────────────────────────
create table if not exists group_members (
  id           uuid        default gen_random_uuid() primary key,
  group_id     uuid        references groups(id) on delete cascade not null,
  user_id      uuid        references auth.users(id) on delete cascade not null,
  role         text        not null default 'member'
                           check (role in ('admin', 'member')),
  display_name text,
  joined_at    timestamptz default now(),
  unique (group_id, user_id)
);

alter table group_members enable row level security;

drop policy if exists "Members can view group members"                         on group_members;
drop policy if exists "Users can join groups"                                  on group_members;
drop policy if exists "Admins can update member roles"                         on group_members;
drop policy if exists "Admins can remove members, users can remove themselves" on group_members;

create policy "Members can view group members"
  on group_members for select using (is_group_member(group_id, auth.uid()));

create policy "Users can join groups"
  on group_members for insert with check (auth.uid() = user_id);

create policy "Admins can update member roles"
  on group_members for update
  using (auth.uid() = user_id or is_group_admin(group_id, auth.uid()));

create policy "Admins can remove members, users can remove themselves"
  on group_members for delete
  using (auth.uid() = user_id or is_group_admin(group_id, auth.uid()));


-- ─── GROUP SONGS ──────────────────────────────────────────────────────────────
create table if not exists group_songs (
  id             uuid        default gen_random_uuid() primary key,
  group_id       uuid        references groups(id) on delete cascade not null,
  filename       text        not null,
  title          text,
  artist         text,
  content        text        not null default '',
  tags           text[]      default '{}',
  key            text,
  added_by       uuid        references auth.users(id) on delete set null,
  last_edited_by uuid        references auth.users(id) on delete set null,
  created_at     timestamptz default now(),
  updated_at     timestamptz default now(),
  unique (group_id, filename)
);

-- Migration for existing databases that already have group_songs without artist:
alter table group_songs add column if not exists artist text;

drop trigger if exists group_songs_updated_at on group_songs;
create trigger group_songs_updated_at
  before update on group_songs
  for each row execute procedure update_updated_at();

alter table group_songs enable row level security;

drop policy if exists "Members can read group songs"  on group_songs;
drop policy if exists "Members can add group songs"   on group_songs;
drop policy if exists "Members can edit group songs"  on group_songs;
drop policy if exists "Admins can delete group songs" on group_songs;

create policy "Members can read group songs"
  on group_songs for select using (is_group_member(group_id, auth.uid()));

create policy "Members can add group songs"
  on group_songs for insert with check (is_group_member(group_id, auth.uid()));

create policy "Members can edit group songs"
  on group_songs for update using (is_group_member(group_id, auth.uid()));

create policy "Admins can delete group songs"
  on group_songs for delete using (is_group_admin(group_id, auth.uid()));


-- ─── GROUP SETLISTS ───────────────────────────────────────────────────────────
create table if not exists group_setlists (
  id             uuid        default gen_random_uuid() primary key,
  group_id       uuid        references groups(id) on delete cascade not null,
  name           text        not null,
  song_filenames text[]      default '{}',
  created_by     uuid        references auth.users(id) on delete set null,
  created_at     timestamptz default now(),
  updated_at     timestamptz default now()
);

drop trigger if exists group_setlists_updated_at on group_setlists;
create trigger group_setlists_updated_at
  before update on group_setlists
  for each row execute procedure update_updated_at();

alter table group_setlists enable row level security;

drop policy if exists "Members can manage group setlists" on group_setlists;
create policy "Members can manage group setlists"
  on group_setlists for all
  using  (is_group_member(group_id, auth.uid()))
  with check (is_group_member(group_id, auth.uid()));


-- ============================================================
--  APPROVAL / ACCESS CONTROL
-- ============================================================

-- ─── APPROVED MEMBERS ─────────────────────────────────────────────────────────
create table if not exists approved_members (
  id         uuid        default gen_random_uuid() primary key,
  user_id    uuid        references auth.users(id) on delete cascade not null,
  email      text        not null,
  approved   boolean     not null default false,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique (user_id),
  unique (email)
);

drop trigger if exists approved_members_updated_at on approved_members;
create trigger approved_members_updated_at
  before update on approved_members
  for each row execute procedure update_updated_at();

alter table approved_members enable row level security;

grant select, insert, update, delete on approved_members to authenticated;
grant all on approved_members to service_role;

drop policy if exists "Users can view their own approval status" on approved_members;
create policy "Users can view their own approval status"
  on approved_members for select
  using (auth.uid() = user_id);

-- Helper: check whether a given user is approved
create or replace function is_approved_member(p_user_id uuid)
returns boolean language sql security definer stable as $$
  select coalesce(
    (select approved from approved_members where user_id = p_user_id),
    false
  );
$$;

-- Auto-enroll new sign-ups as pending (skips users with no email)
--  * search_path is pinned: auth triggers do not run with `public` on the path,
--    so without this the insert fails and signup returns
--    "Database error saving new user".
--  * both unique constraints (user_id, email) are handled.
--  * any unexpected failure is swallowed so signup can never be blocked.
create or replace function handle_new_approved_member()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text;
begin
  v_email := coalesce(new.email, new.raw_user_meta_data->>'email');
  if v_email is not null then
    begin
      insert into public.approved_members (user_id, email, approved)
      values (new.id, v_email, false)
      on conflict (user_id) do nothing;
    exception
      when unique_violation then
        -- email already present under a different user_id: link it across
        update public.approved_members
           set user_id = new.id
         where email = v_email;
      when others then
        raise warning 'approved_members enrolment failed for %: %', new.id, sqlerrm;
    end;
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_approved_member on auth.users;
create trigger on_auth_user_created_approved_member
  after insert on auth.users
  for each row execute function handle_new_approved_member();

-- Backfill: mark all existing users as approved (skips users without an email)
insert into approved_members (user_id, email, approved)
select id, email, true
from auth.users
where email is not null
  and not exists (
    select 1 from approved_members where approved_members.user_id = auth.users.id
  )
on conflict do nothing;


-- ============================================================
--  INDEXES (performance at scale)
-- ============================================================

create index if not exists songs_user_id_idx      on songs(user_id);
create index if not exists songs_artist_idx        on songs(artist);
create index if not exists songs_key_idx           on songs(key);
create index if not exists songs_updated_at_idx    on songs(updated_at desc);
create index if not exists setlists_user_id_idx    on setlists(user_id);
create index if not exists shared_items_token_idx  on shared_items(token);
create index if not exists shared_items_expiry_idx on shared_items(expires_at);
create index if not exists grp_members_user_idx    on group_members(user_id);
create index if not exists grp_members_group_idx   on group_members(group_id);
create index if not exists grp_songs_group_idx     on group_songs(group_id);
create index if not exists approved_members_user_idx on approved_members(user_id);
create index if not exists approved_members_email_idx  on approved_members(email);


-- ============================================================
--  MAINTENANCE
-- ============================================================

-- Backfill artist and key from existing song content (run once):
--
--   update songs set
--     artist = (regexp_match(content, '(?i)^\{artist:\s*(.+?)\}', 'm'))[1],
--     key    = (regexp_match(content, '(?i)^\{key:\s*([A-G][b#]?m?)\}', 'm'))[1]
--   where content ilike '%{artist:%'
--      or content ilike '%{key:%';

-- Clean up expired share links:
--
--   delete from shared_items where expires_at < now();
--
-- Schedule via pg_cron (optional):
--
--   select cron.schedule(
--     'cleanup-expired-shares', '0 3 * * *',
--     'delete from shared_items where expires_at < now()'
--   );

-- ============================================================
--  TABLE SUMMARY
--
--  songs             Personal ChordPro files        RLS: user_id
--  setlists          Personal setlists               RLS: user_id
--  shared_items      Share links (90-day expiry)     RLS: owner / public read
--  groups            Collaboration groups            RLS: member / admin
--  group_members     Group membership + roles        RLS: member / admin
--  group_songs       Songs shared within a group     RLS: member r/w, admin delete
--  group_setlists    Setlists shared within a group  RLS: member
--  approved_members  App access approval list        RLS: own row / service_role
--
--  RLS helpers (security definer, avoids recursion):
--    is_group_member(group_id, user_id) → boolean
--    is_group_admin(group_id, user_id)  → boolean
--    is_approved_member(user_id)        → boolean
-- ============================================================
