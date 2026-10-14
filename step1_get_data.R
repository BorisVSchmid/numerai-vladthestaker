########
# Download maturity-aware Numerai model score events and publish exact paired
# D38 through D57 signal-maturity panels and the D60 outcome panel.
# Inputs: parameters.csv, Optimize-Me.xlsx Models sheet, cached histories, public API.
# Outputs: data/model_history/ and output/scores/; preserve raw score events.
########

# -------------------- Dependencies --------------------
message("Step1: loading R packages...")
if (!requireNamespace("groundhog", quietly = TRUE)) install.packages("groundhog")
library(groundhog)

groundhog.library(c("readxl", "httr2"), "2025-06-01")

source(file.path("R", "functions-config.R"))
source(file.path("R", "functions-score-storage.R"))
source(file.path("R", "functions-fetch.R"))
source(file.path("R", "functions-hyperparam-runtime.R"))
source(file.path("R", "functions-inputs.R"))


# -------------------- Canonical score events and archive helpers --------------------
score_event_columns <- c(
  "first_downloaded_at_utc",
  "last_downloaded_at_utc",
  "download_current_round",
  "tournament_id",
  "model_name",
  "model_id",
  "submission_id",
  "round_number",
  "score_date_utc",
  "score_day",
  "metric_name",
  "metric_version",
  "value",
  "percentile",
  "score_resolved",
  "score_resolve_date_utc",
  "round_close_staking_time_utc",
  "round_score_time_utc",
  "round_resolve_time_utc"
)


empty_score_event_history <- function() {
  data.frame(
    first_downloaded_at_utc = character(),
    last_downloaded_at_utc = character(),
    download_current_round = integer(),
    tournament_id = integer(),
    model_name = character(),
    model_id = character(),
    submission_id = character(),
    round_number = integer(),
    score_date_utc = character(),
    score_day = integer(),
    metric_name = character(),
    metric_version = character(),
    value = numeric(),
    percentile = numeric(),
    score_resolved = logical(),
    score_resolve_date_utc = character(),
    round_close_staking_time_utc = character(),
    round_score_time_utc = character(),
    round_resolve_time_utc = character(),
    stringsAsFactors = FALSE
  )
}


score_event_key <- function(events) {
  key_columns <- c(
    "model_id",
    "submission_id",
    "round_number",
    "score_date_utc",
    "score_day",
    "metric_name",
    "metric_version"
  )
  if (!all(key_columns %in% names(events))) {
    stop("Score events do not contain every event-key column.", call. = FALSE)
  }
  if (nrow(events) && anyNA(events[, key_columns, drop = FALSE])) {
    stop("A score event has a missing event-key field.", call. = FALSE)
  }
  do.call(paste, c(events[key_columns], sep = "\u001f"))
}


score_pair_key <- function(events) {
  pair_columns <- c(
    "model_id",
    "submission_id",
    "round_number",
    "score_date_utc",
    "score_day"
  )
  if (!all(pair_columns %in% names(events))) {
    stop("Score events do not contain every metric-pair column.", call. = FALSE)
  }
  do.call(paste, c(events[pair_columns], sep = "\u001f"))
}


validate_score_event_history <- function(events, context = "Score-event history") {
  if (!is.data.frame(events) || !identical(names(events), score_event_columns)) {
    stop(context, " does not have the expected columns.", call. = FALSE)
  }
  if (!nrow(events)) return(invisible(events))

  keys <- score_event_key(events)
  if (anyDuplicated(keys)) {
    stop(context, " contains duplicate metric maturity events.", call. = FALSE)
  }
  if (
    any(is.na(events$model_name) | events$model_name == "") ||
      any(events$model_name != tolower(events$model_name)) ||
      any(is.na(events$model_id) | events$model_id == "") ||
      any(is.na(events$submission_id) | events$submission_id == "") ||
      any(!is.finite(events$download_current_round)) ||
      any(!is.finite(events$tournament_id)) ||
      any(!is.finite(events$round_number)) ||
      any(!is.finite(events$score_day)) ||
      any(events$score_day < 1L) ||
      any(is.na(events$metric_name) | events$metric_name == "") ||
      any(is.na(events$metric_version) | events$metric_version == "")
  ) {
    stop(context, " contains invalid identifiers or numeric keys.", call. = FALSE)
  }
  if (any(!grepl("^\\d{4}-\\d{2}-\\d{2}T", events$score_date_utc))) {
    stop(context, " contains a score event without an ISO timestamp.", call. = FALSE)
  }
  invisible(events)
}


