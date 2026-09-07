"""
Load the downloaded KKBox CSVs into a local DuckDB database.

Reads sql/00_load_raw.sql, runs each per-table block against
data/processed/kkbox.duckdb, and prints a row count per table.

Resilient by design: a block whose source CSV is missing is skipped with a
message rather than raising, so this can run after a partial download (for
example before user_logs.csv has been fetched).

Paths are resolved from this file's location, so it works from any CWD.

Usage:
    python scripts/load_data.py
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(HERE)
RAW_DIR = os.path.join(PROJECT_ROOT, "data", "raw")
PROCESSED_DIR = os.path.join(PROJECT_ROOT, "data", "processed")
SQL_FILE = os.path.join(PROJECT_ROOT, "sql", "00_load_raw.sql")
DB_PATH = os.path.join(PROCESSED_DIR, "kkbox.duckdb")

BLOCK_RE = re.compile(
    r"--\s*table:\s*(?P<table>\S+)\s*\n"
    r"--\s*file:\s*(?P<file>\S+)\s*\n"
    r"(?P<sql>.*?)(?=\n--\s*table:|\Z)",
    re.DOTALL,
)


def parse_blocks(sql_text):
    blocks = []
    for m in BLOCK_RE.finditer(sql_text):
        blocks.append((m.group("table"), m.group("file"), m.group("sql").strip()))
    return blocks


def find_csv(filename):
    """Locate `filename` under data/raw/, flat first then any sub-directory."""
    flat = os.path.join(RAW_DIR, filename)
    if os.path.exists(flat):
        return flat
    for root, _dirs, files in os.walk(RAW_DIR):
        if filename in files:
            return os.path.join(root, filename)
    return None


def main():
    if not os.path.exists(SQL_FILE):
        sys.exit(f"Missing SQL file: {SQL_FILE}")

    import duckdb

    os.makedirs(PROCESSED_DIR, exist_ok=True)
    blocks = parse_blocks(open(SQL_FILE).read())
    if not blocks:
        sys.exit(f"No '-- table:' blocks found in {SQL_FILE}")

    print("=" * 70)
    print("Loading KKBox CSVs into DuckDB")
    print("=" * 70)
    print(f"Database: {DB_PATH}")
    print(f"Raw dir:  {RAW_DIR}\n")

    con = duckdb.connect(DB_PATH)

    loaded, skipped = [], []
    for table, filename, stmt in blocks:
        csv_path = find_csv(filename)
        if csv_path is None:
            print(f"  skip  {table:16s} - {filename} not found under data/raw/")
            skipped.append(table)
            continue

        print(f"  load  {table:16s} <- {os.path.relpath(csv_path, RAW_DIR)}")
        safe_path = csv_path.replace("'", "''")
        con.execute(stmt.replace(f":raw_dir/{filename}", safe_path))
        loaded.append(table)

    print("\n" + "-" * 70)
    print("Row counts")
    print("-" * 70)
    if not loaded:
        print("  (nothing loaded - run scripts/download_data.py first)")
    for table in loaded:
        n = con.execute(f'SELECT count(*) FROM "{table}"').fetchone()[0]
        print(f"  {table:16s} {n:>14,d}")
    if skipped:
        print("\n  skipped (source CSV missing): " + ", ".join(skipped))

    con.close()
    print("\nDone. DB written to data/processed/kkbox.duckdb")


if __name__ == "__main__":
    main()
