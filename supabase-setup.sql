/* ============================================================
   THE GREEN WARDEN
   SAFE REFERRAL + DASHBOARD COMPATIBILITY SQL
   ============================================================

   IMPORTANT:
   - Does NOT drop tables.
   - Does NOT delete existing users/data.
   - Does NOT reset WP.
   - A referral is NOT rewarded when merely attached.
   - A successful/qualified referral pays EXACTLY +200 WP.
   - The +200 reward can only be paid once.
   ============================================================ */


/* ============================================================
   1. REFERRAL CODE UNIQUE INDEX
   ============================================================ */

CREATE UNIQUE INDEX IF NOT EXISTS referral_codes_referral_code_uidx
ON public.referral_codes (referral_code);


/* ============================================================
   2. GENERATE REFERRAL CODE
   ============================================================ */

CREATE OR REPLACE FUNCTION public.generate_referral_code()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_existing text;
    v_code text;
BEGIN

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'AUTH_REQUIRED';
    END IF;


    /* Existing permanent code */
    SELECT referral_code
    INTO v_existing
    FROM public.referral_codes
    WHERE user_id = v_user_id
    LIMIT 1;


    IF v_existing IS NOT NULL THEN
        RETURN v_existing;
    END IF;


    /*
      Example:
      GW1A2B3C4D
    */

    v_code :=
        'GW' ||
        upper(
            substr(
                replace(v_user_id::text, '-', ''),
                1,
                8
            )
        );


    BEGIN

        INSERT INTO public.referral_codes (
            user_id,
            referral_code
        )
        VALUES (
            v_user_id,
            v_code
        );

    EXCEPTION
        WHEN unique_violation THEN

            v_code :=
                'GW' ||
                upper(
                    substr(
                        replace(v_user_id::text, '-', ''),
                        1,
                        12
                    )
                );

            INSERT INTO public.referral_codes (
                user_id,
                referral_code
            )
            VALUES (
                v_user_id,
                v_code
            );

    END;


    RETURN v_code;

END;
$$;


/* ============================================================
   3. GET MY REFERRAL CODE
   ============================================================ */

CREATE OR REPLACE FUNCTION public.get_my_referral_code()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user_id uuid := auth.uid();
    v_code text;
BEGIN

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'AUTH_REQUIRED';
    END IF;


    SELECT referral_code
    INTO v_code
    FROM public.referral_codes
    WHERE user_id = v_user_id
    LIMIT 1;


    IF v_code IS NULL THEN
        v_code := public.generate_referral_code();
    END IF;


    RETURN v_code;

END;
$$;


/* ============================================================
   4. GET MY REFERRAL DATA
   ============================================================

   Dashboard expects:

       total_referrals
       total_wp_earned
       my_activity_streak
       my_7_day_qualified

   We also return the existing/legacy names for compatibility.

   IMPORTANT:
   referral_rewards uses wp_awarded, NOT wp_amount.
   ============================================================ */

CREATE OR REPLACE FUNCTION public.get_my_referral_data()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE

    v_user_id uuid := auth.uid();

    v_code text;

    v_total_referrals integer := 0;
    v_successful_referrals integer := 0;
    v_reward_count integer := 0;

    v_total_wp integer := 0;

    v_has_been_referred boolean := false;

    v_activity_streak integer := 0;
    v_days_remaining integer := 7;

    v_qualified boolean := false;

    v_today date;