merge_score_event_history <- function(existing_events, downloaded_events) {
  # Cache reads and API downloads validate their inputs before merging.
  if (!nrow(downloaded_events)) return(existing_events)

  existing_keys <- score_event_key(existing_events)
  downloaded_keys <- score_event_key(downloaded_events)
  existing_rows <- match(downloaded_keys, existing_keys)
  matched <- !is.na(existing_rows)
  downloaded_events$first_downloaded_at_utc[matched] <-
    existing_events$first_downloaded_at_utc[existing_rows[matched]]

  retained <- existing_events[
    !existing_keys %in% downloaded_keys,
    ,
    drop = FALSE
  ]
  merged <- rbind(retained, downloaded_events)
  merged <- merged[order(
    merged$model_name,
    merged$round_number,
    merged$score_day,
    merged$metric_name,
    merged$score_date_utc
  ), , drop = FALSE]
  rownames(merged) <- NULL
  validate_score_event_history(merged, "Merged score-event history")
  merged
}


write_rds_safely <- function(object, path) {
  output_dir <- dirname(path)
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  temporary_path <- tempfile(
    pattern = paste0(basename(path), "."),
    tmpdir = output_dir,
    fileext = ".tmp"
  )
  on.exit(unlink(temporary_path), add = TRUE)
  saveRDS(object, temporary_path, compress = "gzip")
  publish_staged_files(temporary_path, path)
  invisible(path)
}


read_model_score_history <- function(path) {
  if (!file.exists(path)) return(empty_score_event_history())
  events <- readRDS(path)
  validate_score_event_history(events, paste0("Model cache `", path, "`"))
  events
}


combined_score_cells <- function(events, score_config) {
  if (!nrow(events)) {
    return(data.frame(
      model_name = character(),
      model_id = character(),
      round_number = integer(),
      score_day = integer(),
      score_date_utc = character(),
      combined_score = numeric(),
      stringsAsFactors = FALSE
    ))
  }

  target_days <- as.integer(sub("d", "", names(maturity_score_artifact_names())))
  corr <- events[
    events$metric_name == score_config$corr_metric_name &
      as.character(events$metric_version) == score_config$corr_metric_version &
      events$score_day %in% target_days,
    ,
    drop = FALSE
  ]
  mmc <- events[
    events$metric_name == score_config$mmc_metric_name &
      as.character(events$metric_version) == score_config$mmc_metric_version &
      events$score_day %in% target_days,
    ,
    drop = FALSE
  ]
  corr_keys <- score_pair_key(corr)
  mmc_keys <- score_pair_key(mmc)
  if (anyDuplicated(corr_keys) || anyDuplicated(mmc_keys)) {
    stop("A model has duplicate CORR or MMC events for one maturity cell.", call. = FALSE)
  }

  paired_corr <- which(corr_keys %in% mmc_keys)
  if (!length(paired_corr)) {
    return(data.frame(
      model_name = character(),
      model_id = character(),
      round_number = integer(),
      score_day = integer(),
      score_date_utc = character(),
      combined_score = numeric(),
      stringsAsFactors = FALSE
    ))
  }
  corr <- corr[paired_corr, , drop = FALSE]
  corr_keys <- corr_keys[paired_corr]
  mmc <- mmc[match(corr_keys, mmc_keys), , drop = FALSE]
  finite_pair <- is.finite(corr$value) & is.finite(mmc$value)
  corr <- corr[finite_pair, , drop = FALSE]
  mmc <- mmc[finite_pair, , drop = FALSE]

  cells <- data.frame(
    model_name = as.character(corr$model_name),
    model_id = as.character(corr$model_id),
    round_number = as.integer(corr$round_number),
    score_day = as.integer(corr$score_day),
    score_date_utc = as.character(corr$score_date_utc),
    combined_score =
      score_config$corr_multiplier * as.numeric(corr$value) +
      score_config$mmc_multiplier * as.numeric(mmc$value),
    stringsAsFactors = FALSE
  )
  cell_keys <- paste(cells$model_id, cells$round_number, cells$score_day, sep = "\u001f")
  if (anyDuplicated(cell_keys)) {
    stop(
      "A model has more than one complete CORR/MMC pair for one round and maturity.",
      call. = FALSE
    )
  }
  cells[order(cells$model_name, cells$round_number, cells$score_day), , drop = FALSE]
}


