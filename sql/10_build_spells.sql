-- 10_build_spells.sql
-- Build per-user subscription spells from the raw KKBox transaction log.
--
-- Run via scripts/build_spells.py (which resolves paths from its own location
-- and executes this file against data/processed/kkbox.duckdb).
--
-- ---------------------------------------------------------------------------
-- Definitions
-- ---------------------------------------------------------------------------
-- Raw dates are integers in YYYYMMDD form; everything below works in DATE.
--
-- A *spell* is a maximal run of transactions in which each renewal happens
-- within GRACE_DAYS (30) of the previous membership expiry. A gap longer than
-- that is the KKBox churn definition: membership lapsed and was not renewed.
--
-- We model each user's FIRST spell only. That spell starts at the user's first
-- ever transaction, so the clock starts at true subscription inception and the
-- duration is not left-truncated. Users who churn and later return contribute
-- their first spell (event = 1); their later spells are out of scope.
--
-- Event / censoring rule, with cutoff = last transaction date in the data:
--   * a later spell exists                       -> churned at spell-1 expiry
--   * no later spell, expiry + 30d <= cutoff     -> churned at spell-1 expiry
--       (we observed the full grace window elapse with no renewal)
--   * otherwise                                  -> right-censored at
--       least(expiry, cutoff). If expiry > cutoff the user is still paid up
--       and we censor at the cutoff; if expiry <= cutoff the grace window has
--       not finished by the cutoff, so the outcome is genuinely unknown and we
--       censor at the expiry rather than guessing.
-- This rule cannot produce a spell_end after the cutoff.
--
-- Cohort: accounts whose registration_init_time falls on or after the start of
-- the transaction window (2015-01-01). Such an account cannot have been
-- subscribed before the data begins, which rules out left truncation. Users
-- already subscribed on 2015-01-01 are excluded because their true start date
-- is unobservable.

-- ---------------------------------------------------------------------------
-- Parameters (single-row table so downstream SQL and Python read one source)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE analysis_params AS
SELECT
    DATE '2015-01-01' AS window_start,   -- first transaction_date in the data
    DATE '2017-03-31' AS cutoff,         -- last  transaction_date in the data
    30                AS grace_days,     -- KKBox churn definition
    DATE '2019-01-01' AS absurd_expiry;  -- expiries beyond this are junk

-- ---------------------------------------------------------------------------
-- Cleaned transaction log
-- ---------------------------------------------------------------------------
-- transactions and transactions_v2 overlap, so UNION (not UNION ALL) to
-- de-duplicate identical rows. Rows whose expiry date is unparseable or
-- absurd are dropped; the counts are reported by scripts/check_censoring.py.
CREATE OR REPLACE TABLE tx_clean AS
WITH raw_union AS (
    SELECT * FROM transactions
    UNION
    SELECT * FROM transactions_v2
),
cast_dates AS (
    SELECT
        msno,
        payment_method_id,
        payment_plan_days,
        plan_list_price,
        actual_amount_paid,
        is_auto_renew,
        is_cancel,
        TRY_CAST(strptime(CAST(transaction_date      AS VARCHAR), '%Y%m%d') AS DATE) AS tx_date,
        TRY_CAST(strptime(CAST(membership_expire_date AS VARCHAR), '%Y%m%d') AS DATE) AS expire_date
    FROM raw_union
)
SELECT c.*
FROM cast_dates c, analysis_params p
WHERE c.tx_date     IS NOT NULL
  AND c.expire_date IS NOT NULL
  AND c.tx_date     >= p.window_start
  AND c.tx_date     <= p.cutoff
  AND c.expire_date >= p.window_start
  AND c.expire_date <  p.absurd_expiry;

