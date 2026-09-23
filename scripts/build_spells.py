"""
Build the per-user subscription spells table in DuckDB.

Executes sql/10_build_spells.sql against data/processed/kkbox.duckdb, then
exports the modelling cohort to data/processed/spells.csv for the R layer.

Paths are resolved from this file's location, so it works from any CWD.

Usage:
    python scripts/build_spells.py
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(HERE)
PROCESSED_DIR = os.path.join(PROJECT_ROOT, "data", "processed")
SQL_FILE = os.path.join(PROJECT_ROOT, "sql", "10_build_spells.sql")
DB_PATH = os.path.join(PROCESSED_DIR, "kkbox.duckdb")
CSV_OUT = os.path.join(PROCESSED_DIR, "spells.csv")

# Columns the R layer needs. Deliberately excludes msno: the analysis is
# aggregate and the user id is not a covariate.
EXPORT_COLS = [
    "duration_days",
    "event",
    "is_auto_renew",
    "payment_method_id",
    "payment_plan_days",
    "plan_list_price",
    "actual_amount_paid",
    "city",
    "registered_via",
    "n_transactions",
    "spell_start",
    "spell_end",
    "registration_date",
]


def main():
    for path, what in ((SQL_FILE, "SQL file"), (DB_PATH, "database")):
        if not os.path.exists(path):
            sys.exit(f"Missing {what}: {path}")

    import duckdb

    print("=" * 70)
    print("Building subscription spells")
    print("=" * 70)
    print(f"Database: {DB_PATH}")
    print(f"SQL:      {SQL_FILE}\n")

    con = duckdb.connect(DB_PATH)
    con.execute("PRAGMA disable_progress_bar")

    print("Running sql/10_build_spells.sql ...")
    con.execute(open(SQL_FILE).read())

    for table in ("tx_clean", "tx_spelled", "spell_agg", "spells"):
        n = con.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
        print(f"  {table:12s} {n:>14,d} rows")

    n_analysable = con.execute(
        "SELECT count(*) FROM spells WHERE is_analysable"
    ).fetchone()[0]
    print(f"\n  modelling cohort (is_analysable): {n_analysable:,d}")

    cols = ", ".join(EXPORT_COLS)
    con.execute(
        f"COPY (SELECT {cols} FROM spells WHERE is_analysable) "
        f"TO '{CSV_OUT}' (HEADER, DELIMITER ',')"
    )
    size_mb = os.path.getsize(CSV_OUT) / 1e6
    print(f"\nExported -> {CSV_OUT} ({size_mb:.1f} MB)")

    con.close()
    print("\nDone. Next: python scripts/check_censoring.py")


if __name__ == "__main__":
    main()