materialize_maturity_score_panels <- function(
  model_histories,
  model_df,
  min_from_round,
  current_round,
  score_config
) {
  model_names <- tolower(trimws(as.character(model_df$name)))
  if (
    !length(model_names) || any(is.na(model_names) | model_names == "") ||
      anyDuplicated(model_names) || is.null(names(model_histories)) ||
      !identical(names(model_histories), model_names)
  ) {
    stop("Model histories must be named in exact lower-case roster order.", call. = FALSE)
  }
  min_from_round <- as.integer(min_from_round)
  current_round <- as.integer(current_round)
  if (
    !is.finite(min_from_round) || !is.finite(current_round) ||
      min_from_round > current_round
  ) {
    stop("Panel round bounds are invalid.", call. = FALSE)
  }
  round_values <- seq.int(min_from_round, current_round)
  empty_panel <- data.frame(roundNumber = round_values, check.names = FALSE)
  panel_names <- names(maturity_score_artifact_names())
  panels <- setNames(rep(list(empty_panel), length(panel_names)), panel_names)
  target_days <- setNames(as.integer(sub("d", "", panel_names)), panel_names)

  for (model_index in seq_along(model_names)) {
    model_name <- model_names[[model_index]]
    history <- model_histories[[model_name]]
    if (nrow(history) && any(history$model_name != model_name)) {
      stop("A model history does not match roster name `", model_name, "`.", call. = FALSE)
    }
    cells <- combined_score_cells(history, score_config)
    for (panel_name in names(target_days)) {
      day_cells <- cells[
        cells$score_day == target_days[[panel_name]] &
          cells$round_number >= min_from_round &
          cells$round_number >= model_df$start[[model_index]] &
          cells$round_number <= current_round,
        ,
        drop = FALSE
      ]
      if (anyDuplicated(day_cells$round_number)) {
        stop(
          "Model `", model_name, "` has duplicate D", target_days[[panel_name]],
          " round cells.",
          call. = FALSE
        )
      }
      values <- rep(NA_real_, length(round_values))
      if (nrow(day_cells)) {
        values[match(day_cells$round_number, round_values)] <- day_cells$combined_score
      }
      panels[[panel_name]][[model_name]] <- values
    }
  }
  validate_maturity_score_panels(panels)
}


write_maturity_score_panels <- function(panels, output_dir) {
  # Materialization validates the panels; CSV writing fails on write errors.
  artifact_names <- maturity_score_artifact_names()
  paths <- maturity_score_artifact_paths(output_dir)
  dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
  stage_dir <- tempfile("maturity-panels-", tmpdir = output_dir)
  dir.create(stage_dir, recursive = TRUE, showWarnings = FALSE)
  if (!dir.exists(stage_dir)) {
    stop("Could not create the maturity-panel staging directory.", call. = FALSE)
  }
  on.exit(unlink(stage_dir, recursive = TRUE, force = TRUE), add = TRUE)
  staged_paths <- file.path(stage_dir, unname(artifact_names))
  names(staged_paths) <- names(artifact_names)
  for (panel_name in names(artifact_names)) {
    write_csv_safely(panels[[panel_name]], staged_paths[[panel_name]])
  }
  publish_staged_files(staged_paths, paths)
  invisible(paths)
}


# -------------------- Model-score download helpers --------------------
fetch_model_id <- function(model_name, query_runner = run_query) {
  query <- paste(
    "query ModelId($modelName: String!) {",
    "v3UserProfile(modelName: $modelName) { id }",
    "}"
  )
  normalized_name <- tolower(trimws(as.character(model_name)))
  data <- query_runner(query, list(modelName = normalized_name))
  if (is.null(data$v3UserProfile$id)) {
    stop("Numerai model not found: ", normalized_name, call. = FALSE)
  }
  as.character(data$v3UserProfile$id)
}


