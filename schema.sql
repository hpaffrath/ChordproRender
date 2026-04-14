-- ============================================================
--  ChordPro Editor — Database Schema
--  Run this in the Supabase SQL Editor to recreate all tables.
--  Safe to re-run: uses IF NOT EXISTS / CREATE OR REPLACE.
-- ============================================================


-- ─── SONGS ────────────────────────────────────────────────────────────────────
--  One row per saved .cho file. Content stored as plain text.

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

-- Keep updated_at current automatically
create or replace function update_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists songs_updated_at on songs;
create trigger songs_updated_at
  before update on songs
  for each row execute procedure update_updated_at();

-- Row Level Security: users can only see and modify their own songs
alter table songs enable row level security;

drop policy if exists "Users can manage their own songs" on songs;
create policy "Users can manage their own songs"
  on songs for all
  using  (auth.uid() = user_id)
  with check (auth.uid() = user_id);


-- ─── SETLISTS ─────────────────────────────────────────────────────────────────
--  An ordered list of song filenames belonging to a user.

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
--  Recipients with an account can save a copy; others get a read-only view.

create table if not exists shared_items (
  id                uuid        default gen_random_uuid() primary key,
  token             text        unique not null
                                default substr(md5(random()::text || clock_timestamp()::text), 1, 24),
  owner_id          uuid        references auth.users(id) on delete cascade not null,
  item_type         text        not null check (item_type in ('song', 'setlist')),
  title             text        not null,
  content           text,                    -- populated for item_type = 'song'
  setlist_contents  jsonb,                   -- populated for item_type = 'setlist'
                                             -- format: [{ filename, title, content }]
  created_at        timestamptz default now(),
  expires_at        timestamptz default (now() + interval '90 days')
);

alter table shared_items enable row level security;

-- Owners can create, update and delete their own shares
drop policy if exists "Owners can manage their shares" on shared_items;
create policy "Owners can manage their shares"
  on shared_items for all
  using  (auth.uid() = owner_id)
  with check (auth.uid() = owner_id);

-- Anyone (including anonymous visitors) can read a share by token
drop policy if exists "Anyone can read shares" on shared_items;
create policy "Anyone can read shares"
  on shared_items for select
  using (true);


-- ─── OPTIONAL: ADD key COLUMN TO EXISTING SONGS TABLE ─────────────────────────
--  If you already have a songs table without the key column, run this once:

alter table songs add column if not exists key text;


-- ─── SUMMARY ──────────────────────────────────────────────────────────────────
--
--  Tables:
--    songs         — ChordPro song files (.cho), one per user/filename pair
--    setlists      — Ordered lists of song filenames belonging to a user
--    shared_items  — Time-limited share links for songs and setlists
--
--  All tables use Row Level Security.
--  The shared_items table has an additional public read policy for share links.
--  Shared items expire after 90 days by default (expires_at column).
--
--  To clean up expired shares periodically, run:
--    delete from shared_items where expires_at < now();
--  Or set up a pg_cron job in Supabase:
--    select cron.schedule('cleanup-expired-shares', '0 3 * * *',
--      'delete from shared_items where expires_at < now()');
--
-- ============================================================
