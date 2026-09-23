# 00_setup.R -- shared paths, data loading and factor preparation.
#
# Sourced by every other script in R/. Resolves all paths from this file's
# own location, so the scripts run correctly from any working directory.

this_file_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  m <- grep("^--file=", args, value = TRUE)
  if (length(m)) return(dirname(normalizePath(sub("^--file=", "", m[1]))))
  of <- sys.frames()[[1]]$ofile
  if (!is.null(of)) return(dirname(normalizePath(of)))
  normalizePath(getwd())
}

R_DIR        <- this_file_dir()
PROJECT_ROOT <- dirname(R_DIR)
DATA_DIR     <- file.path(PROJECT_ROOT, "data", "processed")
RESULTS_DIR  <- file.path(PROJECT_ROOT, "results")
SPELLS_CSV   <- file.path(DATA_DIR, "spells.csv")

dir.create(RESULTS_DIR, showWarnings = FALSE, recursive = TRUE)

suppressPackageStartupMessages({
  library(survival)
  library(survminer)
  library(ggplot2)
})

# Reproducible subsampling wherever a full-data fit is impractical.
SEED <- 20170331

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
save_png <- function(name, plot_obj, width = 9, height = 6, dpi = 130) {
  path <- file.path(RESULTS_DIR, name)
  if (inherits(plot_obj, "ggsurvplot")) {
    # ggsurvplot is a list of grobs; print() assembles it onto a device
    png(path, width = width * dpi, height = height * dpi, res = dpi)
    print(plot_obj)
    dev.off()
  } else if (inherits(plot_obj, "ggplot")) {
    ggsave(path, plot_obj, width = width, height = height, dpi = dpi)
  } else if (is.function(plot_obj)) {
    png(path, width = width * dpi, height = height * dpi, res = dpi)
    plot_obj()
    dev.off()
  } else {
    stop("save_png: don't know how to render object of class ",
         paste(class(plot_obj), collapse = "/"))
  }
  message("  saved ", file.path("results", name))
  invisible(path)
}

# A tee: print to console and collect for a results/*.txt transcript.
new_report <- function(filename) {
  lines <- character(0)
  path <- file.path(RESULTS_DIR, filename)
  list(
    say = function(...) {
      txt <- paste0(...)
      cat(txt, "\n", sep = "")
      lines <<- c(lines, txt)
    },
    obj = function(x) {
      out <- capture.output(print(x))
      cat(out, sep = "\n"); cat("\n")
      lines <<- c(lines, out, "")
    },
    rule = function(title = NULL) {
      bar <- strrep("-", 74)
      cat(bar, "\n"); lines <<- c(lines, bar)
      if (!is.null(title)) {
        cat(title, "\n", bar, "\n", sep = "")
        lines <<- c(lines, title, bar)
      }
    },
    close = function() {
      writeLines(lines, path)
      message("  wrote ", file.path("results", filename))
    }
  )
}

# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------
# Collapse a factor to its `n` most frequent levels, everything else "Other".
lump_factor <- function(x, n, other = "Other") {
  tab <- sort(table(x), decreasing = TRUE)
  keep <- names(tab)[seq_len(min(n, length(tab)))]
  out <- ifelse(as.character(x) %in% keep, as.character(x), other)
  lv <- c(keep, if (any(out == other)) other)
  factor(out, levels = lv)
}

load_spells <- function() {
  if (!file.exists(SPELLS_CSV)) {
    stop("Missing ", SPELLS_CSV, "\n",
         "Run: python scripts/build_spells.py", call. = FALSE)
  }
  message("Reading ", SPELLS_CSV, " ...")
  df <- read.csv(
    SPELLS_CSV,
    colClasses = c(
      duration_days = "integer", event = "integer", is_auto_renew = "integer",
      payment_method_id = "integer", payment_plan_days = "integer",
      plan_list_price = "integer", actual_amount_paid = "integer",
      city = "integer", registered_via = "integer", n_transactions = "integer",
      spell_start = "Date", spell_end = "Date", registration_date = "Date"
    )
  )

  # --- outcome -------------------------------------------------------------
  stopifnot(all(df$duration_days > 0), all(df$event %in% c(0L, 1L)))

  # --- auto-renew ----------------------------------------------------------
  # Reference = "Yes", so the reported HR reads "auto-renew OFF multiplies the
  # churn hazard by X", which is the actionable direction.
  df$auto_renew <- factor(ifelse(df$is_auto_renew == 1L, "Yes", "No"),
                          levels = c("Yes", "No"))
  # Plain 0/1 indicator of the same thing. Needed for the time-varying model:
  # a factor that appears only inside an interaction gets full dummy coding,
  # which silently reports the "Yes" effect while every other covariate is
  # reported against its reference. A numeric indicator has one unambiguous
  # coefficient, directly comparable to the auto_renewNo HR elsewhere.
  df$autorenew_off <- as.integer(df$is_auto_renew == 0L)

  # --- payment method ------------------------------------------------------
  # Raw ids are opaque; keep the 6 most common and label them PM<id>.
  pm <- lump_factor(factor(df$payment_method_id), 6)
  levels(pm) <- ifelse(levels(pm) == "Other", "Other", paste0("PM", levels(pm)))
  df$payment_method <- relevel(pm, ref = names(sort(table(pm), decreasing = TRUE))[1])

  # --- plan length ---------------------------------------------------------
  # Reference = "8-31 days", the modal monthly plan.
  df$plan_length <- cut(
    df$payment_plan_days,
    breaks = c(-1, 0, 7, 31, 100, 200, Inf),
    labels = c("0 days", "1-7 days", "8-31 days", "32-100 days",
               "101-200 days", "200+ days")
  )
  df$plan_length <- relevel(df$plan_length, ref = "8-31 days")

  # --- city / registration channel ----------------------------------------
  df$city_grp <- lump_factor(factor(paste0("city", df$city)), 5)
  df$city_grp <- relevel(df$city_grp,
                         ref = names(sort(table(df$city_grp), decreasing = TRUE))[1])

  df$reg_channel <- lump_factor(factor(paste0("via", df$registered_via)), 4)
  df$reg_channel <- relevel(df$reg_channel,
                            ref = names(sort(table(df$reg_channel), decreasing = TRUE))[1])

  message(sprintf("  %s spells, %s events (%.2f%% censored)",
                  format(nrow(df), big.mark = ","),
                  format(sum(df$event), big.mark = ","),
                  100 * mean(df$event == 0)))
  df
}

# The covariate set used by both the Cox model and the logistic baseline,
# so the comparison in 03_logistic_baseline.R is like-for-like.
MODEL_COVARIATES <- c("auto_renew", "payment_method", "plan_length",
                      "city_grp", "reg_channel")

model_formula <- function(lhs) {
  as.formula(paste(lhs, "~", paste(MODEL_COVARIATES, collapse = " + ")))
}