build_maturity_score_query <- function() {
  paste(
    paste0(
      "query ModelMaturityScores($modelId: ID!, $tournament: Int!, ",
      "$lastNRounds: Int!, $corrMetric: String!, $corrVersion: String!, ",
      "$mmcMetric: String!, $mmcVersion: String!) {"
    ),
    "corr: submissionScores(",
    "modelId: $modelId, tournament: $tournament,",
    "displayName: $corrMetric, version: $corrVersion,",
    "lastNRounds: $lastNRounds, distinctOnRound: false",
    ") {",
    paste(
      "roundNumber date day displayName version value percentile resolved",
      "resolveDate roundCloseStakingTime roundScoreTime roundResolveTime",
      "submissionId"
    ),
    "}",
    "mmc: submissionScores(",
    "modelId: $modelId, tournament: $tournament,",
    "displayName: $mmcMetric, version: $mmcVersion,",
    "lastNRounds: $lastNRounds, distinctOnRound: false",
    ") {",
    paste(
      "roundNumber date day displayName version value percentile resolved",
      "resolveDate roundCloseStakingTime roundScoreTime roundResolveTime",
      "submissionId"
    ),
    "}",
    "}"
  )
}


json_character <- function(value) {
  if (is.null(value) || length(value) == 0L) return(NA_character_)
  as.character(value[[1L]])
}


json_integer <- function(value) {
  if (is.null(value) || length(value) == 0L) return(NA_integer_)
  as.integer(value[[1L]])
}


json_numeric <- function(value) {
  if (is.null(value) || length(value) == 0L) return(NA_real_)
  as.numeric(value[[1L]])
}


json_logical <- function(value) {
  if (is.null(value) || length(value) == 0L) return(NA)
  as.logical(value[[1L]])
}


flatten_submission_score_events <- function(
  records,
  downloaded_at_utc,
  current_round,
  tournament_id,
  model_name,
  model_id
) {
  if (!length(records)) return(empty_score_event_history())
  rows <- lapply(records, function(record) {
    data.frame(
      first_downloaded_at_utc = downloaded_at_utc,
      last_downloaded_at_utc = downloaded_at_utc,
      download_current_round = as.integer(current_round),
      tournament_id = as.integer(tournament_id),
      model_name = tolower(model_name),
      model_id = as.character(model_id),
      submission_id = json_character(record$submissionId),
      round_number = json_integer(record$roundNumber),
      score_date_utc = json_character(record$date),
      score_day = json_integer(record$day),
      metric_name = json_character(record$displayName),
      metric_version = json_character(record$version),
      value = json_numeric(record$value),
      percentile = json_numeric(record$percentile),
      score_resolved = json_logical(record$resolved),
      score_resolve_date_utc = json_character(record$resolveDate),
      round_close_staking_time_utc = json_character(record$roundCloseStakingTime),
      round_score_time_utc = json_character(record$roundScoreTime),
      round_resolve_time_utc = json_character(record$roundResolveTime),
      stringsAsFactors = FALSE
    )
  })
  events <- do.call(rbind, rows)
  rownames(events) <- NULL
  events
}


validate_downloaded_metric <- function(events, metric_name, metric_version) {
  if (!nrow(events)) return(invisible(events))
  validate_score_event_history(events, paste0("Downloaded `", metric_name, "` events"))
  if (
    any(events$metric_name != metric_name) ||
      any(as.character(events$metric_version) != as.character(metric_version))
  ) {
    stop("Numerai returned an unexpected score metric or version.", call. = FALSE)
  }
  invisible(events)
}


fetch_model_score_events <- function(
  model_name,
  from_round,
  current_round,
  score_config,
  last_n_rounds,
  model_id,
  downloaded_at_utc,
  query_runner = run_query
) {
  model_name <- tolower(trimws(as.character(model_name)))
  from_round <- as.integer(from_round)
  current_round <- as.integer(current_round)
  if (
    length(model_name) != 1L || is.na(model_name) || !nzchar(model_name) ||
      !is.finite(from_round) || !is.finite(current_round) ||
      from_round > current_round
  ) {
    stop("Model score-event request inputs are invalid.", call. = FALSE)
  }
  required_span <- current_round - from_round + 1L
  last_n_rounds <- as.integer(last_n_rounds)
  if (!is.finite(last_n_rounds) || last_n_rounds < required_span) {
    stop(
      "last_n_rounds must cover every requested round through current_round.",
      call. = FALSE
    )
  }
  model_id <- as.character(model_id)
  if (length(model_id) != 1L || is.na(model_id) || !nzchar(model_id)) {
    stop("A score-event request requires one non-empty model ID.", call. = FALSE)
  }

  data <- query_runner(
    build_maturity_score_query(),
    list(
      modelId = model_id,
      tournament = as.integer(score_config$tournament_id),
      lastNRounds = last_n_rounds,
      corrMetric = score_config$corr_metric_name,
      corrVersion = score_config$corr_metric_version,
      mmcMetric = score_config$mmc_metric_name,
      mmcVersion = score_config$mmc_metric_version
    )
  )
  corr <- flatten_submission_score_events(
    data$corr,
    downloaded_at_utc,
    current_round,
    score_config$tournament_id,
    model_name,
    model_id
  )
  mmc <- flatten_submission_score_events(
    data$mmc,
    downloaded_at_utc,
    current_round,
    score_config$tournament_id,
    model_name,
    model_id
  )
  corr <- corr[
    corr$round_number >= from_round & corr$round_number <= current_round,
    ,
    drop = FALSE
  ]
  mmc <- mmc[
    mmc$round_number >= from_round & mmc$round_number <= current_round,
    ,
    drop = FALSE
  ]
  validate_downloaded_metric(
    corr,
    score_config$corr_metric_name,
    score_config$corr_metric_version
  )
  validate_downloaded_metric(
    mmc,
    score_config$mmc_metric_name,
    score_config$mmc_metric_version
  )

  events <- rbind(corr, mmc)
  if (nrow(events)) {
    events <- events[order(
      events$round_number,
      events$score_day,
      events$metric_name,
      events$score_date_utc
    ), , drop = FALSE]
    rownames(events) <- NULL
  }
  events
}


