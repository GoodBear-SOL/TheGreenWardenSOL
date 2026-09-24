/* ============================================================
   THE GREEN WARDEN
   SUPABASE MASTER SETUP / REPAIR SCRIPT
   Dashboard-compatible backend
   ============================================================

   IMPORTANT:
   - Successful referral reward = +200 WP to REFERRER.
   - Attaching a referral does NOT pay the reward.
   - Qualification pays the +200 WP exactly once.
   - task_claims uses claimed_at, NOT created_at.
   - task_claims does NOT require an id column.
   - Dashboard RPC response shapes are matched to dashboard.html.
   ============================================================ */


BEGIN;


/* ============================================================
   1. EXTENSIONS
   ============================================================ */

CREATE EXTENSION IF NOT EXISTS pgcrypto;


/* ============================================================
   2. TABLES
   Existing tables are preserved.
   Missing columns are added only where safe/required.
   ============================================================ */


/* -------------------- profiles -------------------- */

CREATE TABLE IF NOT EXISTS public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  google_name text,
  avatar_url text,
  username text,
  x_username text,
  wp integer NOT NULL DEFAULT 0,
  streak integer NOT NULL DEFAULT 0,
  best_streak integer NOT NULL DEFAULT 0,
  last_checkin date,
  created_at timestamptz NOT NULL DEFAULT now(),
  wallet_address text,
  x_bonus_claimed boolean NOT NULL DEFAULT false,
  wallet_bonus_claimed boolean NOT NULL DEFAULT false,
  is_admin boolean NOT NULL DEFAULT false
);

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS google_name text;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS avatar_url text;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS username text;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS x_username text;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS wp integer NOT NULL DEFAULT 0;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS streak integer NOT NULL DEFAULT 0;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS best_streak integer NOT NULL DEFAULT 0;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS last_checkin date;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS wallet_address text;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS x_bonus_claimed boolean NOT NULL DEFAULT false;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS wallet_bonus_claimed boolean NOT NULL DEFAULT false;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_admin boolean NOT NULL DEFAULT false;


/* -------------------- checkins -------------------- */

