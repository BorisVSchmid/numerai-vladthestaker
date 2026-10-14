args <- commandArgs(trailingOnly = TRUE)
output_dir <- if (length(args)) args[[1L]] else "output"

source(file.path("R", "functions-config.R"))
source(file.path("R", "functions-score-storage.R"))
source(file.path("R", "functions-hyperparam-runtime.R"))
source(file.path("R", "functions-inputs.R"))
source("tests/load-step-functions.R", local = TRUE)
load_step_functions("step4_generate_portfolio_replay_and_weights.R")

portfolio_files <- list.files(file.path(output_dir, "portfolio"),
                              pattern = "^portfolio_[0-9]+[.]csv$")
if (!length(portfolio_files)) stop("No round-specific Step4 portfolios found.")
saved_rounds <- as.integer(sub("^portfolio_([0-9]+)[.]csv$", "\\1", portfolio_files))
audit_round <- if (length(args) > 1L) as.numeric(args[[2L]]) else max(saved_rounds)

portfolio_path <- file.path(output_dir, "portfolio", portfolio_filename(audit_round))
stopifnot(file.exists(portfolio_path), file.info(portfolio_path)$size > 0)
portfolio <- utils::read.csv(
  portfolio_path,
  stringsAsFactors = FALSE,
  check.names = FALSE
)
expected_columns <- c(
  "generated_at_utc", "strategy", "intended_round", "expected_signal_round",
  "signal_round", "signal_fallback_rounds", "signal_score_day",
  "historical_window", "availability_buffer_rounds", "source_round_lag",
  "effective_source_round_lag", "complete_models", "selected_models", "model",
  "signal_combined_score", "weight", "signal_rank"
)
stopifnot(identical(names(portfolio), expected_columns))
params <- read_pipeline_parameters("parameters.csv")
inputs <- check_pipeline_inputs(4L, params, output_dir)
contract <- inputs$contract
panel <- inputs$panel
signal_row <- match(audit_round - contract$source_round_lag, panel$signal$roundNumber)
stopifnot(!is.na(signal_row))
signal_values <- as.numeric(panel$signal[signal_row, panel$models, drop = TRUE])
names(signal_values) <- panel$models
complete <- is.finite(signal_values)
selected <- complete & signal_values > 0 & panel$portfolio_included
expected_models <- panel$models[selected]
stopifnot(setequal(portfolio$model, expected_models))
if (nrow(portfolio)) {
  stopifnot(
    identical(unique(portfolio$strategy), "ewpos_d60plus_w9"),
    identical(unique(as.integer(portfolio$signal_score_day)), 60L),
    identical(unique(as.integer(portfolio$historical_window)), 9L),
    identical(unique(as.integer(portfolio$availability_buffer_rounds)), 4L),
    identical(unique(as.integer(portfolio$source_round_lag)), 64L),
    all(is.finite(portfolio$weight) & portfolio$weight > 0),
    abs(sum(portfolio$weight) - 1) < 1e-10,
    identical(as.integer(portfolio$signal_rank), seq_len(nrow(portfolio))),
    identical(
      portfolio$model,
      portfolio$model[order(-portfolio$signal_combined_score, portfolio$model)]
    ),
    all(portfolio$model == normalize_model_name(portfolio$model)),
    !anyDuplicated(portfolio$model)
  )

  intended_round <- unique(as.integer(portfolio$intended_round))
  expected_signal_round <- unique(as.integer(portfolio$expected_signal_round))
  signal_round <- unique(as.integer(portfolio$signal_round))
  signal_fallback_rounds <- unique(as.integer(portfolio$signal_fallback_rounds))
  effective_source_round_lag <-
    unique(as.integer(portfolio$effective_source_round_lag))
  stopifnot(
    length(intended_round) == 1L,
    intended_round == audit_round,
    length(expected_signal_round) == 1L,
    length(signal_round) == 1L,
    length(signal_fallback_rounds) == 1L,
    length(effective_source_round_lag) == 1L,
    expected_signal_round == intended_round - contract$source_round_lag,
    signal_round == expected_signal_round - signal_fallback_rounds,
    signal_fallback_rounds == 0L,
    effective_source_round_lag == intended_round - signal_round
  )
  stopifnot(
    sum(complete & panel$portfolio_included) == unique(as.integer(portfolio$complete_models)),
    sum(selected) == unique(as.integer(portfolio$selected_models))
  )
  actual_order <- match(portfolio$model, panel$models)
  stopifnot(
    isTRUE(all.equal(
      portfolio$signal_combined_score,
      signal_values[actual_order],
      tolerance = 1e-12,
      check.attributes = FALSE
    )),
    all(abs(portfolio$weight - 1 / length(expected_models)) < 1e-12)
  )
} else {
  # Empty output must agree with the signal, not merely have valid headers.
  cat("Verified header-only Step4 portfolio: no submission.\n")
}

cat("Independent D60+|W9 Step4 artifact audit passed.\n")
