source("R/functions-score-storage.R")
source("R/functions-config.R")
source("R/functions-hyperparam-runtime.R")
source("tests/load-step-functions.R", local = TRUE)
load_step_functions("step3_analyze_default_rule.R")
load_step_functions("step4_generate_portfolio_replay_and_weights.R")
params <- read_pipeline_parameters("parameters.csv")
contract <- default_rule_runtime_contract(params, read_score_profile_config(params))
rounds <- 99:171
models <- paste0("model_",letters[1:9])
signal <- data.frame(roundNumber=rounds,matrix(NA_real_,length(rounds),9))
names(signal)[-1] <- models
outcome <- signal
signal[rounds==99,-1] <- 999 # Cannot replace a later missing exact signal.
signal[rounds==100,-1] <- c(1:8/100,0)
outcome[rounds==164,-1] <- c(1:8/100,9)
signal[rounds==101,-1] <- c(rep(.02,8),-.01)
outcome[rounds==165,-1] <- c(rep(.03,7),NA,.04)
signal[rounds==102,-1] <- c(.02,rep(-.01,8))
outcome[rounds==166,-1] <- .02
signal[rounds==103,-1] <- c(0,rep(-.02,8))
outcome[rounds==167,-1] <- .03
# Source 104 and target 168 are both interior gaps.
signal[rounds==105,-1] <- c(.02,.03,rep(-.02,7))
# All outcomes missing at interior target 169: original selected weights persist.
signal[rounds==106,-1] <- c(.04,rep(-.02,8))
outcome[rounds==170,-1] <- .04
# Step 3 owns historical scoring. Its active account rounds retain the
# zero policy, while Step 4 uses the same selection for each exact target.
x <- as.matrix(signal[-1])[match(rounds-64L,rounds),,drop=FALSE]
comparison <- default_rule_account_comparison(x,as.matrix(outcome[-1]),rounds)
comparison <- comparison[comparison$compare_positive,]
stopifnot(identical(comparison$eval_round,164:170),
  max(abs(comparison$ew_positive-c(.045,.03*7/8,.02,0,0,0,.04)))<1e-12)
for(t in comparison$eval_round) {
  live <- build_live_default_rule_weights(signal,contract,t)
  values <- as.numeric(outcome[outcome$roundNumber==t,live$model,drop=FALSE])
  values[!is.finite(values)] <- 0
  score <- sum(live$weight*values)
  stopifnot(abs(score-comparison$ew_positive[comparison$eval_round==t])<1e-12)
}
stopifnot(nrow(build_live_default_rule_weights(signal,contract,166L))==1L,
  nrow(build_live_default_rule_weights(signal,contract,167L))==0L,
  nrow(build_live_default_rule_weights(signal,contract,168L))==0L)
missing_error <- tryCatch(build_live_default_rule_weights(
  signal[signal$roundNumber <= 100L, ], contract, 165L), error=conditionMessage)
stopifnot(is.character(missing_error),grepl("no fallback",missing_error))
