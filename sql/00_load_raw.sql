-- 00_load_raw.sql
-- Canonical DDL for loading the KKBox raw CSVs into DuckDB.
--
-- scripts/load_data.py executes each block below against
-- data/processed/kkbox.duckdb, replacing :raw_dir with the project's
-- data/raw/ path and skipping any block whose `-- file:` is not present
-- on disk (the large user_logs tables are often not downloaded yet).
--
-- Dates in this dataset are integers in YYYYMMDD form (e.g. 20170131).
-- They are loaded as-is here; the spell-building layer (10_build_spells.sql,
-- not yet written) will cast them to DATE.

-- table: members
-- file: members_v3.csv
CREATE OR REPLACE TABLE members AS
SELECT *
FROM read_csv_auto(':raw_dir/members_v3.csv', header = true, sample_size = -1);

-- table: transactions
-- file: transactions.csv
CREATE OR REPLACE TABLE transactions AS
SELECT *
FROM read_csv_auto(':raw_dir/transactions.csv', header = true, sample_size = -1);

-- table: transactions_v2
-- file: transactions_v2.csv
CREATE OR REPLACE TABLE transactions_v2 AS
SELECT *
FROM read_csv_auto(':raw_dir/transactions_v2.csv', header = true, sample_size = -1);

-- table: train
-- file: train.csv
CREATE OR REPLACE TABLE train AS
SELECT *
FROM read_csv_auto(':raw_dir/train.csv', header = true, sample_size = -1);

-- table: train_v2
-- file: train_v2.csv
CREATE OR REPLACE TABLE train_v2 AS
SELECT *
FROM read_csv_auto(':raw_dir/train_v2.csv', header = true, sample_size = -1);

-- table: user_logs
-- file: user_logs.csv
CREATE OR REPLACE TABLE user_logs AS
SELECT *
FROM read_csv_auto(':raw_dir/user_logs.csv', header = true, sample_size = -1);

-- table: user_logs_v2
-- file: user_logs_v2.csv
CREATE OR REPLACE TABLE user_logs_v2 AS
SELECT *
FROM read_csv_auto(':raw_dir/user_logs_v2.csv', header = true, sample_size = -1);
