"""
Sanity-check the spells table before any survival model is fitted.

Reports the data funnel, the event/censoring split, the observation cutoff and
the duration distribution, and flags implausible rows (negative durations,
spells ending after the cutoff, zero-duration spells).

Writes the same report to results/01_censoring_report.txt.

Paths are resolved from this file's location, so it works from any CWD.

Usage:
    python scripts/check_censoring.py
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(HERE)
DB_PATH = os.path.join(PROJECT_ROOT, "data", "processed", "kkbox.duckdb")
RESULTS_DIR = os.path.join(PROJECT_ROOT, "results")
REPORT_OUT = os.path.join(RESULTS_DIR, "01_censoring_report.txt")

_lines = []


def say(text=""):
    print(text)
    _lines.append(text)


def rule(title=None):
    say("-" * 70)
    if title:
        say(title)
        say("-" * 70)


def main():
    if not os.path.exists(DB_PATH):
        sys.exit(f"Missing database: {DB_PATH}")

    import duckdb

    con = duckdb.connect(DB_PATH, read_only=True)
    con.execute("PRAGMA disable_progress_bar")
    one = lambda q: con.execute(q).fetchone()
    rows = lambda q: con.execute(q).fetchall()

    if not con.execute(
        "SELECT count(*) FROM information_schema.tables WHERE table_name = 'spells'"
    ).fetchone()[0]:
        sys.exit("No 'spells' table. Run scripts/build_spells.py first.")

    say("=" * 70)
    say("CENSORING SANITY CHECK")
    say("=" * 70)

    # ---------------------------------------------------------------- params
    ws, cutoff, grace, absurd = one("SELECT * FROM analysis_params")
    rule("Observation window")
    say(f"  window start (first transaction_date in data) : {ws}")
    say(f"  observation cutoff (last transaction_date)    : {cutoff}")
    say(f"  churn grace period                            : {grace} days")
    say(f"  expiry dates at/after this treated as junk    : {absurd}")

    # ----------------------------------------------------------- raw funnel
    raw_tx = one("SELECT count(*) FROM (SELECT * FROM transactions UNION SELECT * FROM transactions_v2)")[0]
    clean_tx = one("SELECT count(*) FROM tx_clean")[0]
    rule("Data funnel")
    say(f"  transactions (raw, v1 + v2)                   : {one('SELECT count(*) FROM transactions')[0] + one('SELECT count(*) FROM transactions_v2')[0]:>12,d}")
    say(f"  after de-duplicating v1/v2 overlap            : {raw_tx:>12,d}")
    say(f"  after dropping unparseable/out-of-range dates : {clean_tx:>12,d}  ({raw_tx - clean_tx:,d} dropped)")
    say(f"  users with >=1 clean transaction              : {one('SELECT count(*) FROM spell_agg')[0]:>12,d}")
    say(f"  ... with a members row (covariates available) : {one('SELECT count(*) FROM spells')[0]:>12,d}")

    total = one("SELECT count(*) FROM spells")[0]
    for col, label in [
        ("flag_no_registration_date", "no registration date"),
        ("flag_registered_before_window", "registered before 2015-01-01 (left-truncated)"),
        ("flag_registered_after_first_tx", "registered after first transaction"),
        ("flag_negative_duration", "negative duration"),
        ("flag_zero_duration", "zero duration"),
        ("flag_end_after_cutoff", "spell_end after cutoff"),
    ]:
        n = one(f"SELECT count(*) FROM spells WHERE {col}")[0]
        say(f"  excluded - {label:<45s}: {n:>12,d}")

    n_ok = one("SELECT count(*) FROM spells WHERE is_analysable")[0]
    say(f"  MODELLING COHORT                              : {n_ok:>12,d}")

    # ------------------------------------------------------ implausibility
    rule("Implausible-row checks (on the modelling cohort)")
    checks = [
        ("duration_days < 0", "negative durations"),
        ("duration_days = 0", "zero durations"),
        ("spell_end > cutoff", "spells ending after the cutoff"),
        ("spell_start > spell_end", "start after end"),
        ("spell_start < window_start", "start before window"),
        ("event NOT IN (0, 1)", "event not 0/1"),
        ("event = 1 AND spell_end > cutoff", "churn recorded after cutoff"),
    ]
    worst = 0
    for cond, label in checks:
        n = one(f"SELECT count(*) FROM spells WHERE is_analysable AND ({cond})")[0]
        worst = max(worst, n)
        say(f"  {'OK   ' if n == 0 else 'FAIL '} {label:<45s}: {n:>12,d}")

    # ------------------------------------------------------ event/censoring
    rule("Events vs censoring (modelling cohort)")
    n_ev, n_cens = one(
        "SELECT sum(event), sum(1 - event) FROM spells WHERE is_analysable"
    )
    say(f"  total spells                 : {n_ok:>12,d}")
    say(f"  events (churned, event = 1)  : {n_ev:>12,d}  ({100 * n_ev / n_ok:5.2f}%)")
    say(f"  censored (active, event = 0) : {n_cens:>12,d}  ({100 * n_cens / n_ok:5.2f}%)")
    say(f"  CENSORING RATE               : {100 * n_cens / n_ok:11.2f}%")

    say("")
    say("  Censoring reason breakdown:")
    for reason, n in rows(
        """
        SELECT CASE
                 WHEN final_expiry > cutoff THEN 'still paid up past cutoff'
                 ELSE 'grace window unfinished at cutoff'
               END AS reason,
               count(*)
        FROM spells WHERE is_analysable AND event = 0
        GROUP BY 1 ORDER BY 2 DESC
        """
    ):
        say(f"    {reason:<40s} {n:>12,d}")

    # ------------------------------------------------------------ durations
    rule("Duration distribution (days, modelling cohort)")
    stats = one(
        """
        SELECT min(duration_days), max(duration_days),
               avg(duration_days), median(duration_days),
               quantile_cont(duration_days, 0.25), quantile_cont(duration_days, 0.75),
               quantile_cont(duration_days, 0.90), quantile_cont(duration_days, 0.99)
        FROM spells WHERE is_analysable
        """
    )
    labels = ["min", "max", "mean", "median", "p25", "p75", "p90", "p99"]
    for label, v in zip(labels, stats):
        say(f"  {label:<8s} {v:>10.1f}")

    say("")
    say("  By outcome:")
    say(f"    {'group':<12s} {'n':>10s} {'median':>9s} {'mean':>9s} {'max':>7s}")
    for grp, n, med, mean, mx in rows(
        """
        SELECT CASE WHEN event = 1 THEN 'churned' ELSE 'censored' END,
               count(*), median(duration_days), avg(duration_days), max(duration_days)
        FROM spells WHERE is_analysable GROUP BY 1 ORDER BY 1
        """
    ):
        say(f"    {grp:<12s} {n:>10,d} {med:>9.1f} {mean:>9.1f} {mx:>7.0f}")

    say("")
    say("  Histogram (days):")
    for lo, hi, n in rows(
        """
        WITH b AS (
          SELECT CASE
            WHEN duration_days <=   30 THEN 0   WHEN duration_days <=   60 THEN 30
            WHEN duration_days <=   90 THEN 60  WHEN duration_days <=  180 THEN 90
            WHEN duration_days <=  365 THEN 180 WHEN duration_days <=  547 THEN 365
            ELSE 547 END AS lo,
            CASE
            WHEN duration_days <=   30 THEN 30  WHEN duration_days <=   60 THEN 60
            WHEN duration_days <=   90 THEN 90  WHEN duration_days <=  180 THEN 180
            WHEN duration_days <=  365 THEN 365 WHEN duration_days <=  547 THEN 547
            ELSE 9999 END AS hi
          FROM spells WHERE is_analysable
        )
        SELECT lo, hi, count(*) FROM b GROUP BY 1, 2 ORDER BY 1
        """
    ):
        bar = "#" * int(60 * n / n_ok)
        rng = f"{lo:>4d}-{hi:<4d}" if hi != 9999 else f"{lo:>4d}+    "
        say(f"    {rng} {n:>9,d} {100 * n / n_ok:5.1f}%  {bar}")

    # ------------------------------------------------------------ covariates
    rule("Key covariate distributions (modelling cohort)")
    say("  auto-renew at spell start:")
    for v, n in rows(
        "SELECT is_auto_renew, count(*) FROM spells WHERE is_analysable GROUP BY 1 ORDER BY 1"
    ):
        say(f"    is_auto_renew = {v}: {n:>10,d}  ({100 * n / n_ok:5.2f}%)")
    say("  top payment methods:")
    for v, n, ev in rows(
        """SELECT payment_method_id, count(*), avg(event) FROM spells
           WHERE is_analysable GROUP BY 1 ORDER BY 2 DESC LIMIT 8"""
    ):
        say(f"    method {v:>3d}: {n:>10,d}  ({100 * n / n_ok:5.2f}%)  churn {100 * ev:5.1f}%")
    say("  top plan lengths (days):")
    for v, n, ev in rows(
        """SELECT payment_plan_days, count(*), avg(event) FROM spells
           WHERE is_analysable GROUP BY 1 ORDER BY 2 DESC LIMIT 8"""
    ):
        say(f"    plan {v:>4d}d: {n:>10,d}  ({100 * n / n_ok:5.2f}%)  churn {100 * ev:5.1f}%")

    rule()
    say("VERDICT: " + ("PASS - no implausible rows in the modelling cohort."
                       if worst == 0 else
                       "FAIL - implausible rows remain; do not model."))
    rule()

    os.makedirs(RESULTS_DIR, exist_ok=True)
    with open(REPORT_OUT, "w") as fh:
        fh.write("\n".join(_lines) + "\n")
    print(f"\nReport written to {REPORT_OUT}")
    con.close()
    return 0 if worst == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
