-- =========================================================
-- THE GREEN WARDEN — SOCIAL TASKS SYSTEM
-- =========================================================
-- Purpose:
--   Social engagement tasks with mandatory proof support.
--
-- Requirements:
--   public.profiles.id = auth user UUID
--   public.profiles.wp = user's WP balance
--
-- This SQL:
--   1. Creates/updates the task catalog
--   2. Creates/updates task claims
--   3. Requires proof when a task needs proof
--   4. Prevents duplicate claims
--   5. Validates submitted proof URLs
--   6. Awards WP only after a valid claim is created
--   7. Provides the dashboard task board
--
-- IMPORTANT:
--   Replace the two X URLs below with your ACTUAL X POST URLs.
--
-- Example:
--   https://x.com/ThegoodbearSOL/status/1234567890123456789
--
-- Do NOT use only:
--   https://x.com/ThegoodbearSOL
--
-- =========================================================


-- =========================================================
-- 1. TASK CATALOG
-- =========================================================

create table if not exists public.tasks (
    id              text primary key,
    label           text not null,
    url             text not null,
    wp_reward       integer not null check (wp_reward > 0),
    needs_proof     boolean not null default false,
    active          boolean not null default true,
    sort_order      integer not null default 0,
    created_at      timestamptz not null default now()
);


-- Enable RLS
alter table public.tasks enable row level security;


-- Recreate read policy safely
drop policy if exists "tasks_read"
on public.tasks;


create policy "tasks_read"
on public.tasks
for select
to authenticated
using (true);


-- =========================================================
-- 2. SOCIAL TASKS
-- =========================================================
--
-- IMPORTANT:
-- Replace the URLs below before running this SQL.
--
-- For the Like task, proof is mandatory as a self-report.
-- A submitted X URL does NOT technically prove that the
-- user clicked Like. It is stored for manual review.
--
-- If you want stronger proof for the first task, consider
-- changing it later to "Like + Reply to the post" so the
-- user can submit the URL of their own reply.
--
-- =========================================================

insert into public.tasks (
    id,
    label,
    url,
    wp_reward,
    needs_proof,
    active,
    sort_order
)
values
(
    'like-launch-post',
    'Like the Green Warden post',
    'https://x.com/GreenWardenSol/status/2102614430681022855?s=20',
    50,
    true,
    true,
    1
),
(
    'share-launch-post',
    'Share the Green Warden post',
    'https://x.com/GreenWardenSol/status/2102614430681022855?s=20',
    50,
    true,
    true,
    2
)
on conflict (id) do update
set
    label       = excluded.label,
    url         = excluded.url,
    wp_reward   = excluded.wp_reward,
    needs_proof = excluded.needs_proof,
    active      = excluded.active,
    sort_order  = excluded.sort_order;


-- =========================================================
-- 3. TASK CLAIMS
-- =========================================================

create table if not exists public.task_claims (
    user_id       uuid not null
        references auth.users(id)
        on delete cascade,

    task_id       text not null
        references public.tasks(id)
        on delete cascade,

    wp_awarded    integer not null,
    proof_url     text,
    claimed_at    timestamptz not null default now(),

    primary key (user_id, task_id)
);


-- Enable RLS
alter table public.task_claims enable row level security;


-- Recreate user's own claims policy
drop policy if exists "task_claims_read_own"
on public.task_claims;


create policy "task_claims_read_own"
on public.task_claims
for select
to authenticated
using (
    user_id = auth.uid()
);


-- IMPORTANT:
-- There is intentionally NO INSERT policy.
--
-- Users cannot directly insert task claims from the browser.
-- Claims must go through claim_task().
--


-- =========================================================
-- 4. CLAIM TASK FUNCTION
-- =========================================================
--
-- Security improvements:
--
--   • Requires authentication
--   • Requires an existing profile
--   • Requires an active task
--   • Prevents duplicate claims
--   • Requires proof when needs_proof = true
--   • Rejects obviously invalid proof URLs
--   • Accepts only HTTP/HTTPS proof URLs
--   • For X tasks, requires an X/Twitter URL
--
-- IMPORTANT:
--   This does NOT automatically verify that the user actually
--   performed the action on X.
--   It only requires the user to submit proof.
--
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
    v_uid               uuid;
    v_task              public.tasks%rowtype;
    v_wp_award          integer;
    v_profile_exists    boolean;
    v_proof             text;