CREATE TABLE IF NOT EXISTS public.checkins (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  day date NOT NULL,
  day_in_cycle integer NOT NULL,
  wp_awarded integer NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.checkins
  ADD COLUMN IF NOT EXISTS day_in_cycle integer NOT NULL DEFAULT 1;

ALTER TABLE public.checkins
  ADD COLUMN IF NOT EXISTS wp_awarded integer NOT NULL DEFAULT 0;

ALTER TABLE public.checkins
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();


/* -------------------- tasks -------------------- */

CREATE TABLE IF NOT EXISTS public.tasks (
  id text PRIMARY KEY,
  label text NOT NULL,
  url text NOT NULL,
  wp_reward integer NOT NULL,
  needs_proof boolean NOT NULL DEFAULT false,
  active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.tasks
  ADD COLUMN IF NOT EXISTS label text;

ALTER TABLE public.tasks
  ADD COLUMN IF NOT EXISTS url text;

ALTER TABLE public.tasks
  ADD COLUMN IF NOT EXISTS wp_reward integer NOT NULL DEFAULT 0;

ALTER TABLE public.tasks
  ADD COLUMN IF NOT EXISTS needs_proof boolean NOT NULL DEFAULT false;

ALTER TABLE public.tasks
  ADD COLUMN IF NOT EXISTS active boolean NOT NULL DEFAULT true;

ALTER TABLE public.tasks
  ADD COLUMN IF NOT EXISTS sort_order integer NOT NULL DEFAULT 0;

ALTER TABLE public.tasks
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();


/* -------------------- task_claims -------------------- */

CREATE TABLE IF NOT EXISTS public.task_claims (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  task_id text NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
  wp_awarded integer NOT NULL DEFAULT 0,
  proof_url text,
  claimed_at timestamptz NOT NULL DEFAULT now(),
  status text DEFAULT 'pending',
  reviewed_at timestamptz,
  reviewed_by uuid
);

ALTER TABLE public.task_claims
  ADD COLUMN IF NOT EXISTS wp_awarded integer NOT NULL DEFAULT 0;

ALTER TABLE public.task_claims
  ADD COLUMN IF NOT EXISTS proof_url text;

ALTER TABLE public.task_claims
  ADD COLUMN IF NOT EXISTS claimed_at timestamptz NOT NULL DEFAULT now();

ALTER TABLE public.task_claims
  ADD COLUMN IF NOT EXISTS status text DEFAULT 'pending';

ALTER TABLE public.task_claims
  ADD COLUMN IF NOT EXISTS reviewed_at timestamptz;

ALTER TABLE public.task_claims
  ADD COLUMN IF NOT EXISTS reviewed_by uuid;


/* -------------------- referral_codes -------------------- */

CREATE TABLE IF NOT EXISTS public.referral_codes (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  referral_code text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.referral_codes
  ADD COLUMN IF NOT EXISTS referral_code text;

ALTER TABLE public.referral_codes
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();


/* -------------------- referrals -------------------- */

CREATE TABLE IF NOT EXISTS public.referrals (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  referrer_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  referred_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  referral_code text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  initial_reward integer NOT NULL DEFAULT 300,
  initial_rewarded_at timestamptz,
  active_reward integer NOT NULL DEFAULT 200,
  active_rewarded_at timestamptz,
  qualified_at timestamptz
);

ALTER TABLE public.referrals
  ADD COLUMN IF NOT EXISTS referral_code text;

ALTER TABLE public.referrals
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();

ALTER TABLE public.referrals
  ADD COLUMN IF NOT EXISTS initial_reward integer NOT NULL DEFAULT 300;

ALTER TABLE public.referrals
  ADD COLUMN IF NOT EXISTS initial_rewarded_at timestamptz;

ALTER TABLE public.referrals
  ADD COLUMN IF NOT EXISTS active_reward integer NOT NULL DEFAULT 200;

ALTER TABLE public.referrals
  ADD COLUMN IF NOT EXISTS active_rewarded_at timestamptz;

ALTER TABLE public.referrals
  ADD COLUMN IF NOT EXISTS qualified_at timestamptz;


/* -------------------- referral_rewards -------------------- */

CREATE TABLE IF NOT EXISTS public.referral_rewards (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  referral_id bigint NOT NULL REFERENCES public.referrals(id) ON DELETE CASCADE,
  referrer_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  reward_type text NOT NULL,
  wp_awarded integer NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.referral_rewards
  ADD COLUMN IF NOT EXISTS referral_id bigint;

ALTER TABLE public.referral_rewards
  ADD COLUMN IF NOT EXISTS referrer_id uuid;

ALTER TABLE public.referral_rewards
  ADD COLUMN IF NOT EXISTS reward_type text;

ALTER TABLE public.referral_rewards
  ADD COLUMN IF NOT EXISTS wp_awarded integer NOT NULL DEFAULT 0;

ALTER TABLE public.referral_rewards
  ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();


/* ============================================================
   3. INDEXES
   ============================================================ */

CREATE UNIQUE INDEX IF NOT EXISTS referral_codes_code_unique
ON public.referral_codes(referral_code);

CREATE UNIQUE INDEX IF NOT EXISTS referrals_referred_unique
ON public.referrals(referred_id);

CREATE INDEX IF NOT EXISTS referrals_referrer_idx
ON public.referrals(referrer_id);

CREATE INDEX IF NOT EXISTS referral_rewards_referrer_idx
ON public.referral_rewards(referrer_id);

CREATE INDEX IF NOT EXISTS referral_rewards_referral_idx
ON public.referral_rewards(referral_id);

CREATE INDEX IF NOT EXISTS checkins_user_day_idx
ON public.checkins(user_id, day);

CREATE INDEX IF NOT EXISTS task_claims_user_task_idx
ON public.task_claims(user_id, task_id);

CREATE INDEX IF NOT EXISTS task_claims_status_idx
ON public.task_claims(status);


/*
   Protect against duplicate reward rows.

   If an identical reward already exists, this index prevents
   another +200 active referral reward from being inserted.
*/
CREATE UNIQUE INDEX IF NOT EXISTS referral_rewards_active_unique
ON public.referral_rewards(referral_id, reward_type)
WHERE reward_type = 'active_referral';


/* ============================================================
   4. HELPER FUNCTIONS
   ============================================================ */


/* -------------------- Manila date -------------------- */

CREATE OR REPLACE FUNCTION public.manila_today()
RETURNS date
LANGUAGE sql
STABLE
AS $$
  SELECT (now() AT TIME ZONE 'Asia/Manila')::date;
$$;


/* -------------------- Seconds until next Manila day -------------------- */

CREATE OR REPLACE FUNCTION public.manila_seconds_to_reset()
RETURNS integer
LANGUAGE sql
STABLE
AS $$
  SELECT GREATEST(
    0,
    EXTRACT(
      EPOCH FROM (
        (
          (
            (now() AT TIME ZONE 'Asia/Manila')::date
            + 1
          )::timestamp
          AT TIME ZONE 'Asia/Manila'
        )
        - now()
      )
    )::integer
  );
$$;


/* -------------------- Effective streak -------------------- */

CREATE OR REPLACE FUNCTION public.effective_streak(
  p_last date,
  p_streak integer
)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT
    CASE
      WHEN p_last IS NULL THEN 0
      WHEN p_last = public.manila_today() THEN COALESCE(p_streak,0)
      WHEN p_last = public.manila_today() - 1 THEN COALESCE(p_streak,0)
      ELSE 0
    END;
$$;


/* -------------------- WP reward ladder -------------------- */

CREATE OR REPLACE FUNCTION public.wp_for_day(
  p_day integer
)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_day = 1 THEN 5
    WHEN p_day = 2 THEN 10
    WHEN p_day = 3 THEN 15
    WHEN p_day = 4 THEN 20
    WHEN p_day = 5 THEN 25
    WHEN p_day = 6 THEN 30
    WHEN p_day = 7 THEN 50
    ELSE 5
  END;
$$;


/* -------------------- Profile creation -------------------- */

CREATE OR REPLACE FUNCTION public.ensure_profile()
RETURNS public.profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid;
  v_profile public.profiles;
BEGIN
  v_user := auth.uid();

  IF v_user IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED';
  END IF;

  INSERT INTO public.profiles (
    id,
    google_name,
    avatar_url
  )
  SELECT
    u.id,
    COALESCE(
      u.raw_user_meta_data->>'full_name',
      u.raw_user_meta_data->>'name'
    ),
    COALESCE(
      u.raw_user_meta_data->>'avatar_url',
      u.raw_user_meta_data->>'picture'
    )
  FROM auth.users u
  WHERE u.id = v_user
  ON CONFLICT (id) DO NOTHING;

  SELECT *
  INTO v_profile
  FROM public.profiles
  WHERE id = v_user;

  RETURN v_profile;
END;
$$;


/* ============================================================
   5. CHECK-IN SYSTEM
   ============================================================ */


/* -------------------- Get dashboard status -------------------- */

CREATE OR REPLACE FUNCTION public.get_my_status()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid;
  v_profile public.profiles;
  v_today date;
  v_claimed boolean;
  v_rank integer;
  v_effective_streak integer;
BEGIN
  v_user := auth.uid();

  IF v_user IS NULL THEN
    RETURN json_build_object(
      'ok', false,
      'error', 'NOT_AUTHENTICATED'
    );
  END IF;

  v_profile := public.ensure_profile();

  v_today := public.manila_today();

  SELECT EXISTS (
    SELECT 1
    FROM public.checkins c
    WHERE c.user_id = v_user
      AND c.day = v_today
  )
  INTO v_claimed;

  v_effective_streak :=
    public.effective_streak(
      v_profile.last_checkin,
      v_profile.streak
    );

  SELECT
    1 + COUNT(*)
  INTO v_rank
  FROM public.profiles p
  WHERE p.wp > v_profile.wp;

  RETURN json_build_object(
    'ok', true,
    'id', v_profile.id,
    'google_name', v_profile.google_name,
    'avatar_url', v_profile.avatar_url,
    'username', v_profile.username,
    'x_username', v_profile.x_username,
    'wallet_address', v_profile.wallet_address,
    'wp', v_profile.wp,
    'streak', v_effective_streak,
    'best_streak', v_profile.best_streak,
    'last_checkin', v_profile.last_checkin,
    'claimed_today', v_claimed,
    'rank', v_rank,
    'seconds_to_reset', public.manila_seconds_to_reset(),
    'is_admin', COALESCE(v_profile.is_admin,false)
  );
END;
$$;


/* -------------------- Claim daily check-in -------------------- */

CREATE OR REPLACE FUNCTION public.claim_checkin()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid;
  v_profile public.profiles;
  v_today date;
  v_streak integer;
  v_day integer;
  v_reward integer;
  v_inserted integer;
BEGIN
  v_user := auth.uid();

  IF v_user IS NULL THEN
    RETURN json_build_object(
      'ok', false,
      'error', 'NOT_AUTHENTICATED'
    );
  END IF;

  v_profile := public.ensure_profile();

  v_today := public.manila_today();

  /*
    One check-in per user per Manila day.
    This query is intentionally locked by checking the unique
    logical key through the unique index below.
  */
  IF EXISTS (
    SELECT 1
    FROM public.checkins
    WHERE user_id = v_user
      AND day = v_today
  ) THEN
    RETURN json_build_object(
      'ok', false,
      'error', 'ALREADY_CLAIMED',
      'claimed_today', true
    );
  END IF;

  IF v_profile.last_checkin = v_today - 1 THEN
    v_streak := COALESCE(v_profile.streak,0) + 1;
  ELSE
    v_streak := 1;
  END IF;

  v_day := ((v_streak - 1) % 7) + 1;

  v_reward := public.wp_for_day(v_day);

  INSERT INTO public.checkins (
    user_id,
    day,
    day_in_cycle,
    wp_awarded
  )
  VALUES (
    v_user,
    v_today,
    v_day,
    v_reward
  );

  UPDATE public.profiles
  SET
    wp = COALESCE(wp,0) + v_reward,
    streak = v_streak,
    best_streak = GREATEST(
      COALESCE(best_streak,0),
      v_streak
    ),
    last_checkin = v_today
  WHERE id = v_user;

  RETURN json_build_object(
    'ok', true,
    'wp_awarded', v_reward,
    'day', v_day,
    'streak', v_streak
  );
END;
$$;


/* ============================================================
   6. PORTAL ACTIVITY
   ============================================================ */

CREATE OR REPLACE FUNCTION public.record_portal_activity()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid;
BEGIN
  v_user := auth.uid();

  IF v_user IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'NOT_AUTHENTICATED'
    );
  END IF;

  PERFORM public.ensure_profile();

  RETURN jsonb_build_object(
    'ok', true
  );
END;
$$;


/* ============================================================
   7. TASK BOARD
   ============================================================ */

CREATE OR REPLACE FUNCTION public.get_task_board()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid;
  v_tasks jsonb;
  v_claims jsonb;
BEGIN
  v_user := auth.uid();

  IF v_user IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'NOT_AUTHENTICATED'
    );
  END IF;

  PERFORM public.ensure_profile();

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', t.id,
        'label', t.label,
        'url', t.url,
        'wp_reward', t.wp_reward,
        'needs_proof', t.needs_proof,
        'active', t.active,
        'sort_order', t.sort_order
      )
      ORDER BY t.sort_order, t.created_at
    ),
    '[]'::jsonb
  )
  INTO v_tasks
  FROM public.tasks t
  WHERE t.active = true;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'user_id', tc.user_id,
        'task_id', tc.task_id,
        'proof_url', tc.proof_url,
        'wp_awarded', tc.wp_awarded,
        'status', tc.status,
        'claimed_at', tc.claimed_at,
        'reviewed_at', tc.reviewed_at,
        'reviewed_by', tc.reviewed_by
      )
      ORDER BY tc.claimed_at DESC
    ),
    '[]'::jsonb
  )
  INTO v_claims
  FROM public.task_claims tc
  WHERE tc.user_id = v_user;

  RETURN jsonb_build_object(
    'ok', true,
    'tasks', v_tasks,
    'task_claims', v_claims
  );
