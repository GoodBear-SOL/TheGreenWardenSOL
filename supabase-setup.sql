-- =========================================================
-- THE GREEN WARDEN — SOCIAL TASKS ADD-ON
-- =========================================================
-- Purpose:
--   Adds "Like the post" / "Share the post" tasks.
--
-- Requirements from existing Green Warden database:
--   public.profiles.id = auth user UUID
--   public.profiles.wp = user's WP balance
--
-- This version does NOT modify get_my_status().
-- It creates a separate get_task_board() function instead.
--
-- Safe to re-run.
-- =========================================================


-- =========================================================
-- 1. TASK CATALOG
-- =========================================================

create table if not exists public.tasks (
    id          text primary key,
    label       text not null,
    url         text not null,
    wp_reward   integer not null check (wp_reward > 0),
    needs_proof boolean not null default false,
    active      boolean not null default true,
    sort_order  integer not null default 0,
    created_at  timestamptz not null default now()
);


-- Enable Row Level Security
alter table public.tasks enable row level security;


-- Remove old policy if it exists
drop policy if exists "tasks_read" on public.tasks;


-- Signed-in users can read tasks
create policy "tasks_read"
on public.tasks
for select
to authenticated
using (true);


-- =========================================================
-- 2. SEED SOCIAL TASKS
-- =========================================================
-- Change the URL below to your actual X post URL.
--
-- Example:
-- https://x.com/ThegoodbearSOL/status/1234567890123456789
--
-- DO NOT use only your profile URL if the task is supposed
-- to be for a specific post.
-- =========================================================

insert into public.tasks
    (id, label, url, wp_reward, needs_proof, sort_order)
values
    (
        'like-launch-post',
        'Like the post',
        'https://x.com/ThegoodbearSOL',
        50,
        false,
        1
    ),
    (
        'share-launch-post',
        'Share the post',
        'https://x.com/ThegoodbearSOL',
        50,
        true,
        2
    )
on conflict (id) do update
set
    label       = excluded.label,
    url         = excluded.url,
    wp_reward   = excluded.wp_reward,
    needs_proof = excluded.needs_proof,
    sort_order  = excluded.sort_order;


-- =========================================================
-- 3. TASK CLAIMS
-- =========================================================
-- One claim per user per task.
-- The primary key prevents double claiming.
-- =========================================================

create table if not exists public.task_claims (
    user_id    uuid not null
        references auth.users(id)
        on delete cascade,

    task_id    text not null
        references public.tasks(id)
        on delete cascade,

    wp_awarded integer not null,
    proof_url  text,
    claimed_at timestamptz not null default now(),

    primary key (user_id, task_id)
);


-- Enable Row Level Security
alter table public.task_claims enable row level security;


-- Remove old policy if it exists
drop policy if exists "task_claims_read_own"
on public.task_claims;


-- Users can see only their own claims
create policy "task_claims_read_own"
on public.task_claims
for select
to authenticated
using (user_id = auth.uid());


-- IMPORTANT:
-- There is intentionally NO INSERT policy.
-- Users cannot directly insert claims from the browser.
-- Claims must go through claim_task().


-- =========================================================
-- 4. CLAIM TASK FUNCTION
-- =========================================================

