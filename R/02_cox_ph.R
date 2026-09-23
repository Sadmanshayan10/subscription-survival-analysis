# 02_cox_ph.R -- Cox proportional hazards model, PH diagnostics, remediation.
#
#   (c) Cox PH on the full covariate set: hazard ratios, 95% CI, p-values
#   (d) cox.zph() / Schoenfeld residual test of the PH assumption, and -- where
#       it fails -- a remediated model that stratifies on the worst offenders
#       and gives the remaining covariates time-varying coefficients.
#
# Outputs: results/03_cox_model.txt
#          results/cox_forest.png
#          results/schoenfeld_<term>.png
#          results/cox_timevarying.png

this_file_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  m <- grep("^--file=", args, value = TRUE)
  if (length(m)) return(dirname(normalizePath(sub("^--file=", "", m[1]))))
  of <- sys.frames()[[1]]$ofile
  if (!is.null(of)) return(dirname(normalizePath(of)))
  normalizePath(getwd())
}
source(file.path(this_file_dir(), "00_setup.R"))
suppressPackageStartupMessages(library(broom))

df <- load_spells()
rep <- new_report("03_cox_model.txt")

# Pretty labels for coefficient names, for the report and the forest plot.
pretty_term <- function(x) {
  x <- sub("^autorenew_off",  "Auto-renew: No",   x)
  x <- sub("^auto_renew",     "Auto-renew: ",     x)
  x <- sub("^payment_method", "Payment method: ", x)
  x <- sub("^plan_length",    "Plan length: ",    x)
  x <- sub("^city_grp",       "City: ",           x)
  x <- sub("^reg_channel",    "Reg channel: ",    x)
  x
}

fmt_p <- function(p) ifelse(p < 2.2e-16, "< 2.2e-16", formatC(p, format = "e", digits = 2))

# ---------------------------------------------------------------------------
# (c) Cox proportional hazards model
# ---------------------------------------------------------------------------
rep$rule("(c) COX PROPORTIONAL HAZARDS MODEL")
rep$say(sprintf("n = %s spells, %s events, %.2f%% right-censored",
                format(nrow(df), big.mark = ","),
                format(sum(df$event), big.mark = ","),
                100 * mean(df$event == 0)))
rep$say("Reference levels: auto-renew Yes, payment method PM41,")
rep$say("plan length 8-31 days, city1, registration channel via7.")
rep$say("")

fit <- coxph(model_formula("Surv(duration_days, event)"), data = df)

tt <- tidy(fit, exponentiate = TRUE, conf.int = TRUE)
tt$label <- pretty_term(tt$term)
tt <- tt[order(-tt$estimate), ]

rep$say(sprintf("  %-34s %8s %8s %8s   %s", "term", "HR", "lo95", "hi95", "p"))
for (i in seq_len(nrow(tt))) {
  rep$say(sprintf("  %-34s %8.3f %8.3f %8.3f   %s",
                  tt$label[i], tt$estimate[i], tt$conf.low[i],
                  tt$conf.high[i], fmt_p(tt$p.value[i])))
}
rep$say("")
rep$say(sprintf("Concordance (C-index): %.4f (se %.4f)",
                fit$concordance[["concordance"]], fit$concordance[["std"]]))
lr_stat <- 2 * diff(fit$loglik)
lr_df <- length(coef(fit))
rep$say(sprintf("Likelihood ratio test: %.0f on %d df, p %s", lr_stat, lr_df,
                fmt_p(pchisq(lr_stat, lr_df, lower.tail = FALSE))))
rep$say("")
rep$say("Strongest effects (largest and smallest HR):")
for (i in c(1, 2, 3, nrow(tt) - 1, nrow(tt))) {
  rep$say(sprintf("  %-34s HR = %.3f  (95%% CI %.3f-%.3f)",
                  tt$label[i], tt$estimate[i], tt$conf.low[i], tt$conf.high[i]))
}
rep$say("")