END;
$$;


/* ============================================================
   8. TASK PROOF SUBMISSION
   ============================================================ */

CREATE OR REPLACE FUNCTION public.submit_task_for_review(
  p_task_id text,
  p_proof_url text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid;
  v_task public.tasks;
  v_existing public.task_claims;
  v_url text;
BEGIN
  v_user := auth.uid();

  IF v_user IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'NOT_AUTHENTICATED'
    );
  END IF;

  PERFORM public.ensure_profile();

  v_url := btrim(COALESCE(p_proof_url,''));

  IF v_url = '' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'PROOF_REQUIRED'
    );
  END IF;

  IF v_url !~* '^https?://(www\.)?(x\.com|twitter\.com)/.+'
  THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'INVALID_X_PROOF_URL'
    );
  END IF;

  SELECT *
  INTO v_task
  FROM public.tasks
  WHERE id = p_task_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'UNKNOWN_TASK'
    );
  END IF;

  IF NOT v_task.active THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'TASK_INACTIVE'
    );
  END IF;

  SELECT *
  INTO v_existing
  FROM public.task_claims
  WHERE user_id = v_user
    AND task_id = p_task_id;

  IF FOUND THEN

    IF v_existing.status = 'approved' THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', 'ALREADY_APPROVED'
      );
    END IF;

    IF v_existing.status = 'pending' THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', 'ALREADY_PENDING'
      );
    END IF;

    UPDATE public.task_claims
    SET
      proof_url = v_url,
      status = 'pending',
      claimed_at = now(),
      reviewed_at = NULL,
      reviewed_by = NULL
    WHERE user_id = v_user
      AND task_id = p_task_id;

  ELSE

    INSERT INTO public.task_claims (
      user_id,
      task_id,
      wp_awarded,
      proof_url,
      claimed_at,
      status
    )
    VALUES (
      v_user,
      p_task_id,
      0,
      v_url,
      now(),
      'pending'
    );

  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'pending',
    'task_id', p_task_id
  );
