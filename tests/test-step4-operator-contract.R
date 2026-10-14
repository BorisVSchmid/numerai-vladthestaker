source("R/functions-config.R")
source("R/functions-score-storage.R")
source("R/functions-hyperparam-runtime.R")
source("R/functions-inputs.R")
source("tests/load-step-functions.R", local = TRUE)
load_step_functions("step4_generate_portfolio_replay_and_weights.R")

expect_error <- function(expression, pattern) {
  error <- tryCatch({force(expression); NA_character_}, error = conditionMessage)
  stopifnot(!is.na(error), grepl(pattern, error, fixed = TRUE))
}
for (invalid_round in list(NA_real_, Inf, 0L, -1L, 250.5, c(250L, 251L), "250"))
  expect_error(portfolio_filename(invalid_round), "positive integer round")

# Run the actual portfolio workflow offline. Only source-window scores exist:
# historical replay outcomes and figures are not needed to publish live weights.
local({
  workspace <- tempfile("step4-portfolio-")
  dir.create(workspace)
  on.exit(unlink(workspace, recursive = TRUE), add = TRUE)
  params <- read_pipeline_parameters("parameters.csv")
  params$value[params$parameter == "base_round"] <- "100"
  panels <- setNames(lapply(maturity_score_artifact_names(), function(name) {
    data.frame(roundNumber = 100:210, model_a = NA_real_, model_b = NA_real_,
      model_c = NA_real_)
  }), names(maturity_score_artifact_names()))
  panels$d60[panels$d60$roundNumber %in% 138:146, -1L] <-
    rep(c(.05, -.01, .06), each = 9L)
  write_maturity_score_panels <- function() {
    paths <- maturity_score_artifact_paths(workspace)
    for (name in names(paths)) write_csv_safely(panels[[name]], paths[[name]])
  }
  write_maturity_score_panels()
  clock <- function() as.POSIXct("2026-10-12", tz = "UTC")
  roster <- data.frame(name = c("model_a", "model_b", "model_c"), start = 100L)
  roster[["Include?"]] <- "Yes"
  run <- function(round_function = function()210L) {
    generate_current_portfolio(workspace, params, round_function, clock, roster)
  }
  result <- run()
  expected_columns <- c(
    "generated_at_utc", "strategy", "intended_round", "expected_signal_round",
    "signal_round", "signal_fallback_rounds", "signal_score_day",
    "historical_window", "availability_buffer_rounds", "source_round_lag",
    "effective_source_round_lag", "complete_models", "selected_models", "model",
    "signal_combined_score", "weight", "signal_rank"
  )
  portfolio <- utils::read.csv(result$output_path, check.names = FALSE)
  stopifnot(identical(names(portfolio), expected_columns),
    identical(portfolio$model, c("model_c", "model_a")),
    all(portfolio$weight == .5), all(portfolio$intended_round == 210L),
    all(portfolio$signal_round == 146L), all(portfolio$historical_window == 9L),
    identical(portfolio$signal_rank, 1:2),
    identical(list.files(file.path(workspace, "portfolio")), "portfolio_210.csv"))

  # Initial API failure preserves saved weights; failures after identifying the
  # target invalidate only that round and retain its previous-success backup.
  expect_error(run(function()stop("Initial API failure")), "Initial API failure")
  stopifnot(identical(utils::read.csv(result$output_path, check.names = FALSE), portfolio))
  earlier <- file.path(dirname(result$output_path), portfolio_filename(209L))
  earlier_portfolio <- portfolio
  earlier_portfolio$intended_round <- 209L
  write_csv_safely(earlier_portfolio, earlier)
  earlier_saved <- utils::read.csv(earlier, check.names = FALSE)
  changed_round <- local({
    round <- 210L
    function() {previous <- round; round <<- 211L; previous}
  })
  expect_error(run(changed_round), "stale weights are refused")
  stopifnot(!file.exists(result$output_path),
    identical(utils::read.csv(paste0(result$output_path, ".last-successful"), check.names = FALSE),
      portfolio))

  run()
  failed_recheck <- local({
    initial <- TRUE
    function() {
      if (!initial) stop("Publication API failure")
      initial <<- FALSE
      210L
    }
  })
  expect_error(run(failed_recheck), "Publication API failure")
  stopifnot(!file.exists(result$output_path), file.exists(paste0(result$output_path, ".last-successful")))

  run()
  paths <- maturity_score_artifact_paths(workspace)
  broken <- panels$d60
  broken$model_a <- "invalid"
  write_csv_safely(broken, paths[["d60"]])
  expect_error(run(), "non-numeric model column")
  stopifnot(!file.exists(result$output_path))
  write_maturity_score_panels()

  # Workbook permission overrides a positive signal without changing score data.
  roster[["Include?"]][roster$name == "model_c"] <- "No"
  restricted <- run()
  stopifnot(identical(restricted$weights$model, "model_a"), restricted$weights$weight == 1,
    restricted$weights$complete_models == 2L)
  roster[["Include?"]] <- "No"
  disabled <- run()
  stopifnot(nrow(utils::read.csv(disabled$output_path)) == 0L)
  roster[["Include?"]] <- "Yes"

  # One model, no positives, and all incomplete windows retain the CSV contract.
  panels$d60$model_c <- -.02
  write_maturity_score_panels()
  one <- run()
  stopifnot(identical(one$weights$model, "model_a"), one$weights$weight == 1)
  panels$d60$model_a <- -.01
  write_maturity_score_panels()
  empty <- run()
  saved <- utils::read.csv(empty$output_path, check.names = FALSE)
  stopifnot(nrow(saved) == 0L, identical(names(saved), expected_columns))
  panels$d60[panels$d60$roundNumber == 146L, -1L] <- NA_real_
  write_maturity_score_panels()
  incomplete <- run()
  stopifnot(nrow(incomplete$weights) == 0L, file.exists(incomplete$output_path),
    identical(utils::read.csv(earlier, check.names = FALSE), earlier_saved))
})