-- ---------------------------------------------------------------------------
-- Assign a spell id to every transaction
-- ---------------------------------------------------------------------------
-- Within a user, order chronologically; on a tie put cancellations last so the
-- running expiry reflects the cancellation. A transaction opens a new spell
-- when it lands more than grace_days after the previous transaction's expiry.
CREATE OR REPLACE TABLE tx_spelled AS
WITH ordered AS (
    SELECT
        t.*,
        lag(t.expire_date) OVER w AS prev_expire_date
    FROM tx_clean t
    WINDOW w AS (
        PARTITION BY t.msno
        ORDER BY t.tx_date, t.is_cancel, t.expire_date
    )
),
flagged AS (
    SELECT
        o.*,
        CASE
            WHEN o.prev_expire_date IS NULL THEN 1
            WHEN o.tx_date > o.prev_expire_date + p.grace_days THEN 1
            ELSE 0
        END AS starts_new_spell
    FROM ordered o, analysis_params p
)
SELECT
    f.*,
    sum(f.starts_new_spell) OVER (
        PARTITION BY f.msno
        ORDER BY f.tx_date, f.is_cancel, f.expire_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS spell_id
FROM flagged f;

-- ---------------------------------------------------------------------------
-- Collapse each user's first spell to one row, with covariates at spell start
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE spell_agg AS
WITH per_user AS (
    SELECT msno, max(spell_id) AS n_spells
    FROM tx_spelled
    GROUP BY msno
),
first_spell AS (
    SELECT
        msno,
        min(tx_date)  AS spell_start,
        count(*)      AS n_transactions,
        -- expiry of the last transaction in the spell, under the same ordering
        arg_max(expire_date, (tx_date, is_cancel, expire_date)) AS final_expiry,
        -- covariates measured at the first transaction of the spell
        arg_min(payment_method_id,  (tx_date, is_cancel, expire_date)) AS payment_method_id,
        arg_min(payment_plan_days,  (tx_date, is_cancel, expire_date)) AS payment_plan_days,
        arg_min(plan_list_price,    (tx_date, is_cancel, expire_date)) AS plan_list_price,
        arg_min(actual_amount_paid, (tx_date, is_cancel, expire_date)) AS actual_amount_paid,
        arg_min(is_auto_renew,      (tx_date, is_cancel, expire_date)) AS is_auto_renew
    FROM tx_spelled
    WHERE spell_id = 1
    GROUP BY msno
)
SELECT
    f.*,
    u.n_spells,
    (u.n_spells > 1) AS has_later_spell
FROM first_spell f
JOIN per_user u USING (msno);

-- ---------------------------------------------------------------------------
-- Final analysis table: one row per user, with outcome and covariates
-- ---------------------------------------------------------------------------
-- Kept deliberately permissive: implausible rows are FLAGGED here rather than
-- silently dropped, so scripts/check_censoring.py can count them before the
-- modelling cohort (is_analysable) is taken.
CREATE OR REPLACE TABLE spells AS
WITH resolved AS (
    SELECT
        s.msno,
        s.spell_start,
        s.final_expiry,
        s.n_transactions,
        s.n_spells,
        s.has_later_spell,
        s.payment_method_id,
        s.payment_plan_days,
        s.plan_list_price,
        s.actual_amount_paid,
        s.is_auto_renew,
        m.city,
        m.registered_via,
        m.bd            AS declared_age,
        m.gender,
        TRY_CAST(strptime(CAST(m.registration_init_time AS VARCHAR), '%Y%m%d') AS DATE) AS registration_date,
        p.cutoff,
        p.window_start,
        p.grace_days,
        -- churn observed?
        CASE
            WHEN s.has_later_spell AND s.final_expiry <= p.cutoff THEN 1
            WHEN NOT s.has_later_spell
                 AND s.final_expiry + p.grace_days <= p.cutoff     THEN 1
            ELSE 0
        END AS event,
        -- end of observation for this spell
        CASE
            WHEN s.has_later_spell AND s.final_expiry <= p.cutoff THEN s.final_expiry
            WHEN NOT s.has_later_spell
                 AND s.final_expiry + p.grace_days <= p.cutoff     THEN s.final_expiry
            ELSE least(s.final_expiry, p.cutoff)
        END AS spell_end
    FROM spell_agg s
    JOIN members m USING (msno)
    CROSS JOIN analysis_params p
)
SELECT
    r.*,
    datediff('day', r.spell_start, r.spell_end) AS duration_days,
    -- quality flags, reported before any filtering
    (r.registration_date IS NULL)                     AS flag_no_registration_date,
    (r.registration_date <  r.window_start)           AS flag_registered_before_window,
    (r.registration_date >  r.spell_start)            AS flag_registered_after_first_tx,
    (r.spell_end > r.cutoff)                          AS flag_end_after_cutoff,
    (datediff('day', r.spell_start, r.spell_end) < 0) AS flag_negative_duration,
    (datediff('day', r.spell_start, r.spell_end) = 0) AS flag_zero_duration,
    -- the modelling cohort
    (
        r.registration_date IS NOT NULL
        AND r.registration_date >= r.window_start
        AND r.registration_date <= r.spell_start
        AND r.spell_end <= r.cutoff
        AND datediff('day', r.spell_start, r.spell_end) > 0
    ) AS is_analysable
FROM resolved r;