# -------------------- Download progress and workflow --------------------
step1_progress <- function(...) {
  message(format(Sys.time(), "%H:%M:%S"), " | ", paste0(..., collapse = ""))
  flush.console()
}


step1_duration <- function(seconds) {
  seconds <- as.integer(max(0, round(seconds)))
  sprintf("%02d:%02d:%02d", seconds %/% 3600L,
          (seconds %% 3600L) %/% 60L, seconds %% 60L)
}


get_flag <- function(arguments, name, default = NULL) {
  prefix <- paste0("--", name, "=")
  hit <- arguments[startsWith(arguments, prefix)]
  if (!length(hit)) return(default)
  if (length(hit) > 1L) stop("Duplicate --", name, " argument.", call. = FALSE)
  sub(prefix, "", hit[[1L]], fixed = TRUE)
}


empty_download_status <- function() {
  data.frame(
    model_name = character(),
    model_id = character(),
    start_round = integer(),
    first_downloaded_at_utc = character(),
    last_downloaded_at_utc = character(),
    last_current_round = integer(),
    stringsAsFactors = FALSE
  )
}


read_download_status <- function(path) {
  if (!file.exists(path)) return(empty_download_status())
  status <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "")
  if (!identical(names(status), names(empty_download_status()))) {
    stop(path, " does not have the expected download-status columns.", call. = FALSE)
  }
  if (
    nrow(status) &&
      (anyDuplicated(status$model_id) ||
        any(is.na(status$model_id) | status$model_id == "") ||
        any(!is.finite(status$last_current_round)))
  ) {
    stop(path, " contains invalid or duplicate model status rows.", call. = FALSE)
  }
  status
}