# --- forest plot -----------------------------------------------------------
fp <- tt
fp$label <- factor(fp$label, levels = rev(fp$label))
forest <- ggplot(fp, aes(x = estimate, y = label)) +
  geom_vline(xintercept = 1, linetype = "dashed", colour = "grey40") +
  geom_errorbarh(aes(xmin = conf.low, xmax = conf.high), width = 0.25,
                 colour = "#2c6fbb") +
  geom_point(size = 2.2, colour = "#12436d") +
  scale_x_log10() +
  labs(
    title = "Cox proportional hazards: churn hazard ratios",
    subtitle = sprintf(
      "n = %s spells, %s churn events. HR > 1 = churns sooner. Log scale, 95%% CI.",
      format(nrow(df), big.mark = ","), format(sum(df$event), big.mark = ",")),
    caption = "PH assumption is violated (see cox.zph); these HRs are averages over follow-up.",
    x = "Hazard ratio (log scale)", y = NULL) +
  theme_minimal(base_size = 11) +
  theme(panel.grid.major.y = element_line(colour = "grey92"),
        plot.title = element_text(face = "bold"))
save_png("cox_forest.png", forest, width = 9, height = 7)

# ---------------------------------------------------------------------------
# (d) Proportional hazards assumption
# ---------------------------------------------------------------------------
rep$rule("(d) PROPORTIONAL HAZARDS ASSUMPTION -- cox.zph / Schoenfeld residuals")
z <- cox.zph(fit)
rep$obj(z$table)

violated <- rownames(z$table)[rownames(z$table) != "GLOBAL" & z$table[, "p"] < 0.05]
violated <- violated[!is.na(violated)]

rep$say(sprintf("GLOBAL test: chi-sq = %.0f on %d df, p %s",
                z$table["GLOBAL", "chisq"], z$table["GLOBAL", "df"],
                fmt_p(z$table["GLOBAL", "p"])))
rep$say("")
if (length(violated) == 0) {
  rep$say("PH assumption HOLDS for every covariate (all p >= 0.05).")
} else {
  rep$say("PH ASSUMPTION IS VIOLATED. Covariates failing the test (p < 0.05):")
  for (v in violated) {
    rep$say(sprintf("  %-18s chi-sq = %10.0f on %d df, p %s",
                    v, z$table[v, "chisq"], z$table[v, "df"], fmt_p(z$table[v, "p"])))
  }
  rep$say("")
  rep$say("Caveat on interpretation: with n = 915,067 the test is enormously")
  rep$say("powered, so any trivial deviation reaches significance. The remedy")
  rep$say("below is therefore judged on EFFECT SIZE -- whether the hazard ratio")
  rep$say("actually changes materially over follow-up -- not on the p-value.")
}
rep$say("")

# --- Schoenfeld residual plots (smoothed fit only; 506,943 residual points
# --- per panel would render as a solid block and take minutes to draw) ------
for (i in seq_len(nrow(z$table) - 1)) {
  term <- rownames(z$table)[i]
  zi <- z[i]
  ncols <- if (is.null(dim(zi$y))) 1L else ncol(zi$y)
  nr <- ceiling(ncols / 2); nc <- min(2L, ncols)
  save_png(
    paste0("schoenfeld_", term, ".png"),
    function() {
      op <- par(mfrow = c(nr, nc), mar = c(4.2, 4.2, 3, 1), oma = c(0, 0, 2.5, 0))
      on.exit(par(op))
      plot(zi, resid = FALSE, col = "#c1272d", lwd = 2)
      abline(h = 0, lty = 3, col = "grey40")
      mtext(sprintf("Scaled Schoenfeld residuals: %s  (p %s)",
                    term, fmt_p(z$table[term, "p"])),
            outer = TRUE, cex = 1.05, font = 2)
    },
    width = 9, height = max(4.4, 3.2 * nr))
}

# ---------------------------------------------------------------------------
# Remediated model
# ---------------------------------------------------------------------------
rep$rule("REMEDIATED MODEL (stratification + time-varying coefficients)")
rep$say("Strategy:")
rep$say("  * plan_length and payment_method are the largest PH violations and")
rep$say("    are nuisance/design variables rather than the effects of interest,")
rep$say("    so they go into strata(): each gets its own baseline hazard shape")
rep$say("    and no proportionality is imposed on them.")
rep$say("  * auto_renew, city_grp and reg_channel get TIME-VARYING coefficients:")
rep$say("    follow-up is split at 30 and 180 days and each covariate is")
rep$say("    interacted with the resulting period, so its HR may differ by period.")
rep$say("  * Idiom is Therneau's `x:strata(tgroup)` on survSplit output, which")
rep$say("    avoids the non-estimable period main effect (within a risk set at")
rep$say("    time t, every subject is in the same period).")
rep$say("")

