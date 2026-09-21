-- ============================================================================
--  THE GREEN WARDEN — database setup
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  It is safe to run more than once.
--
--  Creates everything dashboard.html expects:
--    get_my_status()      claim_checkin()      get_leaderboard(p_limit)      update_profile(p_username, p_x_username)
-- ============================================================================

-- ---------------------------------------------------------------- tables ---
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  google_name  text,
  avatar_url   text,
  username     text,
  x_username   text,
  wp           integer     not null default 0,
  streak       integer     not null default 0,
  best_streak  integer     not null default 0,
  last_checkin date,
  created_at   timestamptz not null default now()
);

-- one Warden name per person, case-insensitive
create unique index if not exists profiles_username_lower_idx
  on public.profiles (lower(username)) where username is not null;

create index if not exists profiles_wp_idx on public.profiles (wp desc, created_at asc);

-- an append-only log; the primary key is what makes a double check-in impossible
create table if not exists public.checkins (
  user_id    uuid    not null references public.profiles(id) on delete cascade,
  day        date    not null,
  day_in_cycle integer not null,
  wp_awarded integer not null,
  created_at timestamptz not null default now(),
  primary key (user_id, day)
);

-- ------------------------------------------------------------------ RLS ---
alter table public.profiles enable row level security;
alter table public.checkins enable row level security;

drop policy if exists "read own profile" on public.profiles;
create policy "read own profile" on public.profiles
  for select to authenticated using (auth.uid() = id);

drop policy if exists "read own checkins" on public.checkins;
create policy "read own checkins" on public.checkins
  for select to authenticated using (auth.uid() = user_id);

-- No insert/update policies on purpose: points, streaks and names can only be
-- changed through the functions below, so nobody can award themselves WP.

-- -------------------------------------------------------------- helpers ---
create or replace function public.manila_today()
returns date language sql stable as $$
  select (now() at time zone 'Asia/Manila')::date;
$$;

create or replace function public.manila_seconds_to_reset()
returns integer language sql stable as $$
  select greatest(0, ceil(extract(epoch from
    (((now() at time zone 'Asia/Manila')::date + 1)::timestamp at time zone 'Asia/Manila') - now()
  ))::int);
$$;

-- the 7-day reward ladder
create or replace function public.wp_for_day(p_day integer)
returns integer language sql immutable as $$
  select (array[5,10,15,20,25,30,50])[greatest(1, least(7, coalesce(p_day, 1)))];
$$;

-- a streak only survives if the last check-in was today or yesterday
create or replace function public.effective_streak(p_last date, p_streak integer)
returns integer language sql immutable as $$
  select case
    when p_last is null then 0
    when p_last >= (select public.manila_today()) - 1 then greatest(coalesce(p_streak, 0), 0)
    else 0
  end;
$$;

-- creates the row on first visit and keeps the Google name/photo fresh
create or replace function public.ensure_profile()
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare
  v_id   uuid   := auth.uid();
  v_meta jsonb  := coalesce(auth.jwt() -> 'user_metadata', '{}'::jsonb);
  v_name text   := nullif(trim(coalesce(v_meta ->> 'full_name', v_meta ->> 'name', '')), '');
  v_pic  text   := nullif(trim(coalesce(v_meta ->> 'avatar_url', v_meta ->> 'picture', '')), '');
  p      public.profiles;
begin
  if v_id is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;

  insert into public.profiles (id, google_name, avatar_url)
  values (v_id, v_name, v_pic)
  on conflict (id) do update
    set google_name = coalesce(excluded.google_name, public.profiles.google_name),
        avatar_url  = coalesce(excluded.avatar_url,  public.profiles.avatar_url)
  returning * into p;

  return p;
end;
$$;

-- --------------------------------------------------------- get_my_status ---
create or replace function public.get_my_status()
returns json
language plpgsql security definer set search_path = public as $$
declare
  p     public.profiles;
  v_eff integer;
  v_rank bigint;
begin
  p := public.ensure_profile();
  v_eff := public.effective_streak(p.last_checkin, p.streak);

  select count(*) + 1 into v_rank
  from public.profiles x
  where x.wp > 0
    and (x.wp > p.wp or (x.wp = p.wp and x.created_at < p.created_at));

  return json_build_object(
    'wp',               p.wp,
    'streak',           v_eff,
    'best_streak',      p.best_streak,
    'rank',             v_rank,
    'claimed_today',    p.last_checkin = public.manila_today(),
    'last_checkin',     p.last_checkin,
    'seconds_to_reset', public.manila_seconds_to_reset(),
    'username',         p.username,
    'google_name',      p.google_name,
    'avatar_url',       p.avatar_url,
    'x_username',       p.x_username
  );
