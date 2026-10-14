########
# Standalone: download recent scores and generate an EW(pos) D60+|W9 portfolio.
#
# Built on R 4.5.2. All application code is in this file; no R/ helpers are loaded.
# Inputs: parameters.csv and Optimize-Me.xlsx (Models sheet).
# Optional: output/scores/d60_combined_scores.csv, read-only, for exact cells
# missing from the API. Step 1 is not required when the API supplies those cells.
#
# Rule: average the nine D60 cells at t-64 through t-72 for each model.
# Every cell must be finite. Only Models sheet Include? = Yes models can enter;
# include strictly positive means with equal weights.
# One positive model is enough; zero means a header-only portfolio CSV.
#
# Output: output_standalone/portfolio_<roundnr>.csv, plus a .last-successful
# backup on same-round reruns. All output is flat. No replay, plots, or Stan.
# Usage: Rscript.exe --vanilla step_standalone.R [OUTPUT_DIR]
########

# -------------------- Parameters and roster --------------------
standalone_read_config <- function(path = "parameters.csv") {
  params <- utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
  names(params) <- tolower(trimws(names(params)))
  if (!all(c("parameter", "value") %in% names(params)) ||
      anyDuplicated(trimws(params$parameter))) {
    stop("Parameters need unique Parameter keys and a Value column.", call. = FALSE)
  }
  value <- function(key) {
    result <- trimws(as.character(params$value[trimws(params$parameter) == key]))
    if (length(result) != 1L) stop("Missing parameter: ", key, call. = FALSE)
    if (is.na(result)) "" else result
  }
  number <- function(key, integer = FALSE, minimum = 0) {
    result <- suppressWarnings(as.numeric(value(key)))
    if (!is.finite(result) || result < minimum ||
        (integer && (result != floor(result) || result > .Machine$integer.max))) {
      stop("Invalid numeric parameter: ", key, call. = FALSE)
    }
    if (integer) as.integer(result) else result
  }
  fixed <- c(selection_score_day = 60L, final_score_day = 60L,
             historical_window = 9L, score_availability_buffer_rounds = 4L,
             min_models_per_cell = 0L)
  for (key in names(fixed)) {
    if (number(key, integer = TRUE) != fixed[[key]])
      stop("Standalone requires EW(pos) D60+|W9, t-64 through t-72, with a zero floor.",
           call. = FALSE)
  }
  if (value("corr_metric_version") != "0" || value("mmc_metric_version") != "0")
    stop("Standalone requires metric version 0.", call. = FALSE)
  corr_metric <- value("corr_metric_name")
  mmc_metric <- value("mmc_metric_name")
  if (!nzchar(corr_metric) || !nzchar(mmc_metric) || corr_metric == mmc_metric)
    stop("CORR and MMC need distinct, nonempty metric names.", call. = FALSE)
  excluded <- tolower(trimws(strsplit(value("model_names_to_exclude"), ",", fixed = TRUE)[[1L]]))
  list(
    tournament_id = number("tournament_id", integer = TRUE, minimum = 1),
    last_n_rounds = number("daily_refresh_rounds", integer = TRUE, minimum = 73),
    request_pause_seconds = number("request_pause_seconds"),
    corr_metric_name = corr_metric, mmc_metric_name = mmc_metric,
    corr_multiplier = number("corr_multiplier"),
    mmc_multiplier = number("mmc_multiplier"),
    model_names_to_exclude = unique(excluded[nzchar(excluded)])
  )
}

standalone_prepare_model_df <- function(workbook_models, excluded_models) {
  if (!is.data.frame(workbook_models) || ncol(workbook_models) < 2L)
    stop("The Models sheet must contain model names and starting rounds.", call. = FALSE)
  models <- data.frame(
    name = tolower(trimws(as.character(workbook_models[[1L]]))),
    start = suppressWarnings(as.numeric(as.character(workbook_models[[2L]])))
  )
  named_rows <- !is.na(models$name) & nzchar(models$name)
  models <- models[named_rows, , drop = FALSE]
  if (!nrow(models)) stop("The Models sheet has no candidate models.", call. = FALSE)
  if (any(!is.finite(models$start) | models$start < 1 |
      models$start != floor(models$start) | models$start > .Machine$integer.max))
    stop("Every configured model must have a positive integer starting round.", call. = FALSE)
  if (anyDuplicated(models$name))
    stop("Duplicate Models sheet model names after lowercasing.", call. = FALSE)
  include_column <- which(tolower(trimws(names(workbook_models))) == "include?")
  if (length(include_column) != 1L)
    stop("Models sheet must contain one Include? column with Yes or No values.", call. = FALSE)
  include <- tolower(trimws(as.character(workbook_models[[include_column]][named_rows])))
  if (any(is.na(include) | !include %in% c("yes", "no")))
    stop("Include? must be Yes or No for every named model.", call. = FALSE)
  models$start <- as.integer(models$start)
  models <- models[include == "yes" & !models$name %in% excluded_models, , drop = FALSE]
  rownames(models) <- NULL
  models
}

