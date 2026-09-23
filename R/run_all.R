# run_all.R -- run the whole R analysis in order.
#
# Usage:  Rscript R/run_all.R
# Assumes the DuckDB layer has already been built:
#   python scripts/load_data.py && python scripts/build_spells.py

this_file_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  m <- grep("^--file=", args, value = TRUE)
  if (length(m)) return(dirname(normalizePath(sub("^--file=", "", m[1]))))
  of <- sys.frames()[[1]]$ofile
  if (!is.null(of)) return(dirname(normalizePath(of)))
  normalizePath(getwd())
}

R_DIR <- this_file_dir()
steps <- c("01_kaplan_meier.R", "02_cox_ph.R", "03_logistic_baseline.R")

for (s in steps) {
  message("\n", strrep("=", 70), "\n== ", s, "\n", strrep("=", 70))
  # A separate process per step: each script is self-contained and this keeps
  # one step's globals from leaking into the next.
  status <- system2("Rscript", shQuote(file.path(R_DIR, s)))
  if (status != 0) stop("Step failed: ", s, call. = FALSE)
}
message("\nAll steps complete. See results/")
