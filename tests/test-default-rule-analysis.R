source("tests/load-step-functions.R", local = TRUE)
load_step_functions("step3_analyze_default_rule.R")
# Conditional accuracy does not fall merely because the model is rarely included.
# A never-included model has no supported positive-accuracy diagnostic.
accuracy<-default_rule_positive_accuracy_posteriors(matrix(.9,2,3),matrix(.8,2,3),c(80,20,0))
stopifnot(all(accuracy$positive_accuracy[,1:2]==.9),
  all(is.na(accuracy$positive_accuracy[,3])),all(accuracy$overall_positive_rate==.8))
invalid<-tryCatch(default_rule_positive_accuracy_posteriors(matrix(1.2,2,1),matrix(.8,2,1),1),error=identity)
stopifnot(inherits(invalid,"error"))
# Eligibility uses complete signals. Missing future outcomes contribute zero
# without dropping selected models or renormalizing the remaining weights.
signals<-matrix(rep(c(rep(1,9),-1,-1,0),5),nrow=5,byrow=TRUE)
outcomes<-matrix(rep(c(rep(.2,8),NA,-.3,NA,.4),5),nrow=5,byrow=TRUE)
outcomes[2,]<-NA # Interior account non-submission.
signals[3,]<--1 # Empty positive portfolio, nonempty EW(all).
outcomes[4,]<-.2
signals[5,]<-NA # Unavailable trailing signal window: excluded.
available<-default_rule_account_comparison(signals,outcomes,101:105)
stopifnot(identical(available$compare_positive,c(TRUE,TRUE,TRUE,TRUE,FALSE)),
  available$positive_models[1]==9L,available$negative_models[1]==2L,
  available$all_models[1]==12L,abs(available$ew_positive[1]-1.6/9)<1e-12,
  abs(available$ew_all[1]-1.7/12)<1e-12,
  available$ew_positive[2]==0,available$ew_all[2]==0,available$ew_positive[3]==0,
  abs(available$ew_positive[4]-available$ew_all[4])<1e-12)
rounds<-100:172
signal<-data.frame(roundNumber=rounds,a=NA_real_,b=NA_real_,c=NA_real_)
outcome<-signal
signal$a[1:9]<-c(4,-3,0,2,-1,5,-2,6,-4)
signal$b[4:9]<-c(-2,5,3,-2,4,-1)
signal$c[7:9]<-c(3,7,2) # Always-positive predictor: no within-model sign contrast.
outcome$a[65:73]<-c(.2,-.1,.05,.3,-.2,.4,.01,.1,-.3)
outcome$b[68:73]<-c(.3,-.1,.4,-.2,.2,-.05)
outcome$c[71:73]<-c(.01,.02,.03)
# Same-source final scores must never be the evaluation outcomes.
outcome$a[1:9]<-999
panel<-list(signal=signal,outcome=outcome,models=c("a","b","c"),portfolio_included=rep(TRUE,3))
contract<-list(source_round_lag=64L)
x<-prepare_default_rule_analysis(panel,contract)
stopifnot(x$data$G==3L,identical(x$data$group_start,c(1L,4L,7L)),
          identical(x$rounds,164:172),identical(x$data$include_model[,1],as.integer(signal$a[1:9]>0)),
          x$counts$pairs_positive[1]==4L,x$counts$pairs_nonpositive[1]==5L,
          x$counts$zero_sign_pairs[1]==1L,x$counts$same_sign[1]+x$counts$opposite_sign[1]==8L,
          grepl("one signal sign",x$counts$status[3]),all(x$account$eval_round>=164L))
stopifnot(x$counts$observed_positive_outcome_given_positive[1]==1)
# Changing only excluded outcomes cannot change observed positive accuracy.
excluded_changed<-panel
excluded_changed$outcome$a[65:73][signal$a[1:9]<=0]<-10
conditional<-prepare_default_rule_analysis(excluded_changed,contract)
stopifnot(identical(x$counts$observed_positive_outcome_given_positive,
  conditional$counts$observed_positive_outcome_given_positive))
# Keep a model in the outcome fit when all signals are nonpositive, but do not
# report its borrowed positive-state posterior as observed inclusion evidence.
never_included<-panel
never_included$signal$a[1:9]<--1
never<-prepare_default_rule_analysis(never_included,contract)
positive_pairs<-never$counts$pairs_positive[match(never$scale$model,never$counts$model)]
posteriors<-default_rule_positive_accuracy_posteriors(matrix(.8,2,never$data$M),
  matrix(.6,2,never$data$M),positive_pairs)
summary<-summarize_default_rule_positive_accuracy(never,posteriors)
row<-match("a",summary$model)
stopifnot(is.na(summary$observed_positive_outcome_given_positive[row]),
  is.na(summary$positive_accuracy_median[row]),
  summary$positive_accuracy_status[row]=="no included paired rounds",
  all(is.finite(summary$positive_accuracy_median[summary$pairs_positive>0])))