begin

    -- -----------------------------------------------------
    -- 1. Identify logged-in user
    -- -----------------------------------------------------

    v_uid := auth.uid();

    if v_uid is null then

        return jsonb_build_object(
            'ok', false,
            'error', 'NOT_AUTHENTICATED'
        );

    end if;


    -- -----------------------------------------------------
    -- 2. Verify profile exists
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
    -- 3. Find task
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
    -- 4. Check task status
    -- -----------------------------------------------------

    if not v_task.active then

        return jsonb_build_object(
            'ok', false,
            'error', 'TASK_INACTIVE'
        );

    end if;


    v_wp_award := v_task.wp_reward;


    -- -----------------------------------------------------
    -- 5. Clean proof URL
    -- -----------------------------------------------------

    v_proof := nullif(
        trim(coalesce(p_proof_url, '')),
        ''
    );


    -- -----------------------------------------------------
    -- 6. Require proof when configured
    -- -----------------------------------------------------

    if v_task.needs_proof = true
       and v_proof is null then

        return jsonb_build_object(
            'ok', false,
            'error', 'PROOF_REQUIRED'
        );

    end if;


    -- -----------------------------------------------------
    -- 7. Validate proof URL format
    -- -----------------------------------------------------
    --
    -- Only HTTP/HTTPS URLs are accepted.
    --

    if v_proof is not null then

        if v_proof !~* '^https?://'
        then

            return jsonb_build_object(
                'ok', false,
                'error', 'INVALID_PROOF_URL'
            );

        end if;

    end if;


    -- -----------------------------------------------------
    -- 8. X-specific proof validation
    -- -----------------------------------------------------
    --
    -- Social tasks currently use X.
    --
    -- We accept:
    --   x.com
    --   www.x.com
    --   twitter.com
    --   www.twitter.com
    --
    -- This does NOT verify the action itself.
    --

    if v_task.needs_proof = true then

        if v_proof !~* '^https?://(www\.)?(x\.com|twitter\.com)/'
        then

            return jsonb_build_object(
                'ok', false,
                'error', 'INVALID_X_PROOF_URL'
            );

        end if;

    end if;


    -- -----------------------------------------------------
    -- 9. Prevent duplicate claim
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
            v_proof
        );

    exception
        when unique_violation then

            return jsonb_build_object(
                'ok', false,
                'error', 'ALREADY_CLAIMED'
            );

    end;


    -- -----------------------------------------------------
    -- 10. Award WP
    -- -----------------------------------------------------

    update public.profiles
    set wp = coalesce(wp, 0) + v_wp_award
    where id = v_uid;


    -- -----------------------------------------------------
    -- 11. Return success
    -- -----------------------------------------------------

    return jsonb_build_object(
        'ok', true,
        'task_id', p_task_id,
        'wp_awarded', v_wp_award,
        'proof_submitted', (v_proof is not null)
    );


end;
$$;


-- =========================================================
-- 5. FUNCTION PERMISSION
-- =========================================================

grant execute
on function public.claim_task(text, text)
to authenticated;


-- =========================================================
-- 6. TASK BOARD FUNCTION
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

    -- -----------------------------------------------------
    -- Identify user
    -- -----------------------------------------------------

    v_uid := auth.uid();


    if v_uid is null then

        return jsonb_build_object(
            'ok', false,
            'error', 'NOT_AUTHENTICATED'
        );

    end if;


    -- -----------------------------------------------------
    -- Return task board
    -- -----------------------------------------------------

    return jsonb_build_object(

        'ok',
        true,


        -- -------------------------------------------------
        -- ACTIVE TASKS
        -- -------------------------------------------------

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


        -- -------------------------------------------------
        -- USER CLAIMS
        -- -------------------------------------------------

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


-- =========================================================
-- 7. FUNCTION PERMISSION
-- =========================================================

grant execute
on function public.get_task_board()
to authenticated;


-- =========================================================
-- 8. ADMIN REVIEW QUERY
-- =========================================================
--
-- DO NOT create this as a public view.
--
-- Run this manually in Supabase SQL Editor when you want
-- to inspect submitted proofs.
--
-- =========================================================

-- SELECT
--     tc.claimed_at,
--     tc.user_id,
--     p.username,
--     p.google_name,
--     t.id AS task_id,
--     t.label,
--     tc.wp_awarded,
--     tc.proof_url
-- FROM public.task_claims tc
-- JOIN public.tasks t
--     ON t.id = tc.task_id
-- LEFT JOIN public.profiles p
--     ON p.id = tc.user_id
-- ORDER BY tc.claimed_at DESC;


-- =========================================================
-- 9. VERIFY TASK CATALOG
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


-- =========================================================
-- 10. VERIFY FUNCTIONS
-- =========================================================

select
    routine_name
from information_schema.routines
where routine_schema = 'public'
and routine_name in (
    'claim_task',
    'get_task_board'
)
order by routine_name;


-- =========================================================
-- 11. VERIFY CLAIM TABLE
-- =========================================================

select
    column_name,
    data_type,
    is_nullable
from information_schema.columns
where table_schema = 'public'
and table_name = 'task_claims'
order by ordinal_position;