BEGIN

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'AUTH_REQUIRED';
    END IF;


    /* --------------------------------------------------------
       Referral code
       -------------------------------------------------------- */

    v_code := public.get_my_referral_code();


    /* --------------------------------------------------------
       Total referrals
       -------------------------------------------------------- */

    SELECT count(*)
    INTO v_total_referrals
    FROM public.referrals
    WHERE referrer_id = v_user_id;


    /* --------------------------------------------------------
       Successful referrals
       -------------------------------------------------------- */

    SELECT count(*)
    INTO v_successful_referrals
    FROM public.referrals
    WHERE referrer_id = v_user_id
      AND qualified_at IS NOT NULL;


    /* --------------------------------------------------------
       Rewards

       IMPORTANT:
       actual column is wp_awarded.
       ======================================================== */

    SELECT
        count(*),
        COALESCE(sum(wp_awarded), 0)
    INTO
        v_reward_count,
        v_total_wp
    FROM public.referral_rewards
    WHERE referrer_id = v_user_id;


    /* --------------------------------------------------------
       Has this user been referred?
       -------------------------------------------------------- */

    SELECT EXISTS (
        SELECT 1
        FROM public.referrals
        WHERE referred_id = v_user_id
    )
    INTO v_has_been_referred;


    /* --------------------------------------------------------
       Manila date
       -------------------------------------------------------- */

    v_today :=
        (now() AT TIME ZONE 'Asia/Manila')::date;


    /* --------------------------------------------------------
       Current consecutive check-in streak

       Uses the REAL checkins schema:

           user_id
           day
           day_in_cycle
           wp_awarded
           created_at
       -------------------------------------------------------- */

    IF v_has_been_referred THEN

        WITH days AS (

            SELECT DISTINCT day

            FROM public.checkins

            WHERE user_id = v_user_id
              AND day <= v_today

        ),

        numbered AS (

            SELECT
                day,

                day -
                (
                    row_number() OVER (
                        ORDER BY day DESC
                    )
                )::integer AS grp

            FROM days

        ),

        latest_group AS (

            SELECT grp

            FROM numbered

            ORDER BY day DESC

            LIMIT 1

        )

        SELECT count(*)
        INTO v_activity_streak

        FROM numbered

        WHERE grp = (
            SELECT grp
            FROM latest_group
        );


        /*
          If the latest check-in is not today or yesterday,
          the active streak is zero.
        */

        IF NOT EXISTS (
            SELECT 1
            FROM public.checkins
            WHERE user_id = v_user_id
              AND day = v_today
        )
        AND NOT EXISTS (
            SELECT 1
            FROM public.checkins
            WHERE user_id = v_user_id
              AND day = v_today - 1
        ) THEN

            v_activity_streak := 0;

        END IF;

    END IF;


    /* --------------------------------------------------------
       7-day qualification
       -------------------------------------------------------- */

    v_qualified :=
        v_has_been_referred
        AND v_activity_streak >= 7;


    /* --------------------------------------------------------
       Days remaining
       -------------------------------------------------------- */

    IF v_qualified THEN

        v_days_remaining := 0;

    ELSE

        v_days_remaining :=
            GREATEST(
                0,
                7 - v_activity_streak
            );

    END IF;


    RETURN jsonb_build_object(

        /* ====================================================
           DASHBOARD FIELD NAMES
           ==================================================== */

        'referral_code',
            v_code,

        'referral_link',
            '?ref=' || v_code,

        'total_referrals',
            v_total_referrals,

        'total_wp_earned',
            v_total_wp,

        'my_activity_streak',
            v_activity_streak,

        'my_7_day_qualified',
            v_qualified,


        /* ====================================================
           ADDITIONAL REFERRAL INFORMATION
           ==================================================== */

        'has_been_referred',
            v_has_been_referred,

        'successful_referrals',
            v_successful_referrals,

        'reward_count',
            v_reward_count,

        'activity_streak',
            v_activity_streak,

        'days_remaining',
            v_days_remaining,

        'qualified',
            v_qualified,


        /* ====================================================
           LEGACY COMPATIBILITY
           ==================================================== */

        'referral_count',
            v_total_referrals

    );

END;
$$;