cuts <- c(30, 180)
period_labels <- c("d1-30", "d31-180", "d181+")

df_split <- survSplit(Surv(duration_days, event) ~ ., data = df,
                      cut = cuts, episode = "tgroup", id = "split_id")

# survSplit rebuilds the data frame and re-derives factors alphabetically,
# which silently flips reference levels (auto_renew would become No-referenced
# and every HR would invert). Restore the levels set in 00_setup.R.
for (v in MODEL_COVARIATES) {
  df_split[[v]] <- factor(df_split[[v]], levels = levels(df[[v]]))
}
stopifnot(identical(levels(df_split$auto_renew), levels(df$auto_renew)))
df_split$tgroup <- factor(df_split$tgroup, levels = seq_along(period_labels),
                          labels = period_labels)

rep$say(sprintf("survSplit: %s spells -> %s person-period rows at cuts %s",
                format(nrow(df), big.mark = ","),
                format(nrow(df_split), big.mark = ","),
                paste(cuts, collapse = ", ")))
rep$say("")

# Reference fit: same strata, but a single proportional HR per covariate.
# Comparing the time-varying HRs against THIS (rather than against the
# unstratified model above) isolates the effect of relaxing proportionality
# from the effect of stratifying -- the two changes would otherwise be
# confounded, since auto-renew is strongly associated with payment method.
fit_strat <- coxph(
  Surv(duration_days, event) ~ auto_renew + city_grp + reg_channel +
    strata(plan_length, payment_method),
  data = df)
ts <- tidy(fit_strat, exponentiate = TRUE, conf.int = TRUE)
ts$label <- pretty_term(ts$term)

rep$say("Stratified model with proportionality still imposed (reference point):")
rep$say(sprintf("  %-30s %8s %8s %8s", "term", "HR", "lo95", "hi95"))
for (i in seq_len(nrow(ts))) {
  rep$say(sprintf("  %-30s %8.3f %8.3f %8.3f",
                  ts$label[i], ts$estimate[i], ts$conf.low[i], ts$conf.high[i]))
}
rep$say("")

fit_tv <- coxph(
  Surv(tstart, duration_days, event) ~
    autorenew_off:strata(tgroup) + city_grp:strata(tgroup) +
    reg_channel:strata(tgroup) + strata(plan_length, payment_method),
  data = df_split)

tv <- tidy(fit_tv, exponentiate = TRUE, conf.int = TRUE)
tv <- tv[!is.na(tv$estimate), ]
# Terms come back as "auto_renewNo:strata(tgroup)d1-30" or
# "strata(tgroup)d1-30:city_grpcity5" -- the two components can appear in
# either order, so pull the period out and treat the remainder as the covariate.
tv$period <- factor(sub(".*strata\\(tgroup\\)([^:]+).*", "\\1", tv$term),
                    levels = period_labels)
tv$covar <- pretty_term(gsub(":?strata\\(tgroup\\)[^:]+:?", "", tv$term))

rep$say("Time-varying hazard ratios (baseline stratified by plan length x payment method):")
rep$say(sprintf("  %-28s %-9s %8s %8s %8s   %s",
                "covariate", "period", "HR", "lo95", "hi95", "p"))
for (i in seq_len(nrow(tv))) {
  rep$say(sprintf("  %-28s %-9s %8.3f %8.3f %8.3f   %s",
                  tv$covar[i], as.character(tv$period[i]), tv$estimate[i],
                  tv$conf.low[i], tv$conf.high[i], fmt_p(tv$p.value[i])))
}
rep$say("")

# --- does the HR actually move? -------------------------------------------
rep$rule("IS THE VIOLATION MATERIAL, OR JUST SIGNIFICANT?")
rep$say("For each covariate, the ratio of its largest to its smallest")
rep$say("period-specific HR. A ratio near 1 means proportionality was a")
rep$say("harmless approximation despite the tiny p-value; a large ratio means")
rep$say("the single-number HR genuinely misrepresents the effect.")
rep$say("")
rep$say(sprintf("  %-28s %9s %9s %9s %9s",
                "covariate", "HR d1-30", "d31-180", "d181+", "max/min"))
