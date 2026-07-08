-- ============================================================================
-- SEC Survivor 2026 — Supabase schema
-- Run this once in the Supabase SQL editor on a fresh project.
-- ============================================================================

create extension if not exists pgcrypto;

-- ----------------------------------------------------------------------------
-- TABLES
-- ----------------------------------------------------------------------------

create table players (
  id                   uuid primary key default gen_random_uuid(),
  name                 text not null unique,
  token_hash           text not null,
  recovery_word_hash   text,
  created_at           timestamptz not null default now()
);

create table games (
  id          bigint generated always as identity primary key,
  week        int not null,
  away        text not null,
  home        text not null,
  kickoff_at  timestamptz not null,
  away_score  int,
  home_score  int,
  winner      text, -- set once final; null while in progress / not started
  updated_at  timestamptz not null default now(),
  unique (week, away, home)
);

create table picks (
  id             bigint generated always as identity primary key,
  player_id      uuid not null references players(id) on delete cascade,
  week           int not null,
  team           text not null,
  last_edited_by text not null default 'player' check (last_edited_by in ('player','commissioner')),
  admin_note     text,
  updated_at     timestamptz not null default now(),
  unique (player_id, week)
);

-- Opponent classification is keyed on the OPPONENT alone (Rule 3 only looks at
-- the opponent's own conference), not on the SEC/opponent pairing. If an
-- opponent isn't in this table, it isn't a valid non-conference opponent this
-- season for any SEC team (add it here if that ever comes up).
create table opponent_classification (
  opponent  text primary key,
  eligible  boolean not null,       -- false = FCS / not FBS, cannot be picked at all
  category  text check (category in ('g5','not_g5'))  -- null when not eligible
);

-- Anyone who should get commissioner powers. Populated after you create a
-- Supabase Auth user for yourself (see SETUP.md).
create table admins (
  user_id uuid primary key references auth.users(id)
);

-- ----------------------------------------------------------------------------
-- SEED DATA: 2026 non-conference opponent classification
-- (verified against 2026 conference realignment; new Pac-12 = G5 per ruling)
-- ----------------------------------------------------------------------------

insert into opponent_classification (opponent, eligible, category) values
  -- Not G5 (ACC / Big Ten / Big 12 / Notre Dame)
  ('Florida State',   true, 'not_g5'),
  ('Baylor',          true, 'not_g5'),
  ('Georgia Tech',    true, 'not_g5'),
  ('Louisville',      true, 'not_g5'),
  ('Clemson',         true, 'not_g5'),
  ('Minnesota',       true, 'not_g5'),
  ('Kansas',          true, 'not_g5'),
  ('Michigan',        true, 'not_g5'),
  ('Utah',            true, 'not_g5'),
  ('Ohio State',      true, 'not_g5'),
  ('Arizona State',   true, 'not_g5'),
  ('NC State',        true, 'not_g5'),

  -- G5 (American, Sun Belt, Mountain West, C-USA, MAC, new Pac-12)
  ('East Carolina',       true, 'g5'),
  ('Tulsa',               true, 'g5'),
  ('Southern Miss',       true, 'g5'),
  ('Florida Atlantic',    true, 'g5'),
  ('Western Kentucky',    true, 'g5'),
  ('South Alabama',       true, 'g5'),
  ('Louisiana Tech',      true, 'g5'),
  ('Louisiana-Monroe',    true, 'g5'),
  ('Troy',                true, 'g5'),
  ('UTEP',                true, 'g5'),
  ('New Mexico',          true, 'g5'),
  ('Charlotte',           true, 'g5'),
  ('Kent State',          true, 'g5'),
  ('Kennesaw State',      true, 'g5'),
  ('Texas State',         true, 'g5'),
  ('UTSA',                true, 'g5'),
  ('Missouri State',      true, 'g5'),
  ('Delaware',            true, 'g5'),

  -- Not eligible (FCS opponents — Rule 1, cannot be picked at all)
  ('Chattanooga',         false, null),
  ('North Alabama',       false, null),
  ('Samford',             false, null),
  ('Campbell',            false, null),
  ('Tennessee State',     false, null),
  ('Youngstown State',    false, null),
  ('McNeese State',       false, null),
  ('Tennessee Tech',      false, null),
  ('Arkansas-Pine Bluff', false, null),
  ('Wofford',             false, null),
  ('Towson',              false, null),
  ('Furman',              false, null),
  ('Citadel',             false, null),
  ('Austin Peay',         false, null);

-- ----------------------------------------------------------------------------
-- HELPERS
-- ----------------------------------------------------------------------------

-- The Saturday-10:59am-Central deadline for a given week, derived from the
-- earliest kickoff already loaded for that week (so it self-adjusts to the
-- actual calendar dates without hardcoding them here).
create or replace function week_deadline(p_week int) returns timestamptz as $$
declare
  d date;
begin
  select (min(kickoff_at) at time zone 'America/Chicago')::date into d
  from games where week = p_week;

  if d is null then
    return null;
  end if;

  -- advance to the Saturday on/after d (Sun=0 ... Sat=6)
  d := d + ((6 - extract(dow from d)::int + 7) % 7);

  return (d::timestamp + interval '10 hours 59 minutes') at time zone 'America/Chicago';
end;
$$ language plpgsql stable;

-- The other side of a (week, SEC team) matchup.
create or replace function opponent_of(p_week int, p_team text) returns text as $$
  select case when home = p_team then away
              when away = p_team then home
              else null end
  from games where week = p_week and (home = p_team or away = p_team);
$$ language sql stable;

-- 'conference' | 'g5' | 'not_g5' | 'ineligible' | 'invalid' (no such game)
create or replace function classify_pick(p_week int, p_team text) returns text as $$
declare
  v_opp text;
  v_sec_teams text[] := array[
    'Alabama','Arkansas','Auburn','Florida','Georgia','Kentucky','LSU',
    'Mississippi State','Missouri','Oklahoma','Ole Miss','South Carolina',
    'Tennessee','Texas','Texas A&M','Vanderbilt'
  ];
  v_row opponent_classification%rowtype;
begin
  v_opp := opponent_of(p_week, p_team);
  if v_opp is null then
    return 'invalid';
  end if;
  if v_opp = any(v_sec_teams) then
    return 'conference';
  end if;
  select * into v_row from opponent_classification where opponent = v_opp;
  if not found or not v_row.eligible then
    return 'ineligible';
  end if;
  return v_row.category;
end;
$$ language plpgsql stable;

-- The moment a (week, team) selection stops being pickable/changeable:
-- whichever comes first, that game's own kickoff, or the week's flat
-- Saturday-10:59am deadline.
create or replace function pick_editable_until(p_week int, p_team text) returns timestamptz as $$
  select least(g.kickoff_at, week_deadline(p_week))
  from games g where g.week = p_week and (g.home = p_team or g.away = p_team);
$$ language sql stable;

-- ----------------------------------------------------------------------------
-- CORE WRITE PATH: submit_pick
-- All eligibility rules are enforced here, server-side. The frontend uses
-- this same logic only to decide what to show on the menu — it is never
-- trusted for enforcement.
-- ----------------------------------------------------------------------------

create or replace function submit_pick(
  p_player_id uuid,
  p_token     text,
  p_week      int,
  p_team      text
) returns void as $$
declare
  v_hash          text;
  v_category      text;
  v_new_deadline  timestamptz;
  v_old           record;
  v_old_deadline  timestamptz;
  v_already_used  boolean;
  v_nonconf_used  int;
  v_g5_used       int;
begin
  -- 1. identity check
  select token_hash into v_hash from players where id = p_player_id;
  if v_hash is null or crypt(p_token, v_hash) <> v_hash then
    raise exception 'invalid credentials';
  end if;

  -- 2. the new pick must be a real, eligible game
  v_category := classify_pick(p_week, p_team);
  if v_category = 'invalid' then
    raise exception 'no such game this week for that team';
  end if;
  if v_category = 'ineligible' then
    raise exception 'that opponent is not FBS and cannot be picked';
  end if;

  -- 3. the new pick's game must still be open
  v_new_deadline := pick_editable_until(p_week, p_team);
  if now() >= v_new_deadline then
    raise exception 'that game has already locked';
  end if;

  -- 4. if replacing an existing pick for this week, the OLD pick must still
  --    be unlocked (you may only swap away from a pick before its own
  --    game/week deadline has passed)
  select * into v_old from picks where player_id = p_player_id and week = p_week;
  if found then
    v_old_deadline := pick_editable_until(v_old.week, v_old.team);
    if v_old_deadline is not null and now() >= v_old_deadline then
      raise exception 'your current pick for this week is already locked';
    end if;
  end if;

  -- 5. team reuse check (excluding this week, in case they're re-confirming)
  select exists(
    select 1 from picks where player_id = p_player_id and team = p_team and week <> p_week
  ) into v_already_used;
  if v_already_used then
    raise exception 'you have already picked that team this season';
  end if;

  -- 6. non-conference / G5 season caps (3 total non-con, 1 of which may be G5)
  if v_category in ('g5','not_g5') then
    select count(*) into v_nonconf_used
    from picks p
    where p.player_id = p_player_id and p.week <> p_week
      and classify_pick(p.week, p.team) in ('g5','not_g5');

    if v_nonconf_used >= 3 then
      raise exception 'non-conference pick limit (3) already used';
    end if;
  end if;

  if v_category = 'g5' then
    select count(*) into v_g5_used
    from picks p
    where p.player_id = p_player_id and p.week <> p_week
      and classify_pick(p.week, p.team) = 'g5';

    if v_g5_used >= 1 then
      raise exception 'G5 pick limit (1) already used';
    end if;
  end if;

  -- all clear — write it
  insert into picks (player_id, week, team, last_edited_by, admin_note, updated_at)
  values (p_player_id, p_week, p_team, 'player', null, now())
  on conflict (player_id, week)
  do update set team = excluded.team, last_edited_by = 'player', admin_note = null, updated_at = now();
end;
$$ language plpgsql security definer;

-- ----------------------------------------------------------------------------
-- SIGNUP (self-serve, only open until the Week 1 deadline)
-- ----------------------------------------------------------------------------

create or replace function signup(
  p_name       text,
  p_token      text,
  p_recovery   text,
  p_week1_team text
) returns uuid as $$
declare
  v_id uuid;
  v_deadline timestamptz;
begin
  v_deadline := week_deadline(1);
  if v_deadline is not null and now() >= v_deadline then
    raise exception 'signup is closed for the season';
  end if;

  if exists(select 1 from players where lower(name) = lower(p_name)) then
    raise exception 'that name is already taken';
  end if;

  insert into players (name, token_hash, recovery_word_hash)
  values (
    p_name,
    crypt(p_token, gen_salt('bf')),
    case when p_recovery is not null and length(p_recovery) > 0
         then crypt(p_recovery, gen_salt('bf')) else null end
  )
  returning id into v_id;

  perform submit_pick(v_id, p_token, 1, p_week1_team);

  return v_id;
end;
$$ language plpgsql security definer;

-- Recovery: proves identity via name + recovery word, then ISSUES a new
-- token (the old one, being hashed, can never be recovered/displayed again).
-- The client generates a fresh random token and passes it in here.
create or replace function recover_player(
  p_name       text,
  p_recovery   text,
  p_new_token  text
) returns uuid as $$
declare
  v_row players%rowtype;
begin
  select * into v_row from players where lower(name) = lower(p_name);
  if not found or v_row.recovery_word_hash is null
     or crypt(p_recovery, v_row.recovery_word_hash) <> v_row.recovery_word_hash then
    raise exception 'no matching player / recovery word';
  end if;

  update players set token_hash = crypt(p_new_token, gen_salt('bf')) where id = v_row.id;
  return v_row.id;
end;
$$ language plpgsql security definer;

-- ----------------------------------------------------------------------------
-- READS
-- ----------------------------------------------------------------------------

-- Public roster (no token hashes exposed).
create view players_public as select id, name, created_at from players;

-- Public board: every player's pick per week, but the team is nulled out
-- (revealed = false) until that week's Saturday-11am reveal, regardless of
-- whether the game already kicked off Thu/Fri.
create or replace function get_public_board() returns table(
  player_id   uuid,
  player_name text,
  week        int,
  team        text,
  revealed    boolean
) as $$
  select
    p.id,
    p.name,
    pk.week,
    case when now() >= week_deadline(pk.week) then pk.team else null end,
    coalesce(now() >= week_deadline(pk.week), false)
  from players p
  join picks pk on pk.player_id = p.id;
$$ language sql stable security definer;

-- A player's own full history, always visible to them regardless of reveal
-- state, used to render their own menu / timeline / remaining allowance.
create or replace function get_my_picks(p_player_id uuid, p_token text) returns table(
  week            int,
  team            text,
  category        text,
  editable_until  timestamptz
) as $$
declare
  v_hash text;
begin
  select token_hash into v_hash from players where id = p_player_id;
  if v_hash is null or crypt(p_token, v_hash) <> v_hash then
    raise exception 'invalid credentials';
  end if;

  return query
    select pk.week, pk.team, classify_pick(pk.week, pk.team), pick_editable_until(pk.week, pk.team)
    from picks pk
    where pk.player_id = p_player_id
    order by pk.week;
end;
$$ language plpgsql stable;

-- ----------------------------------------------------------------------------
-- COMMISSIONER (admin) functions — require a real Supabase Auth session
-- whose auth.uid() is present in the admins table.
-- ----------------------------------------------------------------------------

create or replace function admin_get_all_picks() returns table(
  player_id   uuid,
  player_name text,
  week        int,
  team        text,
  last_edited_by text,
  admin_note  text,
  updated_at  timestamptz
) as $$
  select p.id, p.name, pk.week, pk.team, pk.last_edited_by, pk.admin_note, pk.updated_at
  from picks pk
  join players p on p.id = pk.player_id
  where exists(select 1 from admins where user_id = auth.uid())
  order by p.name, pk.week;
$$ language sql stable security definer;

create or replace function admin_set_pick(
  p_player_id uuid,
  p_week      int,
  p_team      text,
  p_note      text default null
) returns void as $$
begin
  if not exists(select 1 from admins where user_id = auth.uid()) then
    raise exception 'not authorized';
  end if;

  insert into picks (player_id, week, team, last_edited_by, admin_note, updated_at)
  values (p_player_id, p_week, p_team, 'commissioner', p_note, now())
  on conflict (player_id, week)
  do update set team = excluded.team, last_edited_by = 'commissioner',
                admin_note = excluded.admin_note, updated_at = now();
end;
$$ language plpgsql security definer;

create or replace function admin_delete_pick(p_player_id uuid, p_week int) returns void as $$
begin
  if not exists(select 1 from admins where user_id = auth.uid()) then
    raise exception 'not authorized';
  end if;

  delete from picks where player_id = p_player_id and week = p_week;
end;
$$ language plpgsql security definer;

-- ----------------------------------------------------------------------------
-- LOCKDOWN: enable RLS with no anon policies on the sensitive tables, forcing
-- all access through the functions/views above. games + classification are
-- harmless to read directly, so anon gets plain SELECT on those.
-- ----------------------------------------------------------------------------

alter table players enable row level security;
alter table picks enable row level security;
alter table games enable row level security;
alter table opponent_classification enable row level security;
alter table admins enable row level security;
-- (no policies created for players/picks/admins -> zero direct anon access)

create policy "games are public" on games for select using (true);
create policy "classification is public" on opponent_classification for select using (true);

grant usage on schema public to anon, authenticated;
grant select on games, opponent_classification, players_public to anon, authenticated;
grant execute on function
  signup, recover_player, submit_pick, get_public_board, get_my_picks,
  classify_pick, opponent_of, pick_editable_until, week_deadline
  to anon, authenticated;
grant execute on function admin_get_all_picks, admin_set_pick, admin_delete_pick to authenticated;