/* ============================================================
   5. ATTACH REFERRAL
   ============================================================

   IMPORTANT:

   Attaching a referral code DOES NOT award WP.

   It only creates:

       referrals

   The +200 WP reward happens ONLY after qualification.
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

    v_user_id uuid := auth.uid();

    v_code text;

    v_referrer_id uuid;

    v_referral_id bigint;

BEGIN

    IF v_user_id IS NULL THEN

        RETURN jsonb_build_object(
            'ok', false,
            'success', false,
            'message', 'AUTH_REQUIRED'
        );

    END IF;


    v_code :=
        upper(
            trim(
                coalesce(p_code, '')
            )
        );


    IF v_code = '' THEN

        RETURN jsonb_build_object(
            'ok', false,
            'success', false,
            'message', 'INVALID_CODE'
        );

    END IF;


    /* Find referral code owner */

    SELECT user_id
    INTO v_referrer_id

    FROM public.referral_codes

    WHERE upper(referral_code) = v_code

    LIMIT 1;


    IF v_referrer_id IS NULL THEN

        RETURN jsonb_build_object(
            'ok', false,
            'success', false,
            'message', 'REFERRAL_CODE_NOT_FOUND'
        );

    END IF;


    /* Prevent self-referral */

    IF v_referrer_id = v_user_id THEN

        RETURN jsonb_build_object(
            'ok', false,
            'success', false,
            'message', 'SELF_REFERRAL'
        );

    END IF;


    /* Prevent attaching twice */

    IF EXISTS (
        SELECT 1
        FROM public.referrals
        WHERE referred_id = v_user_id
    ) THEN

        RETURN jsonb_build_object(
            'ok', false,
            'success', false,
            'message', 'ALREADY_REFERRED'
        );

    END IF;


    INSERT INTO public.referrals (
        referrer_id,
        referred_id,
        referral_code
    )

    VALUES (
        v_referrer_id,
        v_user_id,
        v_code
    )

    RETURNING id
    INTO v_referral_id;


    /*
      NO WP IS AWARDED HERE.

      The successful referral reward is handled by
      qualify_referral() after the referred user reaches
      the required activity.
    */


    RETURN jsonb_build_object(

        'ok', true,

        'success', true,

        'message', 'REFERRAL_ATTACHED',

        'referral_id',
            v_referral_id,

        'referrer_id',
            v_referrer_id,

        'wp_awarded',
            0

    );

END;
$$;


/* ============================================================
   6. QUALIFY REFERRAL
   ============================================================

   SUCCESSFUL REFERRAL REWARD:

       EXACTLY +200 WP

   Rules:

       1. Referral must exist.
       2. Referred user must have 7 consecutive check-in days.
       3. Referral must not already be qualified.
       4. Reward is recorded in referral_rewards.
       5. Referrer's profile receives exactly +200 WP.
       6. The reward cannot be paid twice.
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

    v_referral public.referrals%ROWTYPE;

    v_today date;

    v_streak integer := 0;

    v_reward integer := 200;

BEGIN

    IF p_referred_user IS NULL THEN

        RETURN jsonb_build_object(
            'ok', false,
            'rewarded', false,
            'error', 'INVALID_USER'
        );

    END IF;


    /* --------------------------------------------------------
       Locate referral
       -------------------------------------------------------- */

    SELECT *
    INTO v_referral

    FROM public.referrals

    WHERE referred_id = p_referred_user

    ORDER BY created_at ASC

    LIMIT 1;


    IF NOT FOUND THEN

        RETURN jsonb_build_object(
            'ok', true,
            'rewarded', false,
            'error', 'NO_REFERRAL'
        );

    END IF;


    /* --------------------------------------------------------
       Already qualified
       -------------------------------------------------------- */

    IF v_referral.qualified_at IS NOT NULL THEN

        RETURN jsonb_build_object(
            'ok', true,
            'rewarded', false,
            'already_qualified', true,
            'wp_awarded', 0
        );

    END IF;


    /* --------------------------------------------------------
       Manila date
       -------------------------------------------------------- */

    v_today :=
        (now() AT TIME ZONE 'Asia/Manila')::date;


    /* --------------------------------------------------------
       Calculate consecutive check-in streak
       -------------------------------------------------------- */

    WITH days AS (

        SELECT DISTINCT day

        FROM public.checkins

        WHERE user_id = p_referred_user
          AND day <= v_today

    ),

    numbered AS (

        SELECT

            day,

            day -
            (
                row_number() OVER (
                    ORDER BY day DESC
                )
            )::integer AS grp

        FROM days

    ),

    latest_group AS (

        SELECT grp

        FROM numbered

        ORDER BY day DESC

        LIMIT 1

    )

    SELECT count(*)

    INTO v_streak

    FROM numbered

    WHERE grp = (
        SELECT grp
        FROM latest_group
    );


    /* --------------------------------------------------------
       Not qualified yet
       -------------------------------------------------------- */

    IF v_streak < 7 THEN

        RETURN jsonb_build_object(

            'ok', true,

            'rewarded', false,

            'streak', v_streak,

            'required', 7,

            'wp_awarded', 0

        );

    END IF;


    /* --------------------------------------------------------
       Lock referral row
       -------------------------------------------------------- */

    SELECT *
    INTO v_referral

    FROM public.referrals

    WHERE id = v_referral.id

    FOR UPDATE;


    /* --------------------------------------------------------
       Double-check qualification
       -------------------------------------------------------- */

    IF v_referral.qualified_at IS NOT NULL THEN

        RETURN jsonb_build_object(
            'ok', true,
            'rewarded', false,
            'already_qualified', true,
            'wp_awarded', 0
        );

    END IF;


    /* --------------------------------------------------------
       Mark referral qualified
       -------------------------------------------------------- */

    UPDATE public.referrals

    SET
        qualified_at = now(),

        active_rewarded_at = now()

    WHERE id = v_referral.id;


    /* --------------------------------------------------------
       Record EXACTLY ONE +200 WP reward
       -------------------------------------------------------- */

    INSERT INTO public.referral_rewards (

        referral_id,

        referrer_id,

        reward_type,

        wp_awarded

    )

    VALUES (

        v_referral.id,

        v_referral.referrer_id,

        'successful_referral',

        v_reward

    );


    /* --------------------------------------------------------
       Award EXACTLY +200 WP to referrer
       -------------------------------------------------------- */

    UPDATE public.profiles

    SET
        wp = COALESCE(wp, 0) + v_reward

    WHERE id = v_referral.referrer_id;


    RETURN jsonb_build_object(

        'ok', true,

        'rewarded', true,

        'streak', v_streak,

        'required', 7,

        'wp_awarded', v_reward,

        'referrer_id',
            v_referral.referrer_id,

        'referral_id',
            v_referral.id

    );