for (cv in unique(tv$covar)) {
  sub_tv <- tv[tv$covar == cv, ]
  sub_tv <- sub_tv[order(sub_tv$period), ]
  hrs <- sub_tv$estimate
  rep$say(sprintf("  %-28s %9.3f %9.3f %9.3f %9.2f", cv,
                  hrs[1], hrs[2], hrs[3], max(hrs) / min(hrs)))
}
rep$say("")

ar_tv <- tv[grepl("^Auto-renew", tv$covar), ]
ar_tv <- ar_tv[order(ar_tv$period), ]
ar_strat <- ts$estimate[grepl("^Auto-renew", ts$label)][1]
ar_naive <- tt$estimate[grepl("^Auto-renew", tt$label)][1]
rep$say("Headline -- hazard ratio for auto-renew OFF (vs ON):")
rep$say(sprintf("  unstratified Cox, proportional : HR = %.3f", ar_naive))
rep$say(sprintf("  stratified Cox, proportional   : HR = %.3f", ar_strat))
for (i in seq_len(nrow(ar_tv))) {
  rep$say(sprintf("  stratified, period %-9s: HR = %.3f (95%% CI %.3f-%.3f)",
                  as.character(ar_tv$period[i]), ar_tv$estimate[i],
                  ar_tv$conf.low[i], ar_tv$conf.high[i]))
}
rep$say(sprintf("  -> the effect decays by a factor of %.1f across follow-up, so a",
                max(ar_tv$estimate) / min(ar_tv$estimate)))
rep$say("     single constant HR is not an adequate summary.")
rep$say("")
rep$say(sprintf("Concordance: unstratified %.4f, remediated %.4f.",
                fit$concordance[["concordance"]],
                fit_tv$concordance[["concordance"]]))
rep$say("These are NOT comparable: concordance in a stratified model is")
rep$say("computed only within strata, so the plan-length and payment-method")
rep$say("information -- which carries most of the discrimination -- is removed")
rep$say("from the score by construction rather than lost by a worse model.")
rep$say("")

# --- plot ------------------------------------------------------------------
tv$covar_f <- factor(tv$covar, levels = rev(unique(tv$covar)))
tvplot <- ggplot(tv, aes(x = estimate, y = covar_f, colour = period)) +
  geom_vline(xintercept = 1, linetype = "dashed", colour = "grey40") +
  geom_errorbarh(aes(xmin = conf.low, xmax = conf.high), width = 0.2,
                 position = position_dodge(width = 0.7)) +
  geom_point(size = 2.2, position = position_dodge(width = 0.7)) +
  scale_x_log10() +
  scale_colour_manual(
    values = setNames(c("#12436d", "#28a197", "#801650"), period_labels),
    name = "Follow-up period") +
  labs(title = "Time-varying hazard ratios after remediating the PH violation",
       subtitle = "Baseline stratified by plan length x payment method; HR free to differ by period",
       caption = "Reference levels: auto-renew Yes, city1, via7. HR > 1 = churns sooner.",
       x = "Hazard ratio (log scale)", y = NULL) +
  theme_minimal(base_size = 11) +
  theme(plot.title = element_text(face = "bold"),
        panel.grid.major.y = element_line(colour = "grey92"))
save_png("cox_timevarying.png", tvplot, width = 9.5, height = 6)

rep$rule()
rep$close()

# Machine-readable coefficient tables. Deliberately not saveRDS() of the fits:
# a coxph object on 915k rows carries its residual matrices and runs to ~13 MB,
# which does not belong in version control.
write.csv(tt[, c("label", "estimate", "conf.low", "conf.high", "p.value")],
          file.path(RESULTS_DIR, "cox_hazard_ratios.csv"), row.names = FALSE)
write.csv(tv[, c("covar", "period", "estimate", "conf.low", "conf.high", "p.value")],
          file.path(RESULTS_DIR, "cox_timevarying_hr.csv"), row.names = FALSE)
write.csv(data.frame(term = rownames(z$table), z$table, row.names = NULL),
          file.path(RESULTS_DIR, "cox_zph_table.csv"), row.names = FALSE)
message("  wrote results/cox_hazard_ratios.csv, cox_timevarying_hr.csv, cox_zph_table.csv")