END;
$$;


/* ============================================================
   9. ADMIN CHECK
   ============================================================ */

CREATE OR REPLACE FUNCTION public.is_current_user_admin()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (
      SELECT is_admin
      FROM public.profiles
      WHERE id = auth.uid()
    ),
    false
  );
$$;


/* ============================================================
   10. ADMIN TASK REVIEWS
   ============================================================ */

CREATE OR REPLACE FUNCTION public.get_admin_task_reviews()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_claims jsonb;
BEGIN
  IF NOT public.is_current_user_admin() THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'ADMIN_REQUIRED'
    );
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'user_id', tc.user_id,
        'task_id', tc.task_id,
        'proof_url', tc.proof_url,
        'wp_awarded', tc.wp_awarded,
        'status', tc.status,
        'claimed_at', tc.claimed_at,
        'reviewed_at', tc.reviewed_at,
        'reviewed_by', tc.reviewed_by,
        'username', p.username,
        'google_name', p.google_name,
        'x_username', p.x_username,
        'avatar_url', p.avatar_url,
        'task_label', t.label,
        'task_url', t.url,
        'task_reward', t.wp_reward
      )
      ORDER BY tc.claimed_at ASC
    ),
    '[]'::jsonb
  )
  INTO v_claims
  FROM public.task_claims tc
  JOIN public.profiles p
    ON p.id = tc.user_id
  JOIN public.tasks t
    ON t.id = tc.task_id
  WHERE tc.status = 'pending';

  RETURN jsonb_build_object(
    'ok', true,
    'claims', v_claims
  );
END;
$$;


/* ============================================================
   11. ADMIN APPROVE TASK CLAIM
   ============================================================ */

CREATE OR REPLACE FUNCTION public.approve_task_claim(
  p_user_id uuid,
  p_task_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_claim public.task_claims;
  v_task public.tasks;
  v_admin uuid;
BEGIN
  v_admin := auth.uid();

  IF NOT public.is_current_user_admin() THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'ADMIN_REQUIRED'
    );
  END IF;

  SELECT *
  INTO v_claim
  FROM public.task_claims
  WHERE user_id = p_user_id
    AND task_id = p_task_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'CLAIM_NOT_FOUND'
    );
  END IF;

  IF v_claim.status = 'approved' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'ALREADY_APPROVED'
    );
  END IF;

  SELECT *
  INTO v_task
  FROM public.tasks
  WHERE id = p_task_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'UNKNOWN_TASK'
    );
  END IF;

  UPDATE public.task_claims
  SET
    status = 'approved',
    wp_awarded = v_task.wp_reward,
    reviewed_at = now(),
    reviewed_by = v_admin
  WHERE user_id = p_user_id
    AND task_id = p_task_id;

  UPDATE public.profiles
  SET wp = COALESCE(wp,0) + v_task.wp_reward
  WHERE id = p_user_id;

  RETURN jsonb_build_object(
    'ok', true,
    'wp_awarded', v_task.wp_reward,
    'task_id', p_task_id,
    'user_id', p_user_id
  );
END;
$$;


/* ============================================================
   12. ADMIN REJECT TASK CLAIM
   ============================================================ */

CREATE OR REPLACE FUNCTION public.reject_task_claim(
  p_user_id uuid,
  p_task_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin uuid;
BEGIN
  v_admin := auth.uid();

  IF NOT public.is_current_user_admin() THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'ADMIN_REQUIRED'
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.task_claims
    WHERE user_id = p_user_id
      AND task_id = p_task_id
  ) THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'CLAIM_NOT_FOUND'
    );
  END IF;

  UPDATE public.task_claims
  SET
    status = 'rejected',
    reviewed_at = now(),
    reviewed_by = v_admin,
    wp_awarded = 0
  WHERE user_id = p_user_id
    AND task_id = p_task_id;

  RETURN jsonb_build_object(
    'ok', true,
    'status', 'rejected'
  );
END;
$$;


/* ============================================================
   13. LEADERBOARD
   ============================================================ */

CREATE OR REPLACE FUNCTION public.get_leaderboard(
  p_limit integer
)
RETURNS TABLE(
  pos bigint,
  display text,
  avatar text,
  x_handle text,
  points integer,
  day_streak integer,
  me boolean
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    ROW_NUMBER() OVER (
      ORDER BY p.wp DESC, p.streak DESC, p.created_at ASC
    ) AS pos,
    COALESCE(
      p.username,
      p.google_name,
      'Warden'
    ) AS display,
    p.avatar_url AS avatar,
    p.x_username AS x_handle,
    COALESCE(p.wp,0) AS points,
    public.effective_streak(
      p.last_checkin,
      p.streak
    ) AS day_streak,
    p.id = auth.uid() AS me
  FROM public.profiles p
  WHERE p.wp > 0
  ORDER BY p.wp DESC, p.streak DESC, p.created_at ASC
  LIMIT GREATEST(COALESCE(p_limit,50),1);
$$;


/* -------------------- Admin leaderboard -------------------- */

CREATE OR REPLACE FUNCTION public.get_admin_leaderboard()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profiles jsonb;
BEGIN
  IF NOT public.is_current_user_admin() THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'ADMIN_REQUIRED'
    );
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'user_id', p.id,
        'username', p.username,
        'google_name', p.google_name,
        'x_username', p.x_username,
        'wp', COALESCE(p.wp,0),
        'streak', public.effective_streak(
          p.last_checkin,
          p.streak
        ),
        'avatar_url', p.avatar_url
      )
      ORDER BY p.wp DESC, p.streak DESC, p.created_at ASC
    ),
    '[]'::jsonb
  )
  INTO v_profiles
  FROM public.profiles p;

  RETURN jsonb_build_object(
    'ok', true,
    'profiles', v_profiles
  );
