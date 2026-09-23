-- =========================================================
-- THE GREEN WARDEN — VERIFIED SOCIAL TASK SYSTEM
-- =========================================================
-- Flow:
--   1. User opens X
--   2. User performs the task
--   3. User submits proof URL
--   4. Claim becomes PENDING
--   5. Admin manually reviews
--   6. Admin approves/rejects
--   7. WP is awarded ONLY on approval
--
-- IMPORTANT:
-- Opening the X link never grants WP.
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


alter table public.tasks enable row level security;


drop policy if exists "tasks_read"
on public.tasks;


create policy "tasks_read"
on public.tasks
for select
to authenticated
using (true);


-- =========================================================
-- 2. TASKS
-- =========================================================
-- Task 1:
-- Like + Reply gives the user a public URL that can be
-- manually checked.
--
-- Task 2:
-- Share/Quote post and submit the resulting X URL.
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
    'Like + Reply to the Green Warden post',
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

    wp_awarded    integer not null default 0,

    proof_url     text,

    status        text not null default 'pending'
        check (status in ('pending', 'approved', 'rejected')),

    claimed_at    timestamptz not null default now(),

    reviewed_at   timestamptz,

    reviewed_by   uuid,

    primary key (user_id, task_id)
);


-- Add new columns if task_claims already existed
alter table public.task_claims
add column if not exists status text;

alter table public.task_claims
add column if not exists reviewed_at timestamptz;

alter table public.task_claims
add column if not exists reviewed_by uuid;


-- Existing claims were already awarded by the old system.
-- Treat them as approved so their WP remains valid.

update public.task_claims
set
    status = 'approved',
    wp_awarded = coalesce(wp_awarded, 0)
where status is null;


alter table public.task_claims
alter column status set default 'pending';


-- =========================================================
-- 4. RLS
-- =========================================================

alter table public.task_claims enable row level security;


drop policy if exists "task_claims_read_own"
on public.task_claims;


create policy "task_claims_read_own"
on public.task_claims
for select
to authenticated
using (
    user_id = auth.uid()
);


-- No INSERT policy.
-- No UPDATE policy.
--
-- Users MUST use the RPC functions below.


-- =========================================================
-- 5. SUBMIT TASK FOR REVIEW
-- =========================================================

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
    v_uid uuid;
    v_task public.tasks%rowtype;
    v_proof text;
    v_existing public.task_claims%rowtype;

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
    -- Verify profile
    -- -----------------------------------------------------

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


    if not v_task.active then

        return jsonb_build_object(
            'ok', false,
            'error', 'TASK_INACTIVE'
        );

    end if;


    -- -----------------------------------------------------
    -- Clean proof
    -- -----------------------------------------------------

    v_proof := nullif(
        trim(coalesce(p_proof_url, '')),
        ''
    );


    -- -----------------------------------------------------
    -- Proof is mandatory
    -- -----------------------------------------------------

    if v_task.needs_proof = true
       and v_proof is null then

        return jsonb_build_object(
            'ok', false,
            'error', 'PROOF_REQUIRED'
        );

    end if;


    -- -----------------------------------------------------
    -- Validate URL
    -- -----------------------------------------------------

    if v_proof !~* '^https?://' then

        return jsonb_build_object(
            'ok', false,
            'error', 'INVALID_PROOF_URL'
        );

    end if;


    -- -----------------------------------------------------
    -- X/Twitter only
    -- -----------------------------------------------------

    if v_proof !~* '^https?://(www\.)?(x\.com|twitter\.com)/' then

        return jsonb_build_object(
            'ok', false,
            'error', 'INVALID_X_PROOF_URL'
        );

    end if;


    -- -----------------------------------------------------
    -- Check previous claim
    -- -----------------------------------------------------

    select *
    into v_existing
    from public.task_claims
    where user_id = v_uid
      and task_id = p_task_id;


    if found then

        if v_existing.status = 'pending' then

            return jsonb_build_object(
                'ok', false,
                'error', 'ALREADY_PENDING'
            );

        end if;


        if v_existing.status = 'approved' then

            return jsonb_build_object(
                'ok', false,
                'error', 'ALREADY_APPROVED'
            );

        end if;


        -- Rejected claim can be resubmitted.
        update public.task_claims
        set
            proof_url = v_proof,
            status = 'pending',
            wp_awarded = 0,
            claimed_at = now(),
            reviewed_at = null,
            reviewed_by = null
        where user_id = v_uid
          and task_id = p_task_id;

    else

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


    return jsonb_build_object(
        'ok', true,
        'status', 'pending',
        'task_id', p_task_id,
        'message', 'Proof submitted for manual review.'
    );


exception
    when unique_violation then

        return jsonb_build_object(
            'ok', false,
            'error', 'ALREADY_PENDING'
        );

end;
$$;


grant execute
on function public.submit_task_for_review(text, text)
to authenticated;


-- =========================================================
-- 6. TASK BOARD
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

        'ok',
        true,


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


grant execute
on function public.get_task_board()
to authenticated;


-- =========================================================
-- 7. ADMIN APPROVE
-- =========================================================
--
-- IMPORTANT:
-- Only run this manually from Supabase SQL Editor
-- after you personally verify the proof.
--
-- Replace USER_UUID and TASK_ID.
-- =========================================================

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
    v_claim public.task_claims%rowtype;
    v_reward integer;

begin

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


    if v_claim.status = 'approved' then

        return jsonb_build_object(
            'ok', false,
            'error', 'ALREADY_APPROVED'
        );

    end if;


    if v_claim.status <> 'pending' then

        return jsonb_build_object(
            'ok', false,
            'error', 'CLAIM_NOT_PENDING'
        );

    end if;


    select wp_reward
    into v_reward
    from public.tasks
    where id = p_task_id;


    if v_reward is null then

        return jsonb_build_object(
            'ok', false,
            'error', 'TASK_NOT_FOUND'
        );

    end if;


    -- Award WP ONLY NOW
    update public.profiles
    set wp = coalesce(wp, 0) + v_reward
    where id = p_user_id;


    update public.task_claims
    set
        status = 'approved',
        wp_awarded = v_reward,
        reviewed_at = now(),
        reviewed_by = auth.uid()
    where user_id = p_user_id
      and task_id = p_task_id;


    return jsonb_build_object(
        'ok', true,
        'status', 'approved',
        'wp_awarded', v_reward
    );

end;
$$;


-- DO NOT grant this to authenticated users.
-- This function is intended for administrator use only.


-- =========================================================
-- 8. ADMIN REJECT
-- =========================================================

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


    if v_claim.status <> 'pending' then

        return jsonb_build_object(
            'ok', false,
            'error', 'CLAIM_NOT_PENDING'
        );

    end if;


    update public.task_claims
    set
        status = 'rejected',
        wp_awarded = 0,
        reviewed_at = now(),
        reviewed_by = auth.uid()
    where user_id = p_user_id
      and task_id = p_task_id;


    return jsonb_build_object(
        'ok', true,
        'status', 'rejected'
    );

end;
$$;


-- DO NOT grant this to authenticated users.


-- =========================================================
-- 9. ADMIN REVIEW QUERY
-- =========================================================

select
    tc.claimed_at,
    tc.status,
    tc.user_id,
    p.username,
    p.google_name,
    t.id as task_id,
    t.label,
    t.wp_reward,
    tc.wp_awarded,
    tc.proof_url,
    tc.reviewed_at,
    tc.reviewed_by
from public.task_claims tc
join public.tasks t
    on t.id = tc.task_id
left join public.profiles p
    on p.id = tc.user_id
order by tc.claimed_at desc;