# -------------------- Public Numerai API --------------------
standalone_query <- function(query, variables = list()) {
  response <- httr2::request("https://api-tournament.numer.ai/") |>
    httr2::req_body_json(list(query = query, variables = variables)) |>
    httr2::req_timeout(seconds = 180) |>
    httr2::req_retry(max_tries = 5L, retry_on_failure = TRUE,
      is_transient = function(response)
        httr2::resp_status(response) %in% c(429L, 500L, 502L, 503L, 504L)) |>
    httr2::req_perform() |>
    httr2::resp_body_json(simplifyVector = FALSE)
  if (length(response$errors))
    stop("Numerai API error: ", paste(vapply(response$errors, function(x) x$message,
      character(1L)), collapse = "; "), call. = FALSE)
  if (is.null(response$data)) stop("Numerai API response has no data.", call. = FALSE)
  response$data
}

standalone_current_round <- function(config, query_runner = standalone_query) {
  data <- query_runner(paste(
    "query CurrentRound($tournament: Int!) {",
    "rounds(tournament: $tournament, number: 0) { number } }"
  ), list(tournament = config$tournament_id))
  if (length(data$rounds) != 1L)
    stop("Numerai did not return one current round.", call. = FALSE)
  round <- data$rounds[[1L]]$number
  if (length(round) != 1L || !is.numeric(round) || !is.finite(round) ||
      round < 1 || round != floor(round) || round > .Machine$integer.max)
    stop("Numerai returned an invalid current round.", call. = FALSE)
  as.integer(round)
}

# Pair CORR and MMC from the same model request, submission, round, timestamp,
# and D60 maturity. Never combine different submissions or scoring timestamps.
standalone_combine_d60 <- function(corr_records, mmc_records, config, source_rounds) {
  parse_metric <- function(records, metric) {
    if (!length(records)) return(data.frame(
      round = integer(), value = numeric(), key = character()))
    scalar <- function(x) if (is.null(x) || !length(x)) NA_character_ else as.character(x[[1L]])
    rows <- do.call(rbind, lapply(records, function(record) data.frame(
      round = suppressWarnings(as.numeric(scalar(record$roundNumber))),
      day = suppressWarnings(as.numeric(scalar(record$day))),
      submission = scalar(record$submissionId), date = scalar(record$date),
      metric = scalar(record$displayName), version = scalar(record$version),
      value = suppressWarnings(as.numeric(scalar(record$value)))
    )))
    keys <- c("round", "day", "submission", "date", "metric", "version")
    if (anyNA(rows[keys]) || any(!is.finite(rows$round)) ||
        any(rows$round < 1 | rows$round != floor(rows$round)) ||
        any(!is.finite(rows$day)) || any(rows$day < 1 | rows$day != floor(rows$day)) ||
        any(!nzchar(rows$submission)) || any(!grepl("^\\d{4}-\\d{2}-\\d{2}T", rows$date)))
      stop("Numerai returned invalid score identifiers.", call. = FALSE)
    if (any(rows$metric != metric) || any(rows$version != "0"))
      stop("Numerai returned an unexpected score metric or version.", call. = FALSE)
    rows <- rows[rows$day == 60L & rows$round %in% source_rounds, , drop = FALSE]
    rows$key <- paste(rows$round, rows$day, rows$submission, rows$date, sep = "\u001f")
    if (anyDuplicated(rows$key)) stop("Duplicate D60 metric events.", call. = FALSE)
    rows[c("round", "value", "key")]
  }
  corr <- parse_metric(corr_records, config$corr_metric_name)
  mmc <- parse_metric(mmc_records, config$mmc_metric_name)
  matches <- match(corr$key, mmc$key)
  paired <- !is.na(matches) & is.finite(corr$value) & is.finite(mmc$value[matches])
  rounds <- corr$round[paired]
  if (anyDuplicated(rounds)) stop("Multiple complete D60 pairs for one round.", call. = FALSE)
  scores <- config$corr_multiplier * corr$value[paired] +
    config$mmc_multiplier * mmc$value[matches[paired]]
  scores[match(source_rounds, rounds)]
}

