# subscription-survival-analysis

Modelling music-subscription churn as a **time-to-event** problem using the
KKBox (WSDM Churn Prediction Challenge) dataset.

## Goal

Estimate how long a KKBox subscriber stays subscribed, and which factors make
churn happen sooner or later. The outcome of interest is the *time from
subscription start to churn*, not simply whether a user churned inside a fixed
window.

## Why survival analysis and not binary classification

The obvious framing is "predict churn (yes/no) in month N". That throws away
most of the information in the data:

- **Right-censoring.** At the end of the observation window, most users are
  still subscribed. Their true lifetime is unknown; we only know it is *at
  least* as long as observed so far. A classifier has to either drop these
  users or mislabel them as "not churned", both of which bias the result.
  Survival models use censored rows correctly: they contribute "survived at
  least this long" information.
- **Time is the thing we care about.** "Will they churn?" is less useful than
  "when?". Survival analysis estimates the full survival curve S(t), so we can
  read off median lifetime, 6-month retention, hazard over time, etc.
- **The hazard is not constant.** Churn risk in this dataset spikes around
  contract renewal dates and is elevated for brand-new users. A single
  fixed-window label cannot express that; the hazard function can.
- **Covariate effects are interpretable.** A Cox model gives a hazard ratio
  per covariate ("auto-renew off multiplies churn hazard by X"), which is
  more actionable than a classifier's feature importance.

Binary classification answers a narrower question and needs an arbitrary
horizon and arbitrary handling of still-active users. Survival analysis is
the native framing for "time until an event that may not have happened yet".

## Planned pipeline

### 1. SQL layer (DuckDB) - build subscription spells

From the raw `transactions` table, construct one row per user subscription
*spell*:

| column | meaning |
|--------|---------|
| `msno` | user id |
| `spell_start` | date the subscription period began |
| `spell_end` | date of churn, or the observation cutoff if still active |
| `event` | 1 if the user churned (gap > 30 days with no renewal), 0 if censored |
| covariates | plan price, payment method, auto-renew flag, city, registered_via, tenure at spell start, ... |

Churn is defined the KKBox way: no valid transaction within 30 days of the
current membership expiry. Users active at the observation cutoff are
right-censored at that date.

### 2. R layer - survival modelling

- **Kaplan-Meier** estimates of S(t) overall and by subgroup (payment method,
  auto-renew, plan length, acquisition channel).
- **Log-rank tests** for whether those subgroup curves differ.
- **Cox Proportional Hazards** for the multivariable covariate effects, with
  hazard ratios and confidence intervals.
- **Schoenfeld residual test** (`cox.zph`) plus scaled-residual plots to check
  the proportional-hazards assumption; stratify or add time-interaction terms
  for any covariate that fails.

## Repository structure

```
subscription-survival-analysis/
├── data/
│   ├── raw/              raw Kaggle CSVs               (gitignored)
│   └── processed/        kkbox.duckdb                  (gitignored)
├── sql/
│   └── 00_load_raw.sql   load raw CSVs into DuckDB
├── scripts/
│   ├── download_data.py  pull + extract the Kaggle dataset
│   └── load_data.py      run the SQL loader, print row counts
├── R/                    survival analysis (not started)
├── results/              figures / tables (not started)
├── requirements.txt      pinned Python deps
└── .gitignore
```

## Status

| Stage | State |
|-------|-------|
| Project scaffold, venv, dependencies | done |
| Kaggle download script (`scripts/download_data.py`) | done, run |
| Raw data downloaded (members, transactions, transactions_v2, train, train_v2) | done |
| `user_logs` download | not done (optional, ~30 GB uncompressed) |
| DuckDB raw load (`sql/00_load_raw.sql`, `scripts/load_data.py`) | done |
| Spell-building SQL (`sql/10_build_spells.sql`) | not started |
| R: Kaplan-Meier / log-rank | not started |
| R: Cox PH + Schoenfeld check | not started |

Nothing in `R/` or `results/` exists yet. The Python/SQL side loads the raw
tables into DuckDB and is verified by row counts; the survival modelling is
still to be written.

## Setup

### 1. Kaggle API token

1. Log in to Kaggle, go to **Account → Settings → API → Create New Token**.
   This downloads `kaggle.json`.
2. Move it into place and lock down the permissions:
   ```bash
   mkdir -p ~/.kaggle
   mv ~/Downloads/kaggle.json ~/.kaggle/kaggle.json
   chmod 600 ~/.kaggle/kaggle.json
   ```
3. Accept the competition rules (required, or the download 403s):
   <https://www.kaggle.com/c/kkbox-churn-prediction-challenge/rules>

`kaggle.json` is gitignored and must never be committed.

### 2. Python environment

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### 3. Download and load the data

```bash
python scripts/download_data.py            # core tables (~1.3 GB download)
python scripts/download_data.py --with-user-logs   # optional, very large
python scripts/load_data.py                # -> data/processed/kkbox.duckdb
```

`load_data.py` skips any table whose CSV is missing, so it is safe to run
after a partial download.

### 4. R (once the R layer exists)

The analysis will use `survival`, `survminer`, and `ggplot2`. An
`renv.lock` / setup script will be added with that code.

## Data source

WSDM - KKBox's Churn Prediction Challenge,
<https://www.kaggle.com/c/kkbox-churn-prediction-challenge>. Data is subject
to the competition rules and is not redistributed in this repo.