# Multiplying D60+|W9 signal magnitudes without changing their signs cannot affect the fit.
modified<-panel; modified$signal[-1]<-lapply(modified$signal[-1],function(v)v*100)
xx<-prepare_default_rule_analysis(modified,contract)
stopifnot(identical(x$data,xx$data))
# Scattered missing pairs get explicit latent residuals, not zero outcomes.
missing<-panel;missing$outcome$a[68]<-NA_real_
with_gap<-prepare_default_rule_analysis(missing,contract)
stopifnot(with_gap$data$H==1L,with_gap$data$missing_row==4L,
          with_gap$data$missing_model==1L,!with_gap$observed[4,1],
          with_gap$counts$pairs[1]==8L,x$data$H==0L)
# A missing signal is likewise excluded, even when its D60 outcome is finite.
missing_signal<-panel;missing_signal$signal$a[4]<-NA_real_
with_missing_signal<-prepare_default_rule_analysis(missing_signal,contract)
stopifnot(identical(with_gap$data,with_missing_signal$data))

# Account posterior weights must retain missing-model denominators and count
# empty/non-submitted rounds as zero, without dividing an empty roster by zero.
fixture<-list(raw_x=matrix(c(1,1,1,-1,-1,-1,NA,NA,1,-1),5,2,byrow=TRUE,
  dimnames=list(NULL,c("a","b"))),raw_y=matrix(c(.1,NA,.1,.2,.1,.2,.1,.2,NA,NA),5,2,byrow=TRUE),
  panel_rounds=1:5,account=data.frame(eval_round=1:5),scale=data.frame(model=c("a","b")),
  portfolio_included=c(TRUE,TRUE))
weights<-default_rule_account_posterior_weights(fixture)
stopifnot(identical(weights$rounds,1:5))
scores<-default_rule_account_expected_scores(matrix(c(.1,.2),1,2),matrix(c(.1,.2),1,2),weights)
stopifnot(max(abs(scores-c(.03,.07,-.04)))<1e-12,
  all(is.na(default_rule_account_expected_scores(matrix(c(.1,.2),1,2),
    matrix(c(.1,.2),1,2),list(coefficients=weights$coefficients,rounds=integer())))))

# A model with one observed pair cannot support an account posterior on that
# round. Report the full replay separately from observations on supported rounds.
subset_panel <- panel
subset_panel$signal[, c("a", "b", "c")] <- NA_real_
subset_panel$signal[1:3, c("a", "b")] <- 1
subset_panel$outcome[, c("a", "b", "c")] <- NA_real_
subset_panel$outcome$a[65:67] <- c(.1, .2, .3)
subset_panel$outcome$b[67] <- 9
subset_prepared <- prepare_default_rule_analysis(subset_panel, contract)
subset_weights <- default_rule_account_posterior_weights(subset_prepared)
subset_scores <- default_rule_account_expected_scores(matrix(c(.1, .2), 2, 1),
  matrix(c(.1, .2), 2, 1), subset_weights)
summaries <- summarize_default_rule_account_scores(subset_prepared, subset_weights, subset_scores)
stopifnot(summaries$summary$common_rounds == 3L,
  summaries$summary$posterior_roster_rounds == 2L,
  abs(summaries$summary$observed_ew_positive - 1.6) < 1e-12,
  abs(summaries$summary$observed_supported_ew_positive - .075) < 1e-12,
  summaries$summary$evidence == "limited_history_under_25_rounds",
  all(summaries$scores$observed_rounds == 3L), all(summaries$scores$posterior_rounds == 2L),
  abs(summaries$scores$observed_supported[1] - .075) < 1e-12)
empty_weights <- list(coefficients = subset_weights$coefficients, rounds = integer())
empty_scores <- default_rule_account_expected_scores(matrix(.1, 1, 1), matrix(.2, 1, 1), empty_weights)
empty_summary <- summarize_default_rule_account_scores(subset_prepared, empty_weights, empty_scores)
stopifnot(empty_summary$summary$posterior_roster_rounds == 0L,
  is.na(empty_summary$summary$observed_supported_ew_positive),
  all(is.na(empty_summary$scores$expected_mean)),
  empty_summary$summary$observed_ew_positive == summaries$summary$observed_ew_positive)
invalid_weights <- subset_weights
invalid_weights$rounds <- 999L
stopifnot(inherits(try(summarize_default_rule_account_scores(
  subset_prepared, invalid_weights, subset_scores), silent = TRUE), "try-error"))

# No models retain their diagnostics but cannot contribute account weights or
# extend its evaluation period beyond the permitted models' observed history.
restricted_panel <- panel
restricted_panel$outcome$a[73L] <- NA_real_
all_allowed <- prepare_default_rule_analysis(restricted_panel, contract)
restricted_panel$portfolio_included <- c(TRUE, FALSE, FALSE)
restricted <- prepare_default_rule_analysis(restricted_panel, contract)
restricted_weights <- default_rule_account_posterior_weights(restricted)
stopifnot(identical(restricted$data, all_allowed$data),
  identical(restricted$counts$portfolio_included, c(TRUE, FALSE, FALSE)),
  max(restricted$account$eval_round) == 171L, all(restricted$account$all_models == 1L),
  restricted$account$ew_positive[restricted$account$eval_round == 164L] == .2,
  all(restricted_weights$coefficients[restricted$scale$model != "a", ] == 0))
restricted_panel$portfolio_included[] <- FALSE
none_allowed <- prepare_default_rule_analysis(restricted_panel, contract)
stopifnot(nrow(none_allowed$account) == 0L,
  length(default_rule_account_posterior_weights(none_allowed)$rounds) == 0L)