main <- function() {
  run_started <- proc.time()[["elapsed"]]
  arguments <- commandArgs(trailingOnly = TRUE)
  allowed <- startsWith(arguments, "--output-dir=")
  if (length(arguments) && any(!allowed)) {
    stop(
      "Unknown argument(s): ", paste(arguments[!allowed], collapse = ", "),
      ". Only --output-dir=PATH is supported.",
      call. = FALSE
    )
  }
  output_dir <- get_flag(arguments, "output-dir", "output")
  parameter_path <- "parameters.csv"
  workbook_path <- "Optimize-Me.xlsx"
  data_root <- "data"
  model_history_dir <- file.path(data_root, "model_history")
  status_path <- file.path(data_root, "model_download_status.csv")
  lock_dir <- file.path(data_root, ".download-lock")

  params <- read_pipeline_parameters(parameter_path)
  step1_progress("Reading the model roster from ", workbook_path, "...")
  workbook_models <- as.data.frame(readxl::read_excel(workbook_path, sheet = "Models"))
  inputs <- check_pipeline_inputs(1L, params, output_dir, workbook_models)
  score_config <- inputs$score_config
  base_round <- inputs$base_round
  initial_history_rounds <- inputs$initial_history_rounds
  daily_refresh_rounds <- inputs$daily_refresh_rounds
  request_pause_seconds <- inputs$request_pause_seconds
  models_df <- inputs$model_df
  model_count <- nrow(models_df)
  step1_progress("Loaded ", model_count, " models. Preparing the refresh...")

  dir.create(data_root, recursive = TRUE, showWarnings = FALSE)
  if (!dir.create(lock_dir, showWarnings = FALSE)) {
    stop(
      "Another downloader holds ", lock_dir,
      ". Remove it only after confirming no download is running.",
      call. = FALSE
    )
  }
  on.exit(unlink(lock_dir, recursive = TRUE, force = TRUE), add = TRUE)
  run_stage_dir <- tempfile("score-refresh-", tmpdir = data_root)
  staged_model_history_dir <- file.path(run_stage_dir, "model_history")
  staged_output_dir <- file.path(run_stage_dir, "output")
  staged_status_path <- file.path(run_stage_dir, "model_download_status.csv")
  dir.create(staged_model_history_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(staged_output_dir, recursive = TRUE, showWarnings = FALSE)
  if (!all(dir.exists(c(staged_model_history_dir, staged_output_dir)))) {
    stop("Could not create the full-refresh staging area.", call. = FALSE)
  }
  on.exit(unlink(run_stage_dir, recursive = TRUE, force = TRUE), add = TRUE)

  step1_progress("Requesting the current Numerai round...")
  current_round <- fetch_current_round(score_config$tournament_id)
  if (current_round < base_round) {
    stop("The current Numerai round precedes base_round.", call. = FALSE)
  }
  step1_progress("Frozen Numerai round: ", current_round, ". Resolving model IDs...")
  downloaded_at_utc <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  model_ids <- vapply(seq_len(model_count), function(i) {
    step1_progress("[Lookup ", i, "/", model_count, "] ", models_df$name[[i]])
    fetch_model_id(models_df$name[[i]])
  }, character(1L))
  if (anyDuplicated(model_ids)) {
    stop("Two configured model names resolve to the same Numerai model ID.", call. = FALSE)
  }
  models_df$model_id <- model_ids
  step1_progress("Model IDs resolved. Starting score downloads; completed models are staged until publication.")

  status <- read_download_status(status_path)
  histories <- stats::setNames(vector("list", nrow(models_df)), models_df$name)
  new_status_rows <- vector("list", nrow(models_df))
  dir.create(model_history_dir, recursive = TRUE, showWarnings = FALSE)

  downloads_started <- proc.time()[["elapsed"]]
  for (model_index in seq_len(nrow(models_df))) {
    model_name <- models_df$name[[model_index]]
    model_id <- models_df$model_id[[model_index]]
    model_start_round <- max(base_round, models_df$start[[model_index]])
    cache_path <- file.path(model_history_dir, paste0(model_id, ".rds"))
    existing <- read_model_score_history(cache_path)
    if (nrow(existing)) {
      if (any(existing$model_id != model_id)) {
        stop("A model-history cache contains the wrong model ID.", call. = FALSE)
      }
      existing$model_name <- model_name
    }
    status_row <- match(model_id, status$model_id)
    previously_downloaded <- !is.na(status_row) || nrow(existing) > 0L
    if (previously_downloaded) {
      previous_current_round <- if (!is.na(status_row)) {
        as.integer(status$last_current_round[[status_row]])
      } else {
        max(as.integer(existing$download_current_round))
      }
      outage_rounds <- max(
        0L,
        current_round - previous_current_round
      )
      api_history_rounds <- daily_refresh_rounds + outage_rounds
    } else {
      full_history_rounds <- current_round - model_start_round + 1L
      api_history_rounds <- max(initial_history_rounds, full_history_rounds)
    }
    from_round <- max(
      model_start_round,
      current_round - api_history_rounds + 1L
    )
    step1_progress(
      "[Model ", model_index, "/", model_count, "] ", model_name, ": ",
      if (previously_downloaded) "refreshing" else "downloading new model history",
      " from round ", from_round, " through ", current_round,
      " (API lookback ", api_history_rounds, " rounds; ", nrow(existing), " cached events)..."
    )
    if (request_pause_seconds > 0 && model_index > 1L) {
      Sys.sleep(request_pause_seconds)
    }
    downloaded <- fetch_model_score_events(
      model_name = model_name,
      from_round = from_round,
      current_round = current_round,
      score_config = score_config,
      last_n_rounds = api_history_rounds,
      model_id = model_id,
      downloaded_at_utc = downloaded_at_utc
    )
    merged <- merge_score_event_history(existing, downloaded)
    staged_cache_path <- file.path(
      staged_model_history_dir,
      paste0(model_id, ".rds")
    )
    write_rds_safely(merged, staged_cache_path)
    histories[[model_index]] <- merged

    first_downloaded_at_utc <- downloaded_at_utc
    if (!is.na(status_row)) {
      first_downloaded_at_utc <- as.character(
        status$first_downloaded_at_utc[[status_row]]
      )
    } else if (nrow(existing)) {
      first_downloaded_at_utc <- min(existing$first_downloaded_at_utc)
    }
    new_status_rows[[model_index]] <- data.frame(
      model_name = model_name,
      model_id = model_id,
      start_round = models_df$start[[model_index]],
      first_downloaded_at_utc = first_downloaded_at_utc,
      last_downloaded_at_utc = downloaded_at_utc,
      last_current_round = current_round,
      stringsAsFactors = FALSE
    )
    download_elapsed <- proc.time()[["elapsed"]] - downloads_started
    remaining_seconds <- download_elapsed / model_index * (model_count - model_index)
    step1_progress(
      "Staged ", model_index, "/", model_count, ": ", model_name,
      " (", nrow(merged), " archived events). Elapsed ",
      step1_duration(download_elapsed), "; approximate remaining download time ",
      step1_duration(remaining_seconds), "."
    )
  }

  step1_progress("Downloads complete. Validating the staged download status...")
  new_status <- do.call(rbind, new_status_rows)
  rownames(new_status) <- NULL
  write_csv_safely(new_status, staged_status_path)

  excluded <- score_config$model_names_to_exclude
  panel_models <- models_df[!models_df$name %in% excluded, , drop = FALSE]
  panel_histories <- histories[panel_models$name]
  if (!nrow(panel_models)) {
    stop("No models remain for runtime panels after reviewed exclusions.", call. = FALSE)
  }
  step1_progress("Building 21 maturity panels for ", nrow(panel_models),
                 " models (D38 through D57 and D60)...")
  panels <- materialize_maturity_score_panels(
    model_histories = panel_histories,
    model_df = panel_models,
    min_from_round = base_round,
    current_round = current_round,
    score_config = score_config
  )
  if (
    !any(is.finite(as.matrix(panels$d38[-1L]))) ||
      !any(is.finite(as.matrix(panels$d60[-1L])))
  ) {
    stop("The refreshed archive cannot form D38 and D60 runtime panels.", call. = FALSE)
  }
  step1_progress("Writing and validating the 21 staged score panels...")
  staged_output_paths <- write_maturity_score_panels(panels, staged_output_dir)
  output_paths <- maturity_score_artifact_paths(output_dir)
  staged_cache_paths <- file.path(
    staged_model_history_dir,
    paste0(models_df$model_id, ".rds")
  )
  destination_cache_paths <- file.path(
    model_history_dir,
    paste0(models_df$model_id, ".rds")
  )
  step1_progress("Publishing the complete refresh: model histories, status, and score panels...")
  publish_staged_files(
    staged_paths = c(
      staged_cache_paths,
      staged_status_path,
      unname(staged_output_paths)
    ),
    destination_paths = c(
      destination_cache_paths,
      status_path,
      unname(output_paths)
    )
  )
  unpaired_events <- sum(vapply(histories, function(history) {
    corr <- history[
      history$metric_name == score_config$corr_metric_name &
        history$metric_version == score_config$corr_metric_version,
      ,
      drop = FALSE
    ]
    mmc <- history[
      history$metric_name == score_config$mmc_metric_name &
        history$metric_version == score_config$mmc_metric_version,
      ,
      drop = FALSE
    ]
    corr_keys <- score_pair_key(corr)
    mmc_keys <- score_pair_key(mmc)
    sum(!corr_keys %in% mmc_keys) + sum(!mmc_keys %in% corr_keys)
  }, integer(1L)))
  cat(
    "Step1 complete at frozen Numerai round ", current_round, ".\n",
    "Archived ", sum(vapply(histories, nrow, integer(1L))),
    " raw maturity events for ", length(histories), " workbook models; ",
    unpaired_events, " unpaired metric events remain preserved.\n",
    "Published ", length(output_paths), " maturity panels (D38 through D57 and D60) in ", file.path(output_dir,"scores"), ".\n",
    sep = ""
  )
  step1_progress("Finished in ", step1_duration(proc.time()[["elapsed"]] - run_started), ".")
  invisible(output_paths)
}


main()
