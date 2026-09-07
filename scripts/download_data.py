"""
Download the WSDM - KKBox Churn Prediction Challenge dataset from Kaggle
into data/raw/ and extract it.

The competition ships each table as a `.7z` archive (some inside a
`churn_comp_refresh/` folder in the refreshed data). This script downloads a
prioritised subset, unwraps any `.zip` Kaggle adds around single files, then
extracts every `.7z` with py7zr.

Priority order (transactions + members first; user_logs is optional and huge):

  1. members_v3.csv         - one row per user, static profile
  2. transactions.csv       - subscription transactions (the churn signal)
  3. train.csv / train_v2   - labelled churn outcomes
  4. transactions_v2.csv    - extra transactions from the refreshed data
  5. sample_submission_*    - id lists
  6. user_logs*             - daily listening logs; only with --with-user-logs

Requires ~/.kaggle/kaggle.json and acceptance of the competition rules at
https://www.kaggle.com/c/kkbox-churn-prediction-challenge/rules
(a 403 on download means the rules have not been accepted yet).

Usage:
    python scripts/download_data.py                 # core tables
    python scripts/download_data.py --with-user-logs # also the large logs
"""

import os
import shutil
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(HERE)
RAW_DIR = os.path.join(PROJECT_ROOT, "data", "raw")

COMPETITION = "kkbox-churn-prediction-challenge"

# Substrings of the files we want, most important first. user_logs is gated.
CORE_PATTERNS = [
    "members",
    "transactions",
    "train",
    "sample_submission",
]
USER_LOG_PATTERNS = ["user_logs"]

RULES_URL = "https://www.kaggle.com/c/kkbox-churn-prediction-challenge/rules"


def authenticate():
    from kaggle.api.kaggle_api_extended import KaggleApi

    api = KaggleApi()
    api.authenticate()
    return api


def is_permission_error(exc):
    text = str(exc).lower()
    return "403" in text or "forbidden" in text or "accept" in text and "rules" in text


def die_needs_rules():
    print("\n" + "=" * 70)
    print("403 from Kaggle - the competition rules have not been accepted.")
    print("Open this page, click 'I Understand and Accept', then re-run:")
    print(f"   {RULES_URL}")
    print("=" * 70)
    sys.exit(1)


def pick_files(api, want_user_logs):
    patterns = CORE_PATTERNS + (USER_LOG_PATTERNS if want_user_logs else [])
    try:
        listing = api.competition_list_files(COMPETITION).files
    except Exception as exc:  # noqa: BLE001 - want a friendly message for any failure
        if is_permission_error(exc):
            die_needs_rules()
        raise

    names = [f.name for f in listing]
    selected = []
    for pat in patterns:
        for name in names:
            if pat in name.lower() and name not in selected:
                selected.append(name)
    skipped = [n for n in names if n not in selected]
    return selected, skipped


def download_one(api, name):
    """Download a single competition file; return the local path it landed at."""
    target_flat = os.path.join(RAW_DIR, os.path.basename(name))
    if os.path.exists(target_flat):
        print(f"   already downloaded: {os.path.basename(name)}")
        return target_flat

    try:
        api.competition_download_file(COMPETITION, name, path=RAW_DIR, quiet=False)
    except Exception as exc:  # noqa: BLE001
        if is_permission_error(exc):
            die_needs_rules()
        raise

    # Kaggle may deliver "<name>" or "<name>.zip", and may keep the subdir.
    candidates = [
        os.path.join(RAW_DIR, name),
        os.path.join(RAW_DIR, name + ".zip"),
        os.path.join(RAW_DIR, os.path.basename(name)),
        os.path.join(RAW_DIR, os.path.basename(name) + ".zip"),
    ]
    for path in candidates:
        if os.path.exists(path):
            return path
    raise FileNotFoundError(f"Downloaded {name} but cannot find it under {RAW_DIR}")


