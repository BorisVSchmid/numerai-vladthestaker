########
# Step 4: generate and publish the current EW(pos) D60+|W9 portfolio.
#
# Inputs: parameters.csv, Optimize-Me.xlsx, Step 1 D60 scores, and the API current round.
# Output: output/portfolio/portfolio_<roundnr>.csv (headers only when empty).
# Usage: Rscript.exe --vanilla step4_generate_portfolio_replay_and_weights.R [OUTPUT_DIR]
########

# -------------------- Exact signals and current-round weights --------------------
build_live_default_rule_weights <- function(signal, contract, intended_round) {
  portfolio_filename(intended_round)
  intended_round <- as.integer(intended_round)
  signal_round <- intended_round - contract$source_round_lag
  signal_row <- match(signal_round, signal$roundNumber)
  if (is.na(signal_row))
    stop("No exact D60+|W9 signal for intended round ", intended_round,
      "; no fallback is permitted.", call. = FALSE)

  model_names <- names(signal)[-1L]
  signal_values <- as.matrix(signal[-1L])[signal_row, ]
  complete <- is.finite(signal_values)
  selected <- complete & signal_values > 0
  selected_models <- sum(selected)
  data.frame(
    strategy = rep(contract$strategy, selected_models),
    intended_round = rep(intended_round, selected_models),
    expected_signal_round = rep(signal_round, selected_models),
    signal_round = rep(signal_round, selected_models),
    signal_fallback_rounds = rep(0L, selected_models),
    signal_score_day = rep(contract$signal_score_day, selected_models),
    historical_window = rep(contract$historical_window, selected_models),
    availability_buffer_rounds = rep(contract$availability_buffer_rounds, selected_models),
    source_round_lag = rep(contract$source_round_lag, selected_models),
    effective_source_round_lag = rep(contract$source_round_lag, selected_models),
    complete_models = rep(sum(complete), selected_models),
    selected_models = rep(selected_models, selected_models),
    model = model_names[selected],
    signal_combined_score = as.numeric(signal_values[selected]),
    weight = rep(1 / selected_models, selected_models),
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}


format_default_rule_portfolio <- function(
  live_weights,
  generated_at_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
) {
  required_columns <- c(
    "strategy", "intended_round", "expected_signal_round", "signal_round",
    "signal_fallback_rounds", "signal_score_day", "historical_window",
    "availability_buffer_rounds", "source_round_lag",
    "effective_source_round_lag",
    "complete_models", "selected_models", "model",
    "signal_combined_score", "weight"
  )
  if (
    !is.data.frame(live_weights) ||
      !identical(names(live_weights), required_columns)
  ) {
    stop("Live D60+|W9 weights do not have the canonical raw schema.", call. = FALSE)
  }
  if (
    any(!is.finite(live_weights$signal_combined_score)) ||
      any(!is.finite(live_weights$weight)) || any(live_weights$weight <= 0) ||
      (nrow(live_weights) > 0L && abs(sum(live_weights$weight) - 1) > 1e-10) ||
      anyDuplicated(live_weights$model)
  ) {
    stop("Live D60+|W9 weights are invalid or not normalized.", call. = FALSE)
  }

  x <- live_weights[
    order(-live_weights$signal_combined_score, live_weights$model),
    ,
    drop = FALSE
  ]
  formatted <- data.frame(
    generated_at_utc = rep(as.character(generated_at_utc), nrow(x)),
    x,
    signal_rank = seq_len(nrow(x)),
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
  rownames(formatted) <- NULL
  formatted
}


# -------------------- Portfolio freshness --------------------
portfolio_filename <- function(intended_round) {
  if (!is.numeric(intended_round) || length(intended_round) != 1L ||
      !is.finite(intended_round) || intended_round < 1 ||
      intended_round > .Machine$integer.max || intended_round != floor(intended_round))
    stop("Portfolio filename requires one positive integer round.", call. = FALSE)
  paste0("portfolio_", as.integer(intended_round), ".csv")
}


# A previous portfolio is retained for inspection, never as an active fallback.
invalidate_portfolio <- function(path) {
  if (!file.exists(path)) return(invisible(path))
  archive <- paste0(path, ".last-successful")
  if (!file.copy(path, archive, overwrite = TRUE))
    stop("Could not preserve the previous portfolio before invalidation.", call. = FALSE)
  if (!file.remove(path) || file.exists(path))
    stop("Could not invalidate the previous portfolio.", call. = FALSE)
  invisible(path)
}


validate_current_portfolio <- function(rows, current_round) {
  if (!is.data.frame(rows) || !nrow(rows) ||
      !all(c("intended_round", "model", "weight") %in% names(rows)) ||
      length(current_round) != 1L || !is.finite(current_round) ||
      anyNA(rows$intended_round) || any(rows$intended_round != current_round))
    stop("No valid portfolio for the current Numerai round; stale weights are refused.", call. = FALSE)
  if (anyDuplicated(rows$model) || anyNA(rows$model) || any(!nzchar(rows$model)) ||
      any(!is.finite(rows$weight)) || any(rows$weight <= 0) ||
      abs(sum(rows$weight)-1) > 1e-10)
    stop("Invalid portfolio models or weights.", call. = FALSE)
  invisible(rows)
}


# -------------------- Generate and publish one portfolio --------------------
generate_current_portfolio <- function(output_dir, params,
    current_round_function = function() fetch_current_round(get_param_integer(params, "tournament_id")),
    clock_function = Sys.time, workbook_models = NULL) {
  current_round <- current_round_function()
  destination <- file.path(output_dir, "portfolio", portfolio_filename(current_round))
  invalidate_portfolio(destination)

  inputs <- check_pipeline_inputs(4L, params, output_dir, workbook_models)
  contract <- inputs$contract
  panel <- inputs$panel
  allowed_models <- panel$models[panel$portfolio_included]
  weights <- build_live_default_rule_weights(
    panel$signal[, c("roundNumber", allowed_models), drop = FALSE], contract, current_round)
  portfolio <- format_default_rule_portfolio(weights,
    format(clock_function(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"))

  portfolio_dir <- dirname(destination)
  dir.create(portfolio_dir, recursive = TRUE, showWarnings = FALSE)
  staged <- tempfile(".portfolio-", tmpdir = portfolio_dir, fileext = ".tmp")
  on.exit(unlink(staged), add = TRUE)
  utils::write.csv(portfolio, staged, row.names = FALSE, na = "")

  publication_round <- current_round_function()
  if (length(publication_round) != 1L || !is.finite(publication_round) ||
      publication_round != current_round)
    stop("Round changed during portfolio generation; stale weights are refused.", call. = FALSE)
  if (nrow(portfolio)) validate_current_portfolio(portfolio, publication_round)
  publish_staged_files(staged, destination)

  message("Step4 complete: ", nrow(portfolio), " models selected for round ", current_round,
    " from newest source round ", current_round - contract$source_round_lag, ".")
  message("Portfolio: ", destination)
  if (!nrow(portfolio)) message("No positive D60+|W9 models: header-only portfolio; no submission.")
  invisible(list(weights = portfolio, output_path = destination, intended_round = current_round))
}

# -------------------- Dependencies, settings, and execution --------------------
main <- function() {
  script_argument <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(script_argument) != 1L)
    stop("Could not determine the Step4 script location.", call. = FALSE)
  script_path <- normalizePath(sub("^--file=", "", script_argument), mustWork = TRUE)
  previous_working_dir <- setwd(dirname(script_path))
  on.exit(setwd(previous_working_dir), add = TRUE)

  args <- commandArgs(trailingOnly = TRUE)
  if (any(startsWith(args, "--")) || length(args) > 1L)
    stop("Usage: Rscript --vanilla step4_generate_portfolio_replay_and_weights.R [OUTPUT_DIR]",
      call. = FALSE)
  output_dir <- if (length(args)) args[[1L]] else "output"
  if (!dir.exists(output_dir))
    stop("Step4 input/output directory does not exist: ", output_dir, call. = FALSE)

  source(file.path("R", "functions-config.R"))
  source(file.path("R", "functions-score-storage.R"))
  source(file.path("R", "functions-fetch.R"))
  source(file.path("R", "functions-hyperparam-runtime.R"))
  source(file.path("R", "functions-inputs.R"))

  if (!requireNamespace("groundhog", quietly = TRUE)) install.packages("groundhog")
  suppressPackageStartupMessages(library(groundhog))
  groundhog.library(c("httr2", "readxl"), "2025-06-01")

  params <- read_pipeline_parameters("parameters.csv")
  generate_current_portfolio(output_dir, params)
}

main()
