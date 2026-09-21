```sql
-- ============================================================================
--  THE GREEN WARDEN — FINAL DATABASE SETUP
--
--  Supabase → SQL Editor → New query → Run
--
--  Includes:
--    • Google profile information
--    • Warden username
--    • X username
--    • Solana public wallet address (MANUAL ENTRY — NO WALLET CONNECTION)
--    • Warden XP
--    • Daily check-in rewards
--    • Streak system
--    • Leaderboard
--    • +5 XP one-time X account bonus
--    • +5 XP one-time Solana wallet bonus
--
--  IMPORTANT:
--    XP bonuses are awarded by database functions, not browser JavaScript.
--    This prevents users from repeatedly claiming the bonuses.
-- ============================================================================


-- ============================================================================
-- TABLES
-- ============================================================================

create table if not exists public.profiles (
  id                  uuid primary key references auth.users(id) on delete cascade,
  google_name         text,
  avatar_url          text,
  username            text,
  x_username          text,
  wallet_address      text,

  wp                  integer not null default 0,
  streak              integer not null default 0,
  best_streak         integer not null default 0,
  last_checkin        date,

  -- One-time profile bonuses
  x_bonus_claimed     boolean not null default false,
  wallet_bonus_claimed boolean not null default false,

  created_at          timestamptz not null default now()
);


-- ============================================================================
-- SAFE COLUMN ADDITIONS
-- These allow this SQL to work even if the original database already exists.
-- ============================================================================

alter table public.profiles
  add column if not exists wallet_address text;

alter table public.profiles
  add column if not exists x_bonus_claimed boolean not null default false;

alter table public.profiles
  add column if not exists wallet_bonus_claimed boolean not null default false;


-- ============================================================================
-- INDEXES
-- ============================================================================

create unique index if not exists profiles_username_lower_idx
  on public.profiles (lower(username))
  where username is not null;

create index if not exists profiles_wp_idx
  on public.profiles (wp desc, created_at asc);

create index if not exists profiles_wallet_address_idx
  on public.profiles (wallet_address)
  where wallet_address is not null;


-- ============================================================================
-- CHECK-IN HISTORY
-- ============================================================================

create table if not exists public.checkins (
  user_id       uuid not null references public.profiles(id) on delete cascade,
  day           date not null,
  day_in_cycle  integer not null,
  wp_awarded    integer not null,
  created_at    timestamptz not null default now(),

  primary key (user_id, day)
);


-- ============================================================================
-- ROW LEVEL SECURITY
-- ============================================================================

alter table public.profiles enable row level security;
alter table public.checkins enable row level security;


-- --------------------------------------------------------------------------
-- PROFILE POLICY
-- --------------------------------------------------------------------------

drop policy if exists "read own profile" on public.profiles;

create policy "read own profile"
  on public.profiles
  for select
  to authenticated
  using (auth.uid() = id);


-- --------------------------------------------------------------------------
-- CHECK-IN POLICY
-- --------------------------------------------------------------------------

drop policy if exists "read own checkins" on public.checkins;

create policy "read own checkins"
  on public.checkins
  for select
  to authenticated
  using (auth.uid() = user_id);


-- ============================================================================
-- MANILA TIME HELPERS
-- ============================================================================

create or replace function public.manila_today()
returns date
language sql
stable
as $$
  select (now() at time zone 'Asia/Manila')::date;
$$;


create or replace function public.manila_seconds_to_reset()
returns integer
language sql
stable
as $$
  select greatest(
    0,
    ceil(
      extract(
        epoch from
        (
          (((now() at time zone 'Asia/Manila')::date + 1)::timestamp
            at time zone 'Asia/Manila')
          - now()
        )
      )
    )::int
  );
$$;


-- ============================================================================
-- 7-DAY REWARD LADDER
--
-- Day 1 = 5 XP
-- Day 2 = 10 XP
-- Day 3 = 15 XP
-- Day 4 = 20 XP
-- Day 5 = 25 XP
-- Day 6 = 30 XP
-- Day 7 = 50 XP
-- ============================================================================

create or replace function public.wp_for_day(p_day integer)
returns integer
language sql
immutable
as $$
  select
    (array[5,10,15,20,25,30,50])
    [greatest(1, least(7, coalesce(p_day, 1)))];
$$;


-- ============================================================================
-- EFFECTIVE STREAK
-- A streak survives if the previous check-in was today or yesterday.
-- ============================================================================

create or replace function public.effective_streak(
  p_last date,
  p_streak integer
)
returns integer
language sql
immutable
as $$
  select case
    when p_last is null then 0
    when p_last >= (select public.manila_today()) - 1
      then greatest(coalesce(p_streak, 0), 0)
    else 0
  end;
$$;


-- ============================================================================
-- BASIC SOLANA ADDRESS VALIDATION
--
-- This checks the expected Base58 character format and length.
-- It does NOT connect to a wallet or automatically verify ownership.
-- ============================================================================

create or replace function public.is_valid_solana_address(
  p_wallet text
)
returns boolean
language sql
immutable
as $$
  select
    p_wallet is null
    or (
      length(trim(p_wallet)) between 32 and 44
      and trim(p_wallet) ~ '^[1-9A-HJ-NP-Za-km-z]+$'
    );
$$;


-- ============================================================================
-- ENSURE PROFILE
-- Creates the profile on first visit and refreshes Google name/photo.
-- ============================================================================

create or replace function public.ensure_profile()
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id   uuid := auth.uid();
  v_meta jsonb := coalesce(
    auth.jwt() -> 'user_metadata',
    '{}'::jsonb
  );

  v_name text := nullif(
    trim(
      coalesce(
        v_meta ->> 'full_name',
        v_meta ->> 'name',
        ''
      )
    ),
    ''
  );

  v_pic text := nullif(
    trim(
      coalesce(
        v_meta ->> 'avatar_url',
        v_meta ->> 'picture',
        ''
      )
    ),
    ''
  );

  p public.profiles;

begin

  if v_id is null then
    raise exception 'NOT_AUTHENTICATED'
      using errcode = '28000';
  end if;


  insert into public.profiles (
    id,
    google_name,
    avatar_url
  )
  values (
    v_id,
    v_name,
    v_pic
  )

  on conflict (id) do update
    set
      google_name = coalesce(
        excluded.google_name,
        public.profiles.google_name
      ),

      avatar_url = coalesce(
        excluded.avatar_url,
        public.profiles.avatar_url
      )

  returning * into p;

  return p;

end;
$$;


-- ============================================================================
-- GET MY STATUS
-- ============================================================================

create or replace function public.get_my_status()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  p     public.profiles;
  v_eff integer;
  v_rank bigint;

begin

  p := public.ensure_profile();

  v_eff := public.effective_streak(
    p.last_checkin,
    p.streak
  );


  select count(*) + 1
  into v_rank

  from public.profiles x

  where x.wp > 0

    and (
      x.wp > p.wp

      or (
        x.wp = p.wp
        and x.created_at < p.created_at
      )
    );


  return json_build_object(

    'wp',
      p.wp,

    'streak',
      v_eff,

    'best_streak',
      p.best_streak,

    'rank',
      v_rank,

    'claimed_today',
      p.last_checkin = public.manila_today(),

    'last_checkin',
      p.last_checkin,

    'seconds_to_reset',
      public.manila_seconds_to_reset(),

    'username',
      p.username,

    'google_name',
      p.google_name,

    'avatar_url',
      p.avatar_url,

    'x_username',
      p.x_username,

    'wallet_address',
      p.wallet_address,

    'x_bonus_claimed',
      p.x_bonus_claimed,

    'wallet_bonus_claimed',
      p.wallet_bonus_claimed

  );

end;
$$;


-- ============================================================================
-- DAILY CHECK-IN
-- ============================================================================

create or replace function public.claim_checkin()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare

  p          public.profiles;

  v_today    date;

  v_streak   integer;

  v_day      integer;

  v_reward   integer;

  v_inserted integer;

begin

  p := public.ensure_profile();

  v_today := public.manila_today();


  -- Already claimed today
  if p.last_checkin = v_today then

    return json_build_object(
      'ok', false,
      'error', 'ALREADY_CLAIMED'
    );

  end if;


  -- Calculate new streak
  v_streak :=
    public.effective_streak(
      p.last_checkin,
      p.streak
    ) + 1;


  v_day :=
    ((v_streak - 1) % 7) + 1;


  v_reward :=
    public.wp_for_day(v_day);


  -- Database-level protection against duplicate claims
  insert into public.checkins (
    user_id,
    day,
    day_in_cycle,
    wp_awarded
  )

  values (
    p.id,
    v_today,
    v_day,
    v_reward
  )

  on conflict (user_id, day)
  do nothing;


  get diagnostics v_inserted = row_count;


  if v_inserted = 0 then

    return json_build_object(
      'ok', false,
      'error', 'ALREADY_CLAIMED'
    );

  end if;


  update public.profiles

  set
    wp = wp + v_reward,

    streak = v_streak,

    best_streak =
      greatest(best_streak, v_streak),

    last_checkin = v_today

  where id = p.id

  returning * into p;


  return json_build_object(

    'ok', true,

    'day',
      v_day,

    'wp_awarded',
      v_reward,

    'streak',
      p.streak,

    'wp',
      p.wp,

    'best_streak',
      p.best_streak

  );

end;
$$;


-- ============================================================================
-- LEADERBOARD
-- ============================================================================

create or replace function public.get_leaderboard(
  p_limit integer default 50
)

returns table (
  pos         bigint,
  display     text,
  avatar      text,
  x_handle    text,
  points      integer,
  day_streak  integer,
  me          boolean
)

language sql
security definer
set search_path = public
as $$

  select

    row_number() over (
      order by
        p.wp desc,
        p.created_at asc
    ) as pos,

    coalesce(
      nullif(p.username, ''),
      nullif(p.google_name, ''),
      'Warden'
    ) as display,

    p.avatar_url as avatar,

    p.x_username as x_handle,

    p.wp as points,

    public.effective_streak(
      p.last_checkin,
      p.streak
    ) as day_streak,

    (p.id = auth.uid()) as me

  from public.profiles p

  where p.wp > 0

  order by
    p.wp desc,
    p.created_at asc

  limit greatest(
    1,
    least(
      200,
      coalesce(p_limit, 50)
    )
  );

$$;


-- ============================================================================
-- UPDATE PROFILE
--
-- Saves:
--   • Username
--   • X username
--   • Solana wallet address
--
-- FIRST valid X username:
--   +5 XP
--
-- FIRST valid Solana wallet:
--   +5 XP
--
-- These bonuses can NEVER be claimed again for that account.
-- ============================================================================

-- Remove the old two-argument version so there is no function ambiguity.
drop function if exists public.update_profile(text, text);


create or replace function public.update_profile(
  p_username text,
  p_x_username text,
  p_wallet_address text default null
)

returns json

language plpgsql
security definer
set search_path = public

as $$

declare

  v_id uuid := auth.uid();

  v_u text := nullif(
    trim(coalesce(p_username, '')),
    ''
  );

  v_x text := nullif(
    trim(coalesce(p_x_username, '')),
    ''
  );

  v_wallet text := nullif(
    trim(coalesce(p_wallet_address, '')),
    ''
  );

  p public.profiles;

  v_x_bonus integer := 0;

  v_wallet_bonus integer := 0;

  v_new_wp integer;

begin


  -- ------------------------------------------------------------------------
  -- AUTH CHECK
  -- ------------------------------------------------------------------------

  if v_id is null then

    raise exception 'NOT_AUTHENTICATED'
      using errcode = '28000';

  end if;


  -- ------------------------------------------------------------------------
  -- LOAD PROFILE
  -- ------------------------------------------------------------------------

  p := public.ensure_profile();


  -- ------------------------------------------------------------------------
  -- CLEAN X USERNAME
  -- ------------------------------------------------------------------------

  v_x :=
    regexp_replace(
      coalesce(v_x, ''),
      '^@+',
      ''
    );

  v_x :=
    nullif(v_x, '');


  -- ------------------------------------------------------------------------
  -- VALIDATE WARDEN USERNAME
  -- ------------------------------------------------------------------------

  if v_u is not null
     and v_u !~ '^[A-Za-z0-9_]{3,20}$'
  then

    return json_build_object(
      'ok', false,
      'error', 'INVALID_USERNAME'
    );

  end if;


  -- ------------------------------------------------------------------------
  -- VALIDATE X USERNAME
  -- ------------------------------------------------------------------------

  if v_x is not null
     and v_x !~ '^[A-Za-z0-9_]{1,15}$'
  then

    return json_build_object(
      'ok', false,
      'error', 'INVALID_X'
    );

  end if;


  -- ------------------------------------------------------------------------
  -- VALIDATE SOLANA ADDRESS
  -- ------------------------------------------------------------------------

  if v_wallet is not null
     and not public.is_valid_solana_address(v_wallet)
  then

    return json_build_object(
      'ok', false,
      'error', 'INVALID_WALLET'
    );

  end if;


  -- ------------------------------------------------------------------------
  -- USERNAME UNIQUENESS
  -- ------------------------------------------------------------------------

  if v_u is not null
     and exists (
       select 1
       from public.profiles

       where lower(username) = lower(v_u)

       and id <> v_id
     )
  then

    return json_build_object(
      'ok', false,
      'error', 'USERNAME_TAKEN'
    );

  end if;


  -- ------------------------------------------------------------------------
  -- X BONUS
  --
  -- Only awarded when:
  --   1. A valid X username is supplied
  --   2. The user has never claimed the X bonus
  --
  -- Editing the X username later gives NO additional XP.
  -- ------------------------------------------------------------------------

  if v_x is not null
     and not p.x_bonus_claimed
  then

    v_x_bonus := 5;

  end if;


  -- ------------------------------------------------------------------------
  -- WALLET BONUS
  --
  -- Only awarded when:
  --   1. A valid Solana address is supplied
  --   2. The user has never claimed the wallet bonus
  --
  -- Editing the wallet later gives NO additional XP.
  -- ------------------------------------------------------------------------

  if v_wallet is not null
     and not p.wallet_bonus_claimed
  then

    v_wallet_bonus := 5;

  end if;


  -- ------------------------------------------------------------------------
  -- UPDATE PROFILE
  -- ------------------------------------------------------------------------

  update public.profiles

  set

    username = v_u,

    x_username = v_x,

    wallet_address = v_wallet,

    wp = wp + v_x_bonus + v_wallet_bonus,

    x_bonus_claimed =
      case
        when v_x_bonus > 0 then true
        else x_bonus_claimed
      end,

    wallet_bonus_claimed =
      case
        when v_wallet_bonus > 0 then true
        else wallet_bonus_claimed
      end

  where id = v_id

  returning * into p;


  -- ------------------------------------------------------------------------
  -- RETURN RESULT
  -- ------------------------------------------------------------------------

  v_new_wp := p.wp;


  return json_build_object(

    'ok',
      true,

    'username',
      p.username,

    'x_username',
      p.x_username,

    'wallet_address',
      p.wallet_address,

    'wp',
      v_new_wp,

    'x_bonus',
      v_x_bonus,

    'wallet_bonus',
      v_wallet_bonus,

    'total_bonus',
      v_x_bonus + v_wallet_bonus,

    'x_bonus_claimed',
      p.x_bonus_claimed,

    'wallet_bonus_claimed',
      p.wallet_bonus_claimed

  );


exception

  when unique_violation then

    return json_build_object(
      'ok', false,
      'error', 'USERNAME_TAKEN'
    );

end;

$$;


-- ============================================================================
-- FUNCTION PERMISSIONS
-- ============================================================================

revoke all
on function public.get_my_status()
from public;

revoke all
on function public.claim_checkin()
from public;

revoke all
on function public.get_leaderboard(integer)
from public;

revoke all
on function public.update_profile(text, text, text)
from public;

revoke all
on function public.ensure_profile()
from public;

revoke all
on function public.is_valid_solana_address(text)
from public;


grant execute
on function public.get_my_status()
to authenticated;

grant execute
on function public.claim_checkin()
to authenticated;

grant execute
on function public.get_leaderboard(integer)
to authenticated;

grant execute
on function public.update_profile(text, text, text)
to authenticated;

grant execute
on function public.ensure_profile()
to authenticated;

grant execute
on function public.is_valid_solana_address(text)
to authenticated;


-- ============================================================================
-- BACKFILL EXISTING GOOGLE USERS
-- ============================================================================

insert into public.profiles (
  id,
  google_name,
  avatar_url
)

select

  u.id,

  nullif(
    trim(
      coalesce(
        u.raw_user_meta_data ->> 'full_name',
        u.raw_user_meta_data ->> 'name',
        ''
      )
    ),
    ''
  ),

  nullif(
    trim(
      coalesce(
        u.raw_user_meta_data ->> 'avatar_url',
        u.raw_user_meta_data ->> 'picture',
        ''
      )
    ),
    ''
  )

from auth.users u

on conflict (id)
do nothing;


-- ============================================================================
-- DONE
--
-- Existing users:
--   • Keep their current WP
--   • Keep their current streak
--   • Keep their existing profile
--   • Can receive X +5 when they first add X
--   • Can receive Wallet +5 when they first add a wallet
--
-- New users:
--   • Start at 0 WP
--   • Can earn daily check-in XP
--   • Can earn +5 X bonus once
--   • Can earn +5 wallet bonus once
-- ============================================================================
```