END;
$$;


/* ============================================================
   14. ADMIN PROFILE
   ============================================================ */

CREATE OR REPLACE FUNCTION public.get_admin_profile(
  p_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile public.profiles;
BEGIN
  IF NOT public.is_current_user_admin() THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'ADMIN_REQUIRED'
    );
  END IF;

  SELECT *
  INTO v_profile
  FROM public.profiles
  WHERE id = p_user_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'PROFILE_NOT_FOUND'
    );
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'profile',
    jsonb_build_object(
      'user_id', v_profile.id,
      'username', v_profile.username,
      'google_name', v_profile.google_name,
      'x_username', v_profile.x_username,
      'wp', v_profile.wp,
      'streak', v_profile.streak,
      'wallet_address', v_profile.wallet_address,
      'avatar_url', v_profile.avatar_url
    )
  );
END;
$$;


/* ============================================================
   15. SOLANA WALLET VALIDATION
   ============================================================ */

CREATE OR REPLACE FUNCTION public.is_valid_solana_address(
  p_wallet text
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_wallet text;
BEGIN
  v_wallet := btrim(COALESCE(p_wallet,''));

  /*
    Solana addresses are base58 strings normally between
    roughly 32 and 44 characters.
  */
  IF v_wallet = '' THEN
    RETURN false;
  END IF;

  IF length(v_wallet) < 32 OR length(v_wallet) > 44 THEN
    RETURN false;
  END IF;

  IF v_wallet !~ '^[1-9A-HJ-NP-Za-km-z]+$' THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;


/* ============================================================
   16. UPDATE PROFILE
   ============================================================ */

DROP FUNCTION IF EXISTS public.update_profile(text,text);
DROP FUNCTION IF EXISTS public.update_profile(text,text,text);

CREATE OR REPLACE FUNCTION public.update_profile(
  p_username text,
  p_x_username text,
  p_wallet_address text
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid;
  v_profile public.profiles;
  v_username text;
  v_x text;
  v_wallet text;
  v_x_bonus integer := 0;
  v_wallet_bonus integer := 0;
BEGIN
  v_user := auth.uid();

  IF v_user IS NULL THEN
    RETURN json_build_object(
      'ok', false,
      'error', 'NOT_AUTHENTICATED'
    );
  END IF;

  v_profile := public.ensure_profile();

  v_username := NULLIF(btrim(COALESCE(p_username,'')), '');
  v_x := NULLIF(
    btrim(
      regexp_replace(
        COALESCE(p_x_username,''),
        '^@',
        ''
      )
    ),
    ''
  );
  v_wallet := NULLIF(btrim(COALESCE(p_wallet_address,'')), '');

  IF v_username IS NOT NULL
     AND v_username !~ '^[A-Za-z0-9_]{3,20}$'
  THEN
    RETURN json_build_object(
      'ok', false,
      'error', 'INVALID_USERNAME'
    );
  END IF;

  IF v_username IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.profiles p
       WHERE lower(p.username) = lower(v_username)
         AND p.id <> v_user
     )
  THEN
    RETURN json_build_object(
      'ok', false,
      'error', 'USERNAME_TAKEN'
    );
  END IF;

  IF v_x IS NOT NULL
     AND v_x !~ '^[A-Za-z0-9_]{1,15}$'
  THEN
    RETURN json_build_object(
      'ok', false,
      'error', 'INVALID_X'
    );
  END IF;

  IF v_wallet IS NOT NULL
     AND NOT public.is_valid_solana_address(v_wallet)
  THEN
    RETURN json_build_object(
      'ok', false,
      'error', 'INVALID_WALLET'
    );
  END IF;

  /*
    X bonus is awarded only the first time X is successfully added.
  */
  IF v_x IS NOT NULL
     AND NOT COALESCE(v_profile.x_bonus_claimed,false)
  THEN
    v_x_bonus := 5;
  END IF;

  /*
    Wallet bonus is awarded only the first time a wallet is saved.
  */
  IF v_wallet IS NOT NULL
     AND NOT COALESCE(v_profile.wallet_bonus_claimed,false)
  THEN
    v_wallet_bonus := 5;
  END IF;

  UPDATE public.profiles
  SET
    username = v_username,
    x_username = v_x,
    wallet_address = v_wallet,
    x_bonus_claimed =
      CASE
        WHEN v_x IS NOT NULL
          THEN true
        ELSE x_bonus_claimed
      END,
    wallet_bonus_claimed =
      CASE
        WHEN v_wallet IS NOT NULL
          THEN true
        ELSE wallet_bonus_claimed
      END,
    wp = COALESCE(wp,0)
       + v_x_bonus
       + v_wallet_bonus
  WHERE id = v_user
  RETURNING *
  INTO v_profile;

  RETURN json_build_object(
    'ok', true,
    'username', v_profile.username,
    'x_username', v_profile.x_username,
    'wallet_address', v_profile.wallet_address,
    'x_bonus', v_x_bonus,
    'wallet_bonus', v_wallet_bonus,
    'total_bonus', v_x_bonus + v_wallet_bonus
  );
END;
$$;


/* ============================================================
   17. REFERRAL CODE GENERATION
   ============================================================ */

CREATE OR REPLACE FUNCTION public.generate_referral_code()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid;
  v_existing text;
  v_code text;
BEGIN
  v_user := auth.uid();

  IF v_user IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED';
  END IF;

  SELECT referral_code
  INTO v_existing
  FROM public.referral_codes
  WHERE user_id = v_user;

  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  v_code :=
    'GW' ||
    upper(
      substr(
        replace(v_user::text,'-',''),
        1,
        8
      )
    );

  INSERT INTO public.referral_codes(
    user_id,
    referral_code
  )
  VALUES(
    v_user,
    v_code
  )
  ON CONFLICT (user_id)
  DO UPDATE
  SET referral_code = EXCLUDED.referral_code;

  RETURN v_code;
END;
$$;


/* ============================================================
   18. GET MY REFERRAL CODE
   ============================================================ */

CREATE OR REPLACE FUNCTION public.get_my_referral_code()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid;
  v_code text;
BEGIN
  v_user := auth.uid();

  IF v_user IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT referral_code
  INTO v_code
  FROM public.referral_codes
  WHERE user_id = v_user;

  IF v_code IS NULL THEN
    v_code := public.generate_referral_code();
  END IF;

  RETURN v_code;
END;
$$;


/* ============================================================
   19. REFERRAL DATA FOR DASHBOARD
   ============================================================ */

CREATE OR REPLACE FUNCTION public.get_my_referral_data()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid;
  v_code text;
  v_total integer;
  v_successful integer;
  v_reward_count integer;
  v_total_wp integer;
  v_has_been_referred boolean;
  v_activity_streak integer;
  v_days_remaining integer;
  v_qualified boolean;
  v_referral_id bigint;
  v_first_activity date;
BEGIN
  v_user := auth.uid();

  IF v_user IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'NOT_AUTHENTICATED'
    );
  END IF;

  v_code := public.get_my_referral_code();

  SELECT COUNT(*)
  INTO v_total
  FROM public.referrals
  WHERE referrer_id = v_user;

  SELECT COUNT(*)
  INTO v_successful
  FROM public.referrals
  WHERE referrer_id = v_user
    AND qualified_at IS NOT NULL;

  SELECT COUNT(*)
  INTO v_reward_count
  FROM public.referral_rewards
  WHERE referrer_id = v_user;

  SELECT COALESCE(SUM(wp_awarded),0)
  INTO v_total_wp
  FROM public.referral_rewards
  WHERE referrer_id = v_user;

  SELECT EXISTS (
    SELECT 1
    FROM public.referrals
    WHERE referred_id = v_user
  )
  INTO v_has_been_referred;

  SELECT
    r.id
  INTO v_referral_id
  FROM public.referrals r
  WHERE r.referred_id = v_user
  LIMIT 1;

  /*
    Referral activity is measured from check-ins belonging to
    the referred account.

    The dashboard displays this as "Your activity streak / 7".
  */
  SELECT MIN(c.day)
  INTO v_first_activity
  FROM public.checkins c
  WHERE c.user_id = v_user;

  SELECT public.effective_streak(
    p.last_checkin,
    p.streak
  )
  INTO v_activity_streak
  FROM public.profiles p
  WHERE p.id = v_user;

  v_activity_streak :=
    LEAST(
      COALESCE(v_activity_streak,0),
      7
    );

  v_days_remaining :=
    GREATEST(
      0,
      7 - COALESCE(v_activity_streak,0)
    );

  /*
    Successful referral qualification:
    - referred account exists
    - at least 7-day activity streak
    - at least 3 total check-ins
  */
  SELECT
    EXISTS (
      SELECT 1
      FROM public.referrals r
      WHERE r.referred_id = v_user
        AND r.qualified_at IS NOT NULL
    )
    OR (
      COALESCE(v_activity_streak,0) >= 7
      AND (
        SELECT COUNT(*)
        FROM public.checkins c
        WHERE c.user_id = v_user
      ) >= 3
    )
  INTO v_qualified;

  RETURN jsonb_build_object(
    'ok', true,

    'referral_code', v_code,

    'referral_link',
      'https://thegreenwarden.xyz/dashboard.html?ref='
      || COALESCE(v_code,''),

    'referral_count', v_total,
    'total_referrals', v_total,

    'successful_referrals', v_successful,

    'reward_count', v_reward_count,

    'total_wp_earned', v_total_wp,

    'has_been_referred', v_has_been_referred,

    'activity_streak', COALESCE(v_activity_streak,0),
    'my_activity_streak', COALESCE(v_activity_streak,0),

    'days_remaining', v_days_remaining,

    'qualified', v_qualified,
    'my_7_day_qualified', v_qualified
  );