create or replace function public.claim_task(
    p_task_id text,
    p_proof_url text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_uid       uuid;
    v_task      public.tasks%rowtype;
    v_wp_award  integer;
    v_profile_exists boolean;
begin

    -- -----------------------------------------------------
    -- Identify logged-in user
    -- -----------------------------------------------------

    v_uid := auth.uid();

    if v_uid is null then
        return jsonb_build_object(
            'ok', false,
            'error', 'NOT_AUTHENTICATED'
        );
    end if;


    -- -----------------------------------------------------
    -- Verify that the user's profile exists
    -- -----------------------------------------------------

    select exists (
        select 1
        from public.profiles
        where id = v_uid
    )
    into v_profile_exists;

    if not v_profile_exists then
        return jsonb_build_object(
            'ok', false,
            'error', 'PROFILE_NOT_FOUND'
        );
    end if;


    -- -----------------------------------------------------
    -- Find task
    -- -----------------------------------------------------

    select *
    into v_task
    from public.tasks
    where id = p_task_id;


    if not found then
        return jsonb_build_object(
            'ok', false,
            'error', 'UNKNOWN_TASK'
        );
    end if;


    -- -----------------------------------------------------
    -- Check whether task is active
    -- -----------------------------------------------------

    if not v_task.active then
        return jsonb_build_object(
            'ok', false,
            'error', 'TASK_INACTIVE'
        );
    end if;


    v_wp_award := v_task.wp_reward;


    -- -----------------------------------------------------
    -- Create claim
    --
    -- The primary key (user_id, task_id) guarantees that
    -- the same user cannot claim the same task twice.
    -- -----------------------------------------------------

    begin

        insert into public.task_claims (
            user_id,
            task_id,
            wp_awarded,
            proof_url
        )
        values (
            v_uid,
            p_task_id,
            v_wp_award,
            nullif(trim(p_proof_url), '')
        );

    exception
        when unique_violation then

            return jsonb_build_object(
                'ok', false,
                'error', 'ALREADY_CLAIMED'
            );

    end;


    -- -----------------------------------------------------
    -- Award WP
    -- -----------------------------------------------------

    update public.profiles
    set wp = coalesce(wp, 0) + v_wp_award
    where id = v_uid;


    -- -----------------------------------------------------
    -- Return success
    -- -----------------------------------------------------

    return jsonb_build_object(
        'ok', true,
        'task_id', p_task_id,
        'wp_awarded', v_wp_award
    );

end;
$$;


-- Allow signed-in users to call the function
grant execute
on function public.claim_task(text, text)
to authenticated;


-- =========================================================
-- 5. TASK BOARD FUNCTION
-- =========================================================
-- Instead of modifying your existing get_my_status(),
-- this gives the dashboard a dedicated function for tasks.
--
-- It returns:
--
-- {
--   "tasks": [...],
--   "task_claims": [...]
-- }
-- =========================================================

create or replace function public.get_task_board()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_uid uuid;
begin

    v_uid := auth.uid();

    if v_uid is null then
        return jsonb_build_object(
            'ok', false,
            'error', 'NOT_AUTHENTICATED'
        );
    end if;


    return jsonb_build_object(

        'ok', true,

        'tasks',
        (
            select coalesce(
                jsonb_agg(
                    jsonb_build_object(
                        'id', t.id,
                        'label', t.label,
                        'url', t.url,
                        'wp_reward', t.wp_reward,
                        'needs_proof', t.needs_proof
                    )
                    order by t.sort_order
                ),
                '[]'::jsonb
            )
            from public.tasks t
            where t.active = true
        ),

        'task_claims',
        (
            select coalesce(
                jsonb_agg(
                    jsonb_build_object(
                        'task_id', c.task_id,
                        'wp_awarded', c.wp_awarded,
                        'claimed_at', c.claimed_at
                    )
                    order by c.claimed_at desc
                ),
                '[]'::jsonb
            )
            from public.task_claims c
            where c.user_id = v_uid
        )

    );

end;
$$;


-- Allow signed-in users to call the task board
grant execute
on function public.get_task_board()
to authenticated;


-- =========================================================
-- 6. OPTIONAL ADMIN VIEW
-- =========================================================
-- This does NOT expose the view to normal users.
-- You can run the SELECT manually in Supabase SQL Editor
-- when you want to review claims.
-- =========================================================

-- Example:
--
-- select
--     tc.claimed_at,
--     tc.user_id,
--     p.username,
--     p.google_name,
--     t.label,
--     tc.wp_awarded,
--     tc.proof_url
-- from public.task_claims tc
-- join public.tasks t
--     on t.id = tc.task_id
-- left join public.profiles p
--     on p.id = tc.user_id
-- order by tc.claimed_at desc;


-- =========================================================
-- 7. VERIFY INSTALLATION
-- =========================================================
-- These queries should return your new tables/functions.
-- =========================================================

select
    id,
    label,
    url,
    wp_reward,
    needs_proof,
    active,
    sort_order
from public.tasks
order by sort_order;


select
    routine_name
from information_schema.routines
where routine_schema = 'public'
and routine_name in (
    'claim_task',
    'get_task_board'
)
order by routine_name;