standalone_download_d60 <- function(model_df, current_round, config,
                                    query_runner = standalone_query) {
  panel <- data.frame(roundNumber = current_round - 72:64)
  query <- paste(
    "query StandaloneScores($modelId: ID!, $tournament: Int!, $lastNRounds: Int!,",
    "$corrMetric: String!, $mmcMetric: String!) {",
    "corr: submissionScores(modelId: $modelId, tournament: $tournament,",
    "displayName: $corrMetric, version: \"0\", lastNRounds: $lastNRounds, distinctOnRound: false)",
    "{ roundNumber day submissionId date displayName version value }",
    "mmc: submissionScores(modelId: $modelId, tournament: $tournament,",
    "displayName: $mmcMetric, version: \"0\", lastNRounds: $lastNRounds, distinctOnRound: false)",
    "{ roundNumber day submissionId date displayName version value } }"
  )
  for (i in seq_len(nrow(model_df))) {
    model <- model_df$name[[i]]
    message("Downloading ", i, "/", nrow(model_df), ": ", model, "...")
    profile <- query_runner(paste(
      "query ModelId($modelName: String!) { v3UserProfile(modelName: $modelName) { id } }"
    ), list(modelName = model))
    id <- profile$v3UserProfile$id
    if (length(id) != 1L || is.na(id) || !nzchar(id))
      stop("Numerai model not found: ", model, call. = FALSE)
    data <- query_runner(query, list(modelId = id, tournament = config$tournament_id,
      lastNRounds = config$last_n_rounds, corrMetric = config$corr_metric_name,
      mmcMetric = config$mmc_metric_name))
    panel[[model]] <- standalone_combine_d60(data$corr, data$mmc, config, panel$roundNumber)
    if (config$request_pause_seconds > 0) Sys.sleep(config$request_pause_seconds)
  }
  panel
}

# -------------------- Exact cells and equal weights --------------------
standalone_exact_cells <- function(panel, models, rounds) {
  cells <- matrix(NA_real_, length(rounds), length(models), dimnames = list(NULL, models))
  if (is.null(panel)) return(cells)
  if (!is.data.frame(panel) || !"roundNumber" %in% names(panel) ||
      anyDuplicated(names(panel)) || !is.numeric(panel$roundNumber) ||
      any(!is.finite(panel$roundNumber)) ||
      any(panel$roundNumber != floor(panel$roundNumber)) || anyDuplicated(panel$roundNumber))
    stop("D60 panel has invalid or duplicate rounds/columns.", call. = FALSE)
  for (model in intersect(models, names(panel))) {
    values <- panel[[model]]
    if (!is.numeric(values) && !(is.logical(values) && all(is.na(values))))
      stop("D60 panel has nonnumeric scores for ", model, call. = FALSE)
    cells[, model] <- values[match(rounds, panel$roundNumber)]
  }
  cells
}

standalone_weights <- function(cells, current_round, generated_at_utc) {
  # Rows are newest to oldest, matching Step 4's addition order exactly.
  signal <- Reduce("+", lapply(seq_len(nrow(cells)), function(i) cells[i, ])) / 9
  complete <- is.finite(signal) & colSums(is.finite(cells)) == 9L
  selected <- complete & signal > 0
  models <- as.character(colnames(cells)[selected])
  values <- as.numeric(signal[selected])
  order <- order(-values, models)
  n <- length(models)
  data.frame(
    generated_at_utc = rep(generated_at_utc, n),
    strategy = rep("ewpos_d60plus_w9", n),
    intended_round = rep(as.integer(current_round), n),
    expected_signal_round = rep(as.integer(current_round - 64L), n),
    signal_round = rep(as.integer(current_round - 64L), n),
    signal_fallback_rounds = rep(0L, n), signal_score_day = rep(60L, n),
    historical_window = rep(9L, n), availability_buffer_rounds = rep(4L, n),
    source_round_lag = rep(64L, n), effective_source_round_lag = rep(64L, n),
    complete_models = rep(sum(complete), n), selected_models = rep(n, n),
    model = models[order], signal_combined_score = values[order],
    weight = rep(1 / n, n), signal_rank = seq_len(n), check.names = FALSE
  )
}