def unwrap_zip(path):
    """If `path` is a .zip, extract it into RAW_DIR and return the member paths."""
    if not path.endswith(".zip"):
        return [path]
    extracted = []
    with zipfile.ZipFile(path) as zf:
        for member in zf.namelist():
            zf.extract(member, RAW_DIR)
            extracted.append(os.path.join(RAW_DIR, member))
    os.remove(path)
    return extracted


def extract_7z_tree():
    """Extract every .7z under RAW_DIR (recursively) next to itself."""
    import py7zr

    archives = []
    for root, _dirs, files in os.walk(RAW_DIR):
        for fn in files:
            if fn.endswith(".7z"):
                archives.append(os.path.join(root, fn))

    for archive in sorted(archives):
        out_dir = os.path.dirname(archive)
        with py7zr.SevenZipFile(archive, "r") as z:
            members = z.getnames()
        already = all(os.path.exists(os.path.join(out_dir, m)) for m in members) and members
        if already:
            print(f"   already extracted: {os.path.basename(archive)}")
            continue
        print(f"   extracting {os.path.basename(archive)} ...")
        with py7zr.SevenZipFile(archive, "r") as z:
            z.extractall(path=out_dir)


def flatten_csvs():
    """Move any extracted CSV out of sub-folders up to data/raw/.

    Some archives (the refreshed `*_v2` files) contain an internal
    `data/churn_comp_refresh/` path, so py7zr writes them into a nested
    directory. Bring them up so downstream code can assume a flat data/raw/.
    """
    for root, _dirs, files in os.walk(RAW_DIR):
        if os.path.abspath(root) == os.path.abspath(RAW_DIR):
            continue
        for fn in files:
            if not fn.endswith(".csv"):
                continue
            src = os.path.join(root, fn)
            dst = os.path.join(RAW_DIR, fn)
            if os.path.exists(dst):
                print(f"   flatten: {fn} already at data/raw/, leaving nested copy")
                continue
            print(f"   flatten: {os.path.relpath(src, RAW_DIR)} -> {fn}")
            shutil.move(src, dst)

    # drop now-empty sub-directories
    for root, dirs, files in os.walk(RAW_DIR, topdown=False):
        if os.path.abspath(root) == os.path.abspath(RAW_DIR):
            continue
        if not os.listdir(root):
            os.rmdir(root)


def summarise():
    print("\nCSV files now in data/raw/:")
    found = []
    for root, _dirs, files in os.walk(RAW_DIR):
        for fn in files:
            if fn.endswith(".csv"):
                p = os.path.join(root, fn)
                size_mb = os.path.getsize(p) / (1024 * 1024)
                rel = os.path.relpath(p, RAW_DIR)
                found.append((rel, size_mb))
    if not found:
        print("   (none)")
    for rel, size_mb in sorted(found):
        print(f"   {rel:40s} {size_mb:10.1f} MB")


def main():
    want_user_logs = "--with-user-logs" in sys.argv[1:]
    os.makedirs(RAW_DIR, exist_ok=True)

    print("=" * 70)
    print("KKBox Churn Prediction Challenge - data download")
    print("=" * 70)
    print(f"Target: {RAW_DIR}")
    print(f"user_logs included: {want_user_logs}")

    api = authenticate()
    selected, skipped = pick_files(api, want_user_logs)

    print("\nWill download:")
    for name in selected:
        print(f"   + {name}")
    if skipped:
        print("Skipping (not needed for the first pass):")
        for name in skipped:
            print(f"   - {name}")

    downloaded = []
    for name in selected:
        for path in unwrap_zip(download_one(api, name)):
            downloaded.append(path)

    print("\nExtracting .7z archives ...")
    extract_7z_tree()
    flatten_csvs()

    summarise()

    print("\n" + "=" * 70)
    print("Download complete.")
    print("Next: python scripts/load_data.py")
    print("=" * 70)


if __name__ == "__main__":
    main()