end;
$$;

-- ---------------------------------------------------------- claim_checkin ---
create or replace function public.claim_checkin()
returns json
language plpgsql security definer set search_path = public as $$
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

  if p.last_checkin = v_today then
    return json_build_object('ok', false, 'error', 'ALREADY_CLAIMED');
  end if;

  v_streak := public.effective_streak(p.last_checkin, p.streak) + 1;
  v_day    := ((v_streak - 1) % 7) + 1;
  v_reward := public.wp_for_day(v_day);

  -- the real guard against double-claiming (two tabs, double click, retry)
  insert into public.checkins (user_id, day, day_in_cycle, wp_awarded)
  values (p.id, v_today, v_day, v_reward)
  on conflict (user_id, day) do nothing;

  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then
    return json_build_object('ok', false, 'error', 'ALREADY_CLAIMED');
  end if;

  update public.profiles
     set wp           = wp + v_reward,
         streak       = v_streak,
         best_streak  = greatest(best_streak, v_streak),
         last_checkin = v_today
   where id = p.id
   returning * into p;

  return json_build_object(
    'ok', true, 'day', v_day, 'wp_awarded', v_reward,
    'streak', p.streak, 'wp', p.wp, 'best_streak', p.best_streak
  );
end;
$$;

-- --------------------------------------------------------- get_leaderboard ---
create or replace function public.get_leaderboard(p_limit integer default 50)
returns table (
  pos bigint, display text, avatar text, x_handle text,
  points integer, day_streak integer, me boolean
)
language sql security definer set search_path = public as $$
  select
    row_number() over (order by p.wp desc, p.created_at asc)      as pos,
    coalesce(nullif(p.username, ''), nullif(p.google_name, ''), 'Warden') as display,
    p.avatar_url                                                  as avatar,
    p.x_username                                                  as x_handle,
    p.wp                                                          as points,
    public.effective_streak(p.last_checkin, p.streak)             as day_streak,
    (p.id = auth.uid())                                           as me
  from public.profiles p
  where p.wp > 0
  order by p.wp desc, p.created_at asc
  limit greatest(1, least(200, coalesce(p_limit, 50)));
$$;

-- ---------------------------------------------------------- update_profile ---
create or replace function public.update_profile(p_username text, p_x_username text)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := auth.uid();
  v_u  text := nullif(trim(coalesce(p_username, '')), '');
  v_x  text := nullif(trim(coalesce(p_x_username, '')), '');
begin
  if v_id is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  perform public.ensure_profile();

  v_x := regexp_replace(coalesce(v_x, ''), '^@+', '');
  v_x := nullif(v_x, '');

  if v_u is not null and v_u !~ '^[A-Za-z0-9_]{3,20}$' then
    return json_build_object('ok', false, 'error', 'INVALID_USERNAME');
  end if;
  if v_x is not null and v_x !~ '^[A-Za-z0-9_]{1,15}$' then
    return json_build_object('ok', false, 'error', 'INVALID_X');
  end if;

  if v_u is not null and exists (
    select 1 from public.profiles
     where lower(username) = lower(v_u) and id <> v_id
  ) then
    return json_build_object('ok', false, 'error', 'USERNAME_TAKEN');
  end if;

  update public.profiles
     set username = v_u, x_username = v_x
   where id = v_id;

  return json_build_object('ok', true, 'username', v_u, 'x_username', v_x);
exception
  when unique_violation then
    return json_build_object('ok', false, 'error', 'USERNAME_TAKEN');
end;
$$;

-- --------------------------------------------------------------- grants ---
revoke all on function public.get_my_status()                     from public;
revoke all on function public.claim_checkin()                     from public;
revoke all on function public.get_leaderboard(integer)            from public;
revoke all on function public.update_profile(text, text)          from public;
revoke all on function public.ensure_profile()                    from public;

grant execute on function public.get_my_status()            to authenticated;
grant execute on function public.claim_checkin()            to authenticated;
grant execute on function public.get_leaderboard(integer)   to authenticated;
grant execute on function public.update_profile(text, text) to authenticated;

-- ---------------------------------------- backfill anyone who signed in first ---
insert into public.profiles (id, google_name, avatar_url)
select u.id,
       nullif(trim(coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name', '')), ''),
       nullif(trim(coalesce(u.raw_user_meta_data ->> 'avatar_url', u.raw_user_meta_data ->> 'picture', '')), '')
from auth.users u
on conflict (id) do nothing;