END;
$$;


/* ============================================================
   20. ATTACH REFERRAL
   IMPORTANT:
   This function DOES NOT pay +200.
   It only creates the referral relationship.
   ============================================================ */

CREATE OR REPLACE FUNCTION public.attach_referral(
  p_code text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid;
  v_code text;
  v_referrer uuid;
BEGIN
  v_user := auth.uid();

  IF v_user IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'NOT_AUTHENTICATED'
    );
  END IF;

  v_code := upper(btrim(COALESCE(p_code,'')));

  IF v_code = '' THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'INVALID_CODE',
      'message', 'Referral code is required.'
    );
  END IF;

  SELECT user_id
  INTO v_referrer
  FROM public.referral_codes
  WHERE upper(referral_code) = v_code
  LIMIT 1;

  IF v_referrer IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'INVALID_CODE',
      'message', 'Referral code not found.'
    );
  END IF;

  IF v_referrer = v_user THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'SELF_REFERRAL',
      'message', 'You cannot use your own referral code.'
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.referrals
    WHERE referred_id = v_user
  ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'ALREADY_REFERRED',
      'message', 'This account already has a referral attached.'
    );
  END IF;

  INSERT INTO public.referrals (
    referrer_id,
    referred_id,
    referral_code,
    initial_reward,
    active_reward
  )
  VALUES (
    v_referrer,
    v_user,
    v_code,
    300,
    200
  );

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Referral attached successfully.',
    'referrer_id', v_referrer
  );

EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'ALREADY_REFERRED',
      'message', 'This account already has a referral attached.'
    );
END;
$$;


/* ============================================================
   21. QUALIFY REFERRAL
   EXACT REWARD = +200 WP
   Paid to REFERRER only.
   ============================================================ */

CREATE OR REPLACE FUNCTION public.qualify_referral(
  p_referred_user uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid;
  v_referral public.referrals;
  v_checkins integer;
  v_streak integer;
  v_reward integer := 200;
  v_inserted boolean := false;
BEGIN
  v_user := auth.uid();

  IF v_user IS NULL THEN
    RETURN jsonb_build_object(
      'rewarded', false,
      'error', 'NOT_AUTHENTICATED'
    );
  END IF;

  /*
    A normal user can only qualify their own referral.
  */
  IF p_referred_user <> v_user
     AND NOT public.is_current_user_admin()
  THEN
    RETURN jsonb_build_object(
      'rewarded', false,
      'error', 'FORBIDDEN'
    );
  END IF;

  SELECT *
  INTO v_referral
  FROM public.referrals
  WHERE referred_id = p_referred_user
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'rewarded', false,
      'error', 'REFERRAL_NOT_FOUND'
    );
  END IF;

  /*
    Already qualified/rewarded.
  */
  IF v_referral.qualified_at IS NOT NULL
     OR v_referral.active_rewarded_at IS NOT NULL
  THEN
    RETURN jsonb_build_object(
      'rewarded', false,
      'already_rewarded', true,
      'wp_awarded', 0
    );
  END IF;

  SELECT COUNT(*)
  INTO v_checkins
  FROM public.checkins
  WHERE user_id = p_referred_user;

  SELECT public.effective_streak(
    p.last_checkin,
    p.streak
  )
  INTO v_streak
  FROM public.profiles p
  WHERE p.id = p_referred_user;

  /*
    Qualification rule:
    7-day activity streak AND at least 3 check-ins.
  */
  IF COALESCE(v_streak,0) < 7
     OR COALESCE(v_checkins,0) < 3
  THEN
    RETURN jsonb_build_object(
      'rewarded', false,
      'qualified', false,
      'streak', COALESCE(v_streak,0),
      'checkins', v_checkins
    );
  END IF;

  /*
    Mark the referral qualified first.
  */
  UPDATE public.referrals
  SET
    qualified_at = now(),
    active_reward = v_reward,
    active_rewarded_at = now()
  WHERE id = v_referral.id;

  /*
    Insert exactly one active referral reward.
    The unique partial index protects against duplicates.
  */
  INSERT INTO public.referral_rewards (
    referral_id,
    referrer_id,
    reward_type,
    wp_awarded
  )
  VALUES (
    v_referral.id,
    v_referral.referrer_id,
    'active_referral',
    v_reward
  )
  ON CONFLICT (referral_id, reward_type)
  WHERE reward_type = 'active_referral'
  DO NOTHING;

  IF FOUND THEN
    v_inserted := true;
  END IF;

  /*
    Only add WP when the reward row was newly inserted.
  */
  IF v_inserted THEN

    UPDATE public.profiles
    SET wp = COALESCE(wp,0) + v_reward
    WHERE id = v_referral.referrer_id;

  END IF;

  RETURN jsonb_build_object(
    'rewarded', v_inserted,
    'qualified', true,
    'wp_awarded',
      CASE
        WHEN v_inserted THEN v_reward
        ELSE 0
      END,
    'referrer_id', v_referral.referrer_id,
    'referred_user', p_referred_user
  );
END;
$$;


/* ============================================================
   22. QUALIFY MY REFERRAL
   Compatibility helper
   ============================================================ */

CREATE OR REPLACE FUNCTION public.qualify_my_referral()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN public.qualify_referral(auth.uid());
END;
$$;


/* ============================================================
   23. REFERRAL ACTIVITY / LIST HELPERS
   ============================================================ */

CREATE OR REPLACE FUNCTION public.get_my_referral_list()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid;
  v_rows jsonb;
BEGIN
  v_user := auth.uid();

  IF v_user IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', r.id,
        'referred_id', r.referred_id,
        'referral_code', r.referral_code,
        'created_at', r.created_at,
        'qualified_at', r.qualified_at,
        'active_reward', r.active_reward,
        'active_rewarded_at', r.active_rewarded_at
      )
      ORDER BY r.created_at DESC
    ),
    '[]'::jsonb
  )
  INTO v_rows
  FROM public.referrals r
  WHERE r.referrer_id = v_user;

  RETURN v_rows;
END;
$$;


CREATE OR REPLACE FUNCTION public.get_my_referral_activity()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user uuid;
BEGIN
  v_user := auth.uid();

  IF v_user IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'NOT_AUTHENTICATED'
    );
  END IF;

  RETURN public.get_my_referral_data();
END;
$$;


/* ============================================================
   24. RLS
   ============================================================ */

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.checkins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referral_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referrals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.referral_rewards ENABLE ROW LEVEL SECURITY;


/* -------------------- Profiles policies -------------------- */

DROP POLICY IF EXISTS profiles_select_own
ON public.profiles;

CREATE POLICY profiles_select_own
ON public.profiles
FOR SELECT
TO authenticated
USING (
  id = auth.uid()
);


DROP POLICY IF EXISTS profiles_update_own
ON public.profiles;

CREATE POLICY profiles_update_own
ON public.profiles
FOR UPDATE
TO authenticated
USING (
  id = auth.uid()
)
WITH CHECK (
  id = auth.uid()
);


/* -------------------- Checkins policies -------------------- */

DROP POLICY IF EXISTS checkins_select_own
ON public.checkins;

CREATE POLICY checkins_select_own
ON public.checkins
FOR SELECT
TO authenticated
USING (
  user_id = auth.uid()
);