# -------------------- Download and publish one current-round portfolio --------------------
standalone_refresh_portfolio <- function(config, model_df, output_dir, archive_dir = "output",
    current_round_function = function() standalone_current_round(config),
    panel_builder = standalone_download_d60, clock_function = Sys.time) {
  current_round <- current_round_function()
  if (length(current_round) != 1L || !is.numeric(current_round) ||
      !is.finite(current_round) || current_round < 73L ||
      current_round != floor(current_round) || current_round > .Machine$integer.max)
    stop("Portfolio needs a valid current round with nine source rounds.", call. = FALSE)
  destination <- file.path(output_dir, paste0("portfolio_", current_round, ".csv"))
  if (file.exists(destination)) {
    if (!file.copy(destination, paste0(destination, ".last-successful"), overwrite = TRUE))
      stop("Could not preserve the previous portfolio.", call. = FALSE)
    if (!file.remove(destination)) stop("Could not invalidate stale weights.", call. = FALSE)
  }

  rounds <- current_round - 64:72
  models <- model_df$name
  message("Standalone: target ", current_round, "; exact D60 source rounds ",
          min(rounds), " through ", max(rounds), ".")
  cells <- matrix(NA_real_, length(rounds), length(models), dimnames = list(NULL, models))
  if (length(models)) {
    live <- panel_builder(model_df = model_df, current_round = current_round, config = config)
    path <- file.path(archive_dir, "scores", "d60_combined_scores.csv")
    archived <- if (file.exists(path)) utils::read.csv(path, check.names = FALSE) else NULL
    cells <- standalone_exact_cells(archived, models, rounds)
    fresh <- standalone_exact_cells(live, models, rounds)
    cells[is.finite(fresh)] <- fresh[is.finite(fresh)]
    # Apply the start boundary once to the combined fresh/archive window.
    for (i in seq_along(models)) cells[rounds < model_df$start[[i]], i] <- NA_real_
  }
  message("Complete nine-cell histories: ", sum(colSums(is.finite(cells)) == 9L),
          "/", length(models), " models after archive overlay.")
  weights <- standalone_weights(cells, current_round,
    format(clock_function(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"))

  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  staged <- tempfile("portfolio-", tmpdir = output_dir, fileext = ".tmp")
  on.exit(unlink(staged), add = TRUE)
  utils::write.csv(weights, staged, row.names = FALSE, na = "")
  publication_round <- current_round_function()
  if (length(publication_round) != 1L || !is.finite(publication_round) ||
      publication_round != current_round)
    stop("Round changed during refresh; stale weights are refused.", call. = FALSE)
  if (!file.rename(staged, destination)) stop("Could not publish portfolio.", call. = FALSE)
  list(weights = weights, output_path = destination, intended_round = current_round)
}

# -------------------- Run from the command line --------------------
if (sys.nframe() == 0L) {
  script <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(script) != 1L) stop("Cannot determine script location.")
  setwd(dirname(normalizePath(sub("^--file=", "", script), mustWork = TRUE)))
  args <- commandArgs(TRUE)
  if (length(args) > 1L) stop("Usage: Rscript step_standalone.R [OUTPUT_DIR]")
  output_dir <- if (length(args)) args[[1L]] else "output_standalone"

  if (!requireNamespace("groundhog", quietly = TRUE)) install.packages("groundhog")
  suppressPackageStartupMessages(library(groundhog))
  groundhog.library(c("readxl", "httr2"), "2025-06-01")

  config <- standalone_read_config()
  workbook <- as.data.frame(readxl::read_excel("Optimize-Me.xlsx", sheet = "Models"))
  models <- standalone_prepare_model_df(workbook, config$model_names_to_exclude)
  result <- standalone_refresh_portfolio(config, models, output_dir)
  message("Standalone complete: ", nrow(result$weights), " equally weighted models for round ",
    result$intended_round, ". Portfolio: ", result$output_path)
  if (!nrow(result$weights)) message("No positive D60+|W9 models: header-only portfolio; no submission.")
}
