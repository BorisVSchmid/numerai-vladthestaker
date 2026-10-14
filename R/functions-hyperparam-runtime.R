# Fixed D60+|W9 settings shared by account diagnostics and live portfolios.
default_rule_runtime_contract <- function(params, score_config) {
  if (score_config$score_availability_buffer_rounds != 4L)
    stop("The private runtime requires a four-round availability buffer (t-64 through t-72).",
      call. = FALSE)
  if (get_param_integer(params, "min_models_per_cell") != 0L)
    stop("The selected runtime requires min_models_per_cell = 0 (empty portfolios score zero).",
      call. = FALSE)
  live_signal_lookback_rounds <- get_param_integer(params, "daily_refresh_rounds")
  if (live_signal_lookback_rounds <= score_config$selection_source_lag_rounds +
      score_config$historical_window - 1L)
    stop("daily_refresh_rounds must cover all nine exact source rounds through t-72.",
      call. = FALSE)

  list(
    strategy = "ewpos_d60plus_w9",
    signal_score_day = score_config$selection_score_day,
    outcome_score_day = score_config$final_score_day,
    availability_buffer_rounds = score_config$score_availability_buffer_rounds,
    source_round_lag = score_config$selection_source_lag_rounds,
    historical_window = score_config$historical_window
  )
}


prepare_default_rule_score_panels <- function(d60, contract, base_round,
                                      model_names_to_exclude = character()) {
  signal <- build_default_rule_signal_panel(d60, contract)
  outcome <- d60

  excluded <- normalize_model_name(model_names_to_exclude)
  retained_models <- setdiff(names(signal)[-1L], excluded)
  if (!length(retained_models)) {
    stop("No model columns remain after configured exclusions.", call. = FALSE)
  }
  signal <- signal[, c("roundNumber", retained_models), drop = FALSE]
  outcome <- outcome[, c("roundNumber", retained_models), drop = FALSE]

  keep <- signal$roundNumber >= as.integer(base_round)
  signal <- signal[keep, , drop = FALSE]
  outcome <- outcome[keep, , drop = FALSE]
  rownames(signal) <- NULL
  rownames(outcome) <- NULL
  if (!nrow(signal)) {
    stop("No D60+|W9/D60 rows remain from base_round onward.", call. = FALSE)
  }
  if (!any(is.finite(as.matrix(signal[-1L])))) {
    stop("The D60+|W9 mean-signal panel has no finite score from base_round onward.", call. = FALSE)
  }

  list(
    signal = signal,
    outcome = outcome,
    models = retained_models
  )
}


# Indexed by newest source round s: all nine final D60 cells at s through s-8
# must be finite. The target round is s + 64.
build_default_rule_signal_panel <- function(d60, contract) {
  result <- d60
  source <- as.matrix(result[-1L])
  total <- matrix(0, nrow(result), ncol(result)-1L)
  complete <- matrix(TRUE, nrow(result), ncol(result)-1L)
  for (k in 0:(contract$historical_window-1L)) {
    rows <- match(result$roundNumber-k, result$roundNumber)
    cells <- source[rows,,drop=FALSE]
    complete <- complete & is.finite(cells)
    cells[!is.finite(cells)] <- 0
    total <- total + cells
  }
  total <- total/contract$historical_window
  total[!complete] <- NA_real_
  result[-1L] <- as.data.frame(total)
  result
}