/* -------------------- Tasks policies -------------------- */

DROP POLICY IF EXISTS tasks_select_authenticated
ON public.tasks;

CREATE POLICY tasks_select_authenticated
ON public.tasks
FOR SELECT
TO authenticated
USING (
  active = true
);


/* -------------------- Task claims policies -------------------- */

DROP POLICY IF EXISTS task_claims_select_own
ON public.task_claims;

CREATE POLICY task_claims_select_own
ON public.task_claims
FOR SELECT
TO authenticated
USING (
  user_id = auth.uid()
);


/* -------------------- Referral code policies -------------------- */

DROP POLICY IF EXISTS referral_codes_select_own
ON public.referral_codes;

CREATE POLICY referral_codes_select_own
ON public.referral_codes
FOR SELECT
TO authenticated
USING (
  user_id = auth.uid()
);


/* -------------------- Referrals policies -------------------- */

DROP POLICY IF EXISTS referrals_select_own
ON public.referrals;

CREATE POLICY referrals_select_own
ON public.referrals
FOR SELECT
TO authenticated
USING (
  referrer_id = auth.uid()
  OR referred_id = auth.uid()
);


/* -------------------- Referral rewards policies -------------------- */

DROP POLICY IF EXISTS referral_rewards_select_own
ON public.referral_rewards;

CREATE POLICY referral_rewards_select_own
ON public.referral_rewards
FOR SELECT
TO authenticated
USING (
  referrer_id = auth.uid()
);


/* ============================================================
   25. DEFAULT TASKS
   Only inserted if they don't already exist.
   ============================================================ */

INSERT INTO public.tasks (
  id,
  label,
  url,
  wp_reward,
  needs_proof,
  active,
  sort_order
)
VALUES
(
  'like-launch-post',
  'Like the Green Warden launch post',
  'https://x.com/ThegoodbearSOL',
  10,
  true,
  true,
  10
),
(
  'share-launch-post',
  'Share the Green Warden launch post',
  'https://x.com/ThegoodbearSOL',
  10,
  true,
  true,
  20
)
ON CONFLICT (id) DO NOTHING;


/* ============================================================
   26. GRANTS
   ============================================================ */

REVOKE ALL ON FUNCTION public.ensure_profile() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.manila_today() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.manila_seconds_to_reset() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.effective_streak(date,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.wp_for_day(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_status() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.claim_checkin() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_portal_activity() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_task_board() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.submit_task_for_review(text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_current_user_admin() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_admin_task_reviews() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.approve_task_claim(uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reject_task_claim(uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_leaderboard(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_admin_leaderboard() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_admin_profile(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_valid_solana_address(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_profile(text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.generate_referral_code() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_referral_code() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_referral_data() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.attach_referral(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.qualify_referral(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.qualify_my_referral() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_referral_list() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_referral_activity() FROM PUBLIC;


GRANT EXECUTE ON FUNCTION public.ensure_profile()
TO authenticated;

GRANT EXECUTE ON FUNCTION public.manila_today()
TO authenticated;

GRANT EXECUTE ON FUNCTION public.manila_seconds_to_reset()
TO authenticated;

GRANT EXECUTE ON FUNCTION public.effective_streak(date,integer)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.wp_for_day(integer)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.get_my_status()
TO authenticated;

GRANT EXECUTE ON FUNCTION public.claim_checkin()
TO authenticated;

GRANT EXECUTE ON FUNCTION public.record_portal_activity()
TO authenticated;

GRANT EXECUTE ON FUNCTION public.get_task_board()
TO authenticated;

GRANT EXECUTE ON FUNCTION public.submit_task_for_review(text,text)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.is_current_user_admin()
TO authenticated;

GRANT EXECUTE ON FUNCTION public.get_admin_task_reviews()
TO authenticated;

GRANT EXECUTE ON FUNCTION public.approve_task_claim(uuid,text)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.reject_task_claim(uuid,text)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.get_leaderboard(integer)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.get_admin_leaderboard()
TO authenticated;

GRANT EXECUTE ON FUNCTION public.get_admin_profile(uuid)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.is_valid_solana_address(text)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.update_profile(text,text,text)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.generate_referral_code()
TO authenticated;

GRANT EXECUTE ON FUNCTION public.get_my_referral_code()
TO authenticated;

GRANT EXECUTE ON FUNCTION public.get_my_referral_data()
TO authenticated;

GRANT EXECUTE ON FUNCTION public.attach_referral(text)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.qualify_referral(uuid)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.qualify_my_referral()
TO authenticated;

GRANT EXECUTE ON FUNCTION public.get_my_referral_list()
TO authenticated;

GRANT EXECUTE ON FUNCTION public.get_my_referral_activity()
TO authenticated;


/* ============================================================
   27. UNIQUE CHECK-IN PROTECTION
   ============================================================ */

CREATE UNIQUE INDEX IF NOT EXISTS checkins_user_day_unique
ON public.checkins(user_id, day);


/* ============================================================
   28. FINAL COMMIT
   ============================================================ */

COMMIT;


/* ============================================================
   29. VERIFICATION
   These SELECT statements are safe to run after the script.
   ============================================================ */

SELECT
  'profiles' AS table_name,
  COUNT(*) AS rows
FROM public.profiles

UNION ALL

SELECT
  'checkins',
  COUNT(*)
FROM public.checkins

UNION ALL

SELECT
  'tasks',
  COUNT(*)
FROM public.tasks

UNION ALL

SELECT
  'task_claims',
  COUNT(*)
FROM public.task_claims

UNION ALL

SELECT
  'referral_codes',
  COUNT(*)
FROM public.referral_codes

UNION ALL

SELECT
  'referrals',
  COUNT(*)
FROM public.referrals

UNION ALL

SELECT
  'referral_rewards',
  COUNT(*)
FROM public.referral_rewards;
