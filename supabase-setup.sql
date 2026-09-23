-- ============================================================
-- THE GREEN WARDEN
-- SOCIAL TASK + MANUAL VERIFICATION SYSTEM
-- ============================================================
--
-- FLOW:
--
--   User opens X task
--          ↓
--   User completes the task
--          ↓
--   User pastes proof URL
--          ↓
--   Submit for Review
--          ↓
--   status = pending
--          ↓
--   ADMIN manually checks X
--          ↓
--   APPROVE
--          ↓
--   WP is awarded
--
-- WP IS NOT AWARDED WHEN THE USER SUBMITS PROOF.
--
-- Existing task claims are preserved as APPROVED because
-- the old system already awarded their WP.
--
-- Requirements:
--
--   public.profiles.id = auth user UUID
--   public.profiles.wp = user's WP balance
--
-- ============================================================


begin;


-- ============================================================
-- 1. TASK CATALOG
-- ============================================================

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


-- Recreate read policy
drop policy if exists "tasks_read"
on public.tasks;


create policy "tasks_read"
on public.tasks
for select
to authenticated
using (true);


-- ============================================================
-- 2. SOCIAL TASKS
-- ============================================================
--
-- The first task is Like + Reply.
--
-- Why?
--
-- A Like by itself does not provide a reliable public URL
-- that you can use to manually verify the user performed it.
--
-- A Reply DOES provide a public X URL.
--
-- The second task uses Quote/Share so the user can submit
-- the public URL of their quote post.
--
-- ============================================================


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
    'Like + Reply to the Green Warden post',
    'https://x.com/GreenWardenSol/status/2102614430681022855?s=20',
    50,
    true,
    true,
    1
),

