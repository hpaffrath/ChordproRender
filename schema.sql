-- ============================================================
--  ChordPro Editor — Complete Database Schema
--  Combines all tables: songs, setlists, shared_items,
--  groups, group_members, group_songs, group_setlists.
--
--  Safe to re-run on an existing database:
--    - CREATE TABLE uses IF NOT EXISTS
--    - All policies use DROP IF EXISTS before CREATE
--    - Trigger function checks for existence before creating
--
--  Run this in the Supabase SQL Editor.
-- ============================================================


-- ─── TRIGGER FUNCTION ─────────────────────────────────────────────────────────
--  Shared by songs, setlists, group_songs, group_setlists.
--  Only created if it doesn't already exist.

do $$ begin
  if not exists (
    select 1 from pg_proc where proname = 'update_updated_at'
  ) then
    execute $func$
      create function update_updated_at()
      returns trigger language plpgsql as $inner$
      begin
        new.updated_at = now();
        return new;
      end;
      $inner$
    $func$;
  end if;
end $$;


-- ─── HELPER FUNCTIONS (security definer — bypass RLS for group checks) ─────────

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
  content     text        not null default '',
  tags        text[]      default '{}',
  key         text,
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

-- Add key column if upgrading from an older schema
alter table songs add column if not exists key text;


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
--  Stores shared songs and setlists accessible via a unique token URL.
--  item_type = 'song'    → content column is populated
--  item_type = 'setlist' → setlist_contents jsonb is populated
--                          format: [{ filename, title, content }]

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
  on shared_items for select
  using (true);


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

drop policy if exists "Members can view their groups" on groups;
create policy "Members can view their groups"
  on groups for select
  using (is_group_member(id, auth.uid()));

drop policy if exists "Creators can view their new group" on groups;
create policy "Creators can view their new group"
  on groups for select
  using (auth.uid() = created_by);

drop policy if exists "Anyone can look up group by invite token" on groups;
create policy "Anyone can look up group by invite token"
  on groups for select
  using (auth.role() = 'authenticated');

drop policy if exists "Authenticated users can create groups" on groups;
create policy "Authenticated users can create groups"
  on groups for insert
  with check (auth.role() = 'authenticated');

drop policy if exists "Admins can update their groups" on groups;
create policy "Admins can update their groups"
  on groups for update
  using (is_group_admin(id, auth.uid()));

drop policy if exists "Admins can delete their groups" on groups;
create policy "Admins can delete their groups"
  on groups for delete
  using (is_group_admin(id, auth.uid()));


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

drop policy if exists "Members can view group members" on group_members;
create policy "Members can view group members"
  on group_members for select
  using (is_group_member(group_id, auth.uid()));

drop policy if exists "Users can join groups" on group_members;
create policy "Users can join groups"
  on group_members for insert
  with check (auth.uid() = user_id);

drop policy if exists "Admins can update member roles" on group_members;
create policy "Admins can update member roles"
  on group_members for update
  using (auth.uid() = user_id or is_group_admin(group_id, auth.uid()));

drop policy if exists "Admins can remove members, users can remove themselves" on group_members;
create policy "Admins can remove members, users can remove themselves"
  on group_members for delete
  using (auth.uid() = user_id or is_group_admin(group_id, auth.uid()));


-- ─── GROUP SONGS ──────────────────────────────────────────────────────────────

create table if not exists group_songs (
  id             uuid        default gen_random_uuid() primary key,
  group_id       uuid        references groups(id) on delete cascade not null,
  filename       text        not null,
  title          text,
  content        text        not null default '',
  tags           text[]      default '{}',
  key            text,
  added_by       uuid        references auth.users(id) on delete set null,
  last_edited_by uuid        references auth.users(id) on delete set null,
  created_at     timestamptz default now(),
  updated_at     timestamptz default now(),
  unique (group_id, filename)
);

drop trigger if exists group_songs_updated_at on group_songs;
create trigger group_songs_updated_at
  before update on group_songs
  for each row execute procedure update_updated_at();

alter table group_songs enable row level security;

drop policy if exists "Members can read group songs" on group_songs;
create policy "Members can read group songs"
  on group_songs for select
  using (is_group_member(group_id, auth.uid()));

drop policy if exists "Members can add group songs" on group_songs;
create policy "Members can add group songs"
  on group_songs for insert
  with check (is_group_member(group_id, auth.uid()));

drop policy if exists "Members can edit group songs" on group_songs;
create policy "Members can edit group songs"
  on group_songs for update
  using (is_group_member(group_id, auth.uid()));

drop policy if exists "Admins can delete group songs" on group_songs;
create policy "Admins can delete group songs"
  on group_songs for delete
  using (is_group_admin(group_id, auth.uid()));


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
--  MAINTENANCE NOTES
--
--  To clean up expired share links (run manually or via pg_cron):
--    delete from shared_items where expires_at < now();
--
--  To schedule automatic cleanup in Supabase (pg_cron):
--    select cron.schedule(
--      'cleanup-expired-shares', '0 3 * * *',
--      'delete from shared_items where expires_at < now()'
--    );
--
--  Tables summary:
--    songs            Personal ChordPro files, RLS by user_id
--    setlists         Personal setlists, RLS by user_id
--    shared_items     Share links (songs/setlists), 90-day expiry
--    groups           Collaboration groups with invite tokens
--    group_members    Group membership with admin/member roles
--    group_songs      Songs shared within a group (all members can edit)
--    group_setlists   Setlists shared within a group
--
--  RLS helper functions (security definer — no recursion):
--    is_group_member(group_id, user_id) → boolean
--    is_group_admin(group_id, user_id)  → boolean
--
-- ============================================================