END;
$$;


/* ============================================================
   7. QUALIFY MY REFERRAL
   ============================================================ */

CREATE OR REPLACE FUNCTION public.qualify_my_referral()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN

    IF auth.uid() IS NULL THEN

        RETURN jsonb_build_object(
            'ok', false,
            'rewarded', false,
            'error', 'AUTH_REQUIRED'
        );

    END IF;


    RETURN public.qualify_referral(
        auth.uid()
    );

END;
$$;


/* ============================================================
   8. FUNCTION PERMISSIONS
   ============================================================ */

REVOKE ALL
ON FUNCTION public.generate_referral_code()
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.get_my_referral_code()
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.get_my_referral_data()
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.attach_referral(text)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.qualify_referral(uuid)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION public.qualify_my_referral()
FROM PUBLIC;


GRANT EXECUTE
ON FUNCTION public.get_my_referral_code()
TO authenticated;

GRANT EXECUTE
ON FUNCTION public.get_my_referral_data()
TO authenticated;

GRANT EXECUTE
ON FUNCTION public.attach_referral(text)
TO authenticated;

GRANT EXECUTE
ON FUNCTION public.qualify_referral(uuid)
TO authenticated;

GRANT EXECUTE
ON FUNCTION public.qualify_my_referral()
TO authenticated;


/* ============================================================
   9. VERIFY REFERRAL FUNCTIONS
   ============================================================ */

SELECT
    p.proname AS function_name,
    pg_get_function_identity_arguments(p.oid) AS arguments,
    pg_get_function_result(p.oid) AS return_type
FROM pg_proc p
JOIN pg_namespace n
    ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
AND p.proname IN (
    'generate_referral_code',
    'get_my_referral_code',
    'get_my_referral_data',
    'attach_referral',
    'qualify_referral',
    'qualify_my_referral'
)
ORDER BY
    p.proname,
    arguments;


/* ============================================================
   10. CHECK EXISTING REFERRAL REWARDS
   ============================================================ */

SELECT
    id,
    referral_id,
    referrer_id,
    reward_type,
    wp_awarded,
    created_at
FROM public.referral_rewards
ORDER BY created_at DESC
LIMIT 20;


/* ============================================================
   11. CHECK REFERRALS
   ============================================================ */

SELECT
    id,
    referrer_id,
    referred_id,
    referral_code,
    initial_reward,
    initial_rewarded_at,
    active_reward,
    active_rewarded_at,
    qualified_at,
    created_at
FROM public.referrals
ORDER BY created_at DESC
LIMIT 20;