(
    'share-launch-post',
    'Quote/Share the Green Warden post',
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


-- ============================================================
-- 3. REMOVE OLD CLAIM FUNCTION
-- ============================================================
--
-- IMPORTANT:
--
-- Your previous claim_task() function immediately awarded WP.
--
-- We must remove it so nobody can bypass manual verification.
--
-- ============================================================


revoke all
on function public.claim_task(text, text)
from public;

revoke all
on function public.claim_task(text, text)
from anon;

revoke all
on function public.claim_task(text, text)
from authenticated;


drop function if exists public.claim_task(text, text);


-- ============================================================
-- 4. TASK CLAIMS TABLE
-- ============================================================


create table if not exists public.task_claims (
    user_id       uuid not null
        references auth.users(id)
        on delete cascade,

    task_id       text not null
        references public.tasks(id)
        on delete cascade,

    wp_awarded    integer not null default 0,

    proof_url     text,

    claimed_at    timestamptz not null default now(),

    primary key (user_id, task_id)
);


-- Enable RLS
alter table public.task_claims enable row level security;


-- ============================================================
-- 5. ADD REVIEW STATUS
-- ============================================================


alter table public.task_claims
add column if not exists status text;


alter table public.task_claims
add column if not exists reviewed_at timestamptz;


alter table public.task_claims
add column if not exists reviewed_by uuid;


-- ============================================================
-- 6. PRESERVE EXISTING CLAIMS
-- ============================================================
--
-- Existing claims came from the old system.
--
-- Since the old system already awarded their WP, mark them
-- as approved so they remain valid.
--
-- ============================================================


update public.task_claims
set status = 'approved'
where status is null;


-- ============================================================
-- 7. DEFAULT STATUS
-- ============================================================


alter table public.task_claims
alter column status set default 'pending';


-- ============================================================
-- 8. STATUS CONSTRAINT
-- ============================================================


alter table public.task_claims
drop constraint if exists task_claims_status_check;


alter table public.task_claims
add constraint task_claims_status_check
check (
    status in (
        'pending',
        'approved',
        'rejected'
    )
);


-- ============================================================
-- 9. RECREATE USER CLAIM READ POLICY
-- ============================================================


drop policy if exists "task_claims_read_own"
on public.task_claims;


create policy "task_claims_read_own"
on public.task_claims
for select
to authenticated
using (
    user_id = auth.uid()
);


-- ============================================================
-- IMPORTANT:
--
-- There is NO INSERT policy.
--
-- There is NO UPDATE policy.
--
-- Users cannot directly create or modify claims.
--
-- All submissions must go through:
--
--     submit_task_for_review()
--
-- ============================================================


-- ============================================================
-- 10. SUBMIT TASK FOR MANUAL REVIEW
-- ============================================================
--
-- This function:
--
--   1. Requires authentication
--   2. Requires a profile
--   3. Requires an active task
--   4. Requires proof
--   5. Validates the proof URL
--   6. Requires X/Twitter URL
--   7. Creates a PENDING claim
--   8. DOES NOT AWARD WP
--
-- ============================================================


create or replace function public.submit_task_for_review(
    p_task_id text,
    p_proof_url text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$

declare
    v_uid            uuid;
    v_task           public.tasks%rowtype;
    v_proof          text;
    v_existing       public.task_claims%rowtype;

begin

    -- --------------------------------------------------------
    -- 1. Identify authenticated user
    -- --------------------------------------------------------

    v_uid := auth.uid();


    if v_uid is null then

        return jsonb_build_object(
            'ok', false,
            'error', 'NOT_AUTHENTICATED'
        );

    end if;


    -- --------------------------------------------------------
    -- 2. Verify profile exists
    -- --------------------------------------------------------

    if not exists (
        select 1
        from public.profiles
        where id = v_uid
    ) then

        return jsonb_build_object(
            'ok', false,
            'error', 'PROFILE_NOT_FOUND'
        );

    end if;


    -- --------------------------------------------------------
    -- 3. Find task
    -- --------------------------------------------------------

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


    -- --------------------------------------------------------
    -- 4. Verify task is active
    -- --------------------------------------------------------

    if not v_task.active then

        return jsonb_build_object(
            'ok', false,
            'error', 'TASK_INACTIVE'
        );

    end if;


    -- --------------------------------------------------------
    -- 5. Clean proof URL
    -- --------------------------------------------------------

    v_proof := nullif(
        trim(coalesce(p_proof_url, '')),
        ''
    );


    -- --------------------------------------------------------
    -- 6. Proof is mandatory
    -- --------------------------------------------------------

    if v_task.needs_proof = true
       and v_proof is null then

        return jsonb_build_object(
            'ok', false,
            'error', 'PROOF_REQUIRED'
        );

    end if;


    -- --------------------------------------------------------
    -- 7. Validate HTTP/HTTPS
    -- --------------------------------------------------------

    if v_proof !~* '^https?://' then

        return jsonb_build_object(
            'ok', false,
            'error', 'INVALID_PROOF_URL'
        );

    end if;


    -- --------------------------------------------------------
    -- 8. Validate X/Twitter URL
    -- --------------------------------------------------------

    if v_proof !~* '^https?://(www\.)?(x\.com|twitter\.com)/' then

        return jsonb_build_object(
            'ok', false,
            'error', 'INVALID_X_PROOF_URL'
        );

    end if;


    -- --------------------------------------------------------
    -- 9. Check existing claim
    -- --------------------------------------------------------

    select *
    into v_existing
    from public.task_claims
    where user_id = v_uid
      and task_id = p_task_id;


    -- --------------------------------------------------------
    -- 10. Existing approved claim
    -- --------------------------------------------------------

    if found
       and v_existing.status = 'approved' then

        return jsonb_build_object(
            'ok', false,
            'error', 'ALREADY_APPROVED'
        );

    end if;


    -- --------------------------------------------------------
    -- 11. Existing pending claim
    -- --------------------------------------------------------

    if found
       and v_existing.status = 'pending' then

        return jsonb_build_object(
            'ok', false,
            'error', 'ALREADY_PENDING'
        );

    end if;


    -- --------------------------------------------------------
    -- 12. Rejected claim can be resubmitted
    -- --------------------------------------------------------

    if found
       and v_existing.status = 'rejected' then

        update public.task_claims
        set
            proof_url   = v_proof,
            status      = 'pending',
            claimed_at  = now(),
            reviewed_at = null,
            reviewed_by = null,
            wp_awarded  = 0

        where user_id = v_uid
          and task_id = p_task_id;


    else

        -- ----------------------------------------------------
        -- 13. Create new pending claim
        -- ----------------------------------------------------

        insert into public.task_claims (
            user_id,
            task_id,
            wp_awarded,
            proof_url,
            status
        )
        values (
            v_uid,
            p_task_id,
            0,
            v_proof,
            'pending'
        );

    end if;


    -- --------------------------------------------------------
    -- 14. IMPORTANT:
    --
    -- NO WP UPDATE HERE.
    --
    -- WP will only be awarded by approve_task_claim().
    -- --------------------------------------------------------


    return jsonb_build_object(
        'ok', true,
        'task_id', p_task_id,
        'status', 'pending',
        'proof_submitted', true,
        'message', 'Proof submitted for manual review.'
    );


end;
$$;


-- ============================================================
-- 11. ALLOW LOGGED-IN USERS TO SUBMIT
-- ============================================================


grant execute
on function public.submit_task_for_review(text, text)
to authenticated;


-- ============================================================
-- 12. TASK BOARD
-- ============================================================
--
-- Returns:
--
--   tasks
--   task_claims
--
-- Including:
--
--   status
--   proof_url
--   wp_awarded
--   claimed_at
--   reviewed_at
--
-- ============================================================


create or replace function public.get_task_board()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$

declare
    v_uid uuid;

begin

    -- --------------------------------------------------------
    -- Identify user
    -- --------------------------------------------------------

    v_uid := auth.uid();


    if v_uid is null then

        return jsonb_build_object(
            'ok', false,
            'error', 'NOT_AUTHENTICATED'
        );

    end if;


    -- --------------------------------------------------------
    -- Return task board
    -- --------------------------------------------------------

    return jsonb_build_object(

        'ok',
        true,


        -- ----------------------------------------------------
        -- ACTIVE TASKS
        -- ----------------------------------------------------

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


        -- ----------------------------------------------------
        -- USER CLAIMS
        -- ----------------------------------------------------

        'task_claims',

        (
            select coalesce(
                jsonb_agg(
                    jsonb_build_object(
                        'task_id', c.task_id,
                        'wp_awarded', c.wp_awarded,
                        'proof_url', c.proof_url,
                        'status', c.status,
                        'claimed_at', c.claimed_at,
                        'reviewed_at', c.reviewed_at
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


-- ============================================================
-- 13. ALLOW LOGGED-IN USERS TO LOAD TASK BOARD
-- ============================================================


grant execute
on function public.get_task_board()
to authenticated;


-- ============================================================
-- 14. ADMIN APPROVAL FUNCTION
-- ============================================================
--
-- IMPORTANT:
--
-- This function is intentionally NOT granted to normal
-- authenticated users.
--
-- Run it manually from Supabase SQL Editor.
--
-- When approved:
--
--   1. Task must be pending
--   2. WP reward comes from the task
--   3. User's WP is increased
--   4. Claim becomes approved
--   5. WP cannot be awarded twice
--
-- ============================================================


create or replace function public.approve_task_claim(
    p_user_id uuid,
    p_task_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$

declare
    v_claim       public.task_claims%rowtype;
    v_task        public.tasks%rowtype;
    v_reward      integer;

begin

    -- --------------------------------------------------------
    -- Find claim
    -- --------------------------------------------------------

    select *
    into v_claim
    from public.task_claims
    where user_id = p_user_id
      and task_id = p_task_id
    for update;


    if not found then

        return jsonb_build_object(
            'ok', false,
            'error', 'CLAIM_NOT_FOUND'
        );

    end if;


    -- --------------------------------------------------------
    -- Prevent double approval
    -- --------------------------------------------------------

    if v_claim.status = 'approved' then

        return jsonb_build_object(
            'ok', false,
            'error', 'ALREADY_APPROVED'
        );

    end if;


    -- --------------------------------------------------------
    -- Only pending claims can be approved
    -- --------------------------------------------------------

    if v_claim.status <> 'pending' then

        return jsonb_build_object(
            'ok', false,
            'error', 'CLAIM_NOT_PENDING',
            'status', v_claim.status
        );

    end if;


    -- --------------------------------------------------------
    -- Find task
    -- --------------------------------------------------------

    select *
    into v_task
    from public.tasks
    where id = p_task_id;


    if not found then

        return jsonb_build_object(
            'ok', false,
            'error', 'TASK_NOT_FOUND'
        );

    end if;


    v_reward := v_task.wp_reward;


    -- --------------------------------------------------------
    -- Award WP
    -- --------------------------------------------------------

    update public.profiles
    set wp = coalesce(wp, 0) + v_reward
    where id = p_user_id;


    if not found then

        return jsonb_build_object(
            'ok', false,
            'error', 'PROFILE_NOT_FOUND'
        );

    end if;


    -- --------------------------------------------------------
    -- Mark approved
    -- --------------------------------------------------------

    update public.task_claims
    set
        status      = 'approved',
        wp_awarded  = v_reward,
        reviewed_at = now(),
        reviewed_by = auth.uid()

    where user_id = p_user_id
      and task_id = p_task_id;


    -- --------------------------------------------------------
    -- Return result
    -- --------------------------------------------------------

    return jsonb_build_object(
        'ok', true,
        'user_id', p_user_id,
        'task_id', p_task_id,
        'status', 'approved',
        'wp_awarded', v_reward
    );

end;
$$;


-- ============================================================
-- IMPORTANT:
--
-- DO NOT GRANT approve_task_claim() TO authenticated.
--
-- It remains restricted to the database owner / privileged
-- SQL execution.
--
-- ============================================================


-- ============================================================
-- 15. ADMIN REJECTION FUNCTION
-- ============================================================
--
-- Rejecting does NOT remove or deduct WP because no WP has
-- been awarded while the claim is pending.
--
-- A rejected user can submit again.
--
-- ============================================================


create or replace function public.reject_task_claim(
    p_user_id uuid,
    p_task_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$

declare
    v_claim public.task_claims%rowtype;

begin

    -- --------------------------------------------------------
    -- Find claim
    -- --------------------------------------------------------

    select *
    into v_claim
    from public.task_claims
    where user_id = p_user_id
      and task_id = p_task_id
    for update;


    if not found then

        return jsonb_build_object(
            'ok', false,
            'error', 'CLAIM_NOT_FOUND'
        );

    end if;


    -- --------------------------------------------------------
    -- Prevent rejecting an approved claim
    -- --------------------------------------------------------

    if v_claim.status = 'approved' then

        return jsonb_build_object(
            'ok', false,
            'error', 'ALREADY_APPROVED'
        );

    end if;


    -- --------------------------------------------------------
    -- Only pending claims can be rejected
    -- --------------------------------------------------------

    if v_claim.status <> 'pending' then

        return jsonb_build_object(
            'ok', false,
            'error', 'CLAIM_NOT_PENDING',
            'status', v_claim.status
        );

    end if;


    -- --------------------------------------------------------
    -- Mark rejected
    -- --------------------------------------------------------

    update public.task_claims
    set
        status      = 'rejected',
        wp_awarded  = 0,
        reviewed_at = now(),
        reviewed_by = auth.uid()

    where user_id = p_user_id
      and task_id = p_task_id;


    return jsonb_build_object(
        'ok', true,
        'user_id', p_user_id,
        'task_id', p_task_id,
        'status', 'rejected'
    );

end;
$$;


-- ============================================================
-- 16. REMOVE PUBLIC EXECUTION PERMISSIONS FROM ADMIN FUNCTIONS
-- ============================================================


revoke all
on function public.approve_task_claim(uuid, text)
from public;

revoke all
on function public.approve_task_claim(uuid, text)
from anon;

revoke all
on function public.approve_task_claim(uuid, text)
from authenticated;


revoke all
on function public.reject_task_claim(uuid, text)
from public;

revoke all
on function public.reject_task_claim(uuid, text)
from anon;

revoke all
on function public.reject_task_claim(uuid, text)
from authenticated;


-- ============================================================
-- 17. ADMIN REVIEW QUERY
-- ============================================================
--
-- Run this AFTER the migration to see pending submissions.
--
-- ============================================================


-- SELECT
--     tc.claimed_at,
--     tc.status,
--     tc.user_id,
--     p.username,
--     p.google_name,
--     t.id AS task_id,
--     t.label,
--     t.wp_reward,
--     tc.proof_url,
--     tc.wp_awarded,
--     tc.reviewed_at
--
-- FROM public.task_claims tc
--
-- JOIN public.tasks t
--     ON t.id = tc.task_id
--
-- LEFT JOIN public.profiles p
--     ON p.id = tc.user_id
--
-- WHERE tc.status = 'pending'
--
-- ORDER BY tc.claimed_at ASC;


-- ============================================================
-- 18. VIEW ALL CLAIMS
-- ============================================================
--
-- Useful for checking the complete history.
--
-- ============================================================


-- SELECT
--     tc.claimed_at,
--     tc.status,
--     tc.user_id,
--     p.username,
--     p.google_name,
--     t.id AS task_id,
--     t.label,
--     tc.proof_url,
--     tc.wp_awarded,
--     tc.reviewed_at
--
-- FROM public.task_claims tc
--
-- JOIN public.tasks t
--     ON t.id = tc.task_id
--
-- LEFT JOIN public.profiles p
--     ON p.id = tc.user_id
--
-- ORDER BY tc.claimed_at DESC;


-- ============================================================
-- 19. VERIFY TASKS
-- ============================================================


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


-- ============================================================
-- 20. VERIFY TASK CLAIM TABLE
-- ============================================================


select
    column_name,
    data_type,
    is_nullable,
    column_default
from information_schema.columns
where table_schema = 'public'
and table_name = 'task_claims'
order by ordinal_position;


-- ============================================================
-- 21. VERIFY FUNCTIONS
-- ============================================================


select
    routine_name,
    routine_type
from information_schema.routines
where routine_schema = 'public'
and routine_name in (
    'submit_task_for_review',
    'get_task_board',
    'approve_task_claim',
    'reject_task_claim',
    'claim_task'
)
order by routine_name;


-- ============================================================
-- FINISH
-- ============================================================


commit;
