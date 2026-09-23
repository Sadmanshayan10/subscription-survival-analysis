# 01_kaplan_meier.R -- Kaplan-Meier survival curves and log-rank tests.
#
#   (a) overall survival, with median survival time and 95% CI
#   (b) stratified by auto-renew status and by payment method, each with a
#       log-rank test
#
# Outputs: results/02_kaplan_meier.txt
#          results/km_overall.png, km_by_autorenew.png, km_by_payment_method.png

this_file_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  m <- grep("^--file=", args, value = TRUE)
  if (length(m)) return(dirname(normalizePath(sub("^--file=", "", m[1]))))
  of <- sys.frames()[[1]]$ofile
  if (!is.null(of)) return(dirname(normalizePath(of)))
  normalizePath(getwd())
}
source(file.path(this_file_dir(), "00_setup.R"))

df <- load_spells()
rep <- new_report("02_kaplan_meier.txt")

rep$rule("KAPLAN-MEIER SURVIVAL ANALYSIS")
rep$say(sprintf("Spells: %s   Events: %s   Censored: %s (%.2f%%)",
                format(nrow(df), big.mark = ","),
                format(sum(df$event), big.mark = ","),
                format(sum(df$event == 0), big.mark = ","),
                100 * mean(df$event == 0)))
rep$say("Time origin: first subscription transaction. Time unit: days.")
rep$say("")

# ---------------------------------------------------------------------------
# (a) Overall survival
# ---------------------------------------------------------------------------
rep$rule("(a) Overall survival")
fit_all <- survfit(Surv(duration_days, event) ~ 1, data = df)
rep$obj(fit_all)

med <- summary(fit_all)$table
rep$say(sprintf("Median survival: %.0f days (95%% CI %.0f - %.0f)",
                med[["median"]], med[["0.95LCL"]], med[["0.95UCL"]]))

# Survival probability at a few reference horizons.
horizons <- c(30, 60, 90, 180, 365, 547)
sm <- summary(fit_all, times = horizons)
rep$say("")
rep$say("Survival probability at fixed horizons:")
rep$say(sprintf("  %6s %10s %10s %18s", "day", "S(t)", "churned", "95% CI"))
for (i in seq_along(sm$time)) {
  rep$say(sprintf("  %6.0f %10.4f %9.1f%% %8.4f - %.4f",
                  sm$time[i], sm$surv[i], 100 * (1 - sm$surv[i]),
                  sm$lower[i], sm$upper[i]))
}
rep$say("")

save_png("km_overall.png",
  ggsurvplot(fit_all, data = df, conf.int = TRUE, risk.table = TRUE,
             xlab = "Days since subscription start", ylab = "S(t): still subscribed",
             title = "KKBox subscriptions: overall Kaplan-Meier survival",
             subtitle = sprintf("n = %s spells, %.1f%% right-censored at 2017-03-31",
                                format(nrow(df), big.mark = ","),
                                100 * mean(df$event == 0)),
             surv.median.line = "hv", censor = FALSE,
             break.time.by = 90, risk.table.height = 0.26,
             ggtheme = theme_minimal()))

# ---------------------------------------------------------------------------
# Helper: fit a stratified KM, tabulate medians, run the log-rank test, plot
# ---------------------------------------------------------------------------
km_block <- function(var, label, png_name, legend_title, palette = "Dark2") {
  rep$rule(sprintf("KM stratified by %s", label))
  # survminer recomputes the log-rank p-value from the fit's own call, so
  # the formula must reference columns of `df` rather than an external Surv().
  f <- as.formula(paste("Surv(duration_days, event) ~", var))
  fit <- survfit(f, data = df)
  # survfit() records the *symbol* `f` in its call; survminer later evaluates
  # that call to recompute the p-value and chokes on a symbol. Substitute the
  # formula itself back in.
  fit$call$formula <- f

  tbl <- summary(fit)$table
  rownames(tbl) <- sub(paste0("^", var, "="), "", rownames(tbl))
  rep$say(sprintf("  %-14s %10s %10s %11s %11s %11s",
                  "group", "n", "events", "median", "95%LCL", "95%UCL"))
  for (i in seq_len(nrow(tbl))) {
    # A median is NA when the group's curve never falls to 0.5 inside the
    # observation window -- report that as "not reached", not as missing.
    fmt <- function(v) if (is.na(v)) "not reached" else sprintf("%.0f", v)
    rep$say(sprintf("  %-14s %10s %10s %11s %11s %11s",
                    rownames(tbl)[i],
                    format(tbl[i, "records"], big.mark = ","),
                    format(tbl[i, "events"], big.mark = ","),
                    fmt(tbl[i, "median"]),
                    fmt(tbl[i, "0.95LCL"]),
                    fmt(tbl[i, "0.95UCL"])))
  }

  lr <- survdiff(f, data = df)
  p <- pchisq(lr$chisq, df = length(lr$n) - 1, lower.tail = FALSE)
  rep$say("")
  rep$say(sprintf("  Log-rank test: chi-sq = %.1f on %d df,  p = %s",
                  lr$chisq, length(lr$n) - 1,
                  if (p < 2.2e-16) "< 2.2e-16" else format.pval(p, digits = 4)))
  rep$say("")

  save_png(png_name,
    ggsurvplot(fit, data = df, conf.int = TRUE, risk.table = TRUE,
               pval = TRUE, pval.method = TRUE,
               xlab = "Days since subscription start",
               ylab = "S(t): still subscribed",
               title = sprintf("KKBox survival by %s", label),
               legend.title = legend_title,
               legend.labs = rownames(tbl),
               censor = FALSE, break.time.by = 90,
               risk.table.height = 0.32, palette = palette,
               ggtheme = theme_minimal()),
    height = 7)

  invisible(list(fit = fit, logrank = lr, p = p))
}

# ---------------------------------------------------------------------------
# (b) Stratified curves
# ---------------------------------------------------------------------------
res_ar <- km_block("auto_renew", "auto-renew status",
                   "km_by_autorenew.png", "Auto-renew")
res_pm <- km_block("payment_method", "payment method",
                   "km_by_payment_method.png", "Payment method")

rep$rule("SUMMARY")
rep$say(sprintf("Overall median survival: %.0f days (95%% CI %.0f-%.0f)",
                med[["median"]], med[["0.95LCL"]], med[["0.95UCL"]]))
rep$say(sprintf("Auto-renew log-rank    : chi-sq = %.1f, p %s",
                res_ar$logrank$chisq,
                if (res_ar$p < 2.2e-16) "< 2.2e-16" else paste("=", format.pval(res_ar$p, 4))))
rep$say(sprintf("Payment method log-rank: chi-sq = %.1f, p %s",
                res_pm$logrank$chisq,
                if (res_pm$p < 2.2e-16) "< 2.2e-16" else paste("=", format.pval(res_pm$p, 4))))
rep$rule()
rep$close()
