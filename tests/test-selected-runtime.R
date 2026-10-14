source("tests/load-step-functions.R", local = TRUE)
load_step_functions("step1_get_data.R", constants = "score_event_columns")
source(file.path("R", "functions-config.R"))
source(file.path("R", "functions-score-storage.R"))
source(file.path("R", "functions-fetch.R"))
source(file.path("R", "functions-hyperparam-runtime.R"))


expect_error_text <- function(expression, pattern) {
  message <- tryCatch(
    {
      force(expression)
      NA_character_
    },
    error = function(error) conditionMessage(error)
  )
  stopifnot(!is.na(message), grepl(pattern, message, fixed = TRUE))
}


make_event <- function(
  round_number,
  score_day,
  metric_name,
  value,
  score_date_utc,
  downloaded_at_utc = "2026-08-22T10:00:00Z",
  resolved = FALSE,
  model_name = "fixture_model",
  model_id = "model-id-1",
  submission_id = "submission-id-1"
) {
  data.frame(
    first_downloaded_at_utc = downloaded_at_utc,
    last_downloaded_at_utc = downloaded_at_utc,
    download_current_round = 1100L,
    tournament_id = 8L,
    model_name = model_name,
    model_id = model_id,
    submission_id = submission_id,
    round_number = as.integer(round_number),
    score_date_utc = score_date_utc,
    score_day = as.integer(score_day),
    metric_name = metric_name,
    metric_version = "0",
    value = as.numeric(value),
    percentile = 0.5,
    score_resolved = as.logical(resolved),
    score_resolve_date_utc = NA_character_,
    round_close_staking_time_utc = "2026-06-01T00:00:00Z",
    round_score_time_utc = "2026-08-01T00:00:00Z",
    round_resolve_time_utc = "2026-08-02T00:00:00Z",
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}


params <- read_pipeline_parameters("parameters.csv")
score_config <- read_score_profile_config(params)
contract <- default_rule_runtime_contract(params, score_config)
stopifnot(
  identical(score_config$selection_score_day, 60L),
  identical(score_config$final_score_day, 60L),
  identical(score_config$selection_source_lag_rounds, 64L),
  identical(score_config$final_source_lag_rounds, 64L),
  identical(score_config$corr_metric_version, "0"),
  identical(score_config$mmc_metric_version, "0"),
  identical(score_config$corr_multiplier, 3),
  identical(score_config$mmc_multiplier, 15),
  identical(contract$historical_window, 9L)
)
stopifnot(identical(names(maturity_score_artifact_names()),paste0("d",c(38:57,60))),
  contract$source_round_lag + contract$historical_window - 1L == 72L)


# Event identity includes maturity. Re-downloading one event refreshes its
# current state while preserving the timestamp at which it was first observed.
existing <- make_event(
  1000L, 57L, "canon_corr60", 0.01,
  "2026-07-28T00:00:00Z"
)
replacement <- make_event(
  1000L, 57L, "canon_corr60", 0.015,
  "2026-07-28T00:00:00Z",
  downloaded_at_utc = "2026-08-22T11:00:00Z",
  resolved = TRUE
)
downloaded <- rbind(
  replacement,
  make_event(1000L, 57L, "canon_mmc60", 0.02, "2026-07-28T00:00:00Z"),
  make_event(1000L, 60L, "canon_corr60", 0.03, "2026-07-31T00:00:00Z", resolved = TRUE),
  make_event(1000L, 60L, "canon_mmc60", 0.04, "2026-07-31T00:00:00Z", resolved = TRUE),
  make_event(
    1001L, 57L, "canon_corr60", 0.05,
    "2026-07-29T00:00:00Z",
    submission_id = "submission-id-2"
  )
)
merged <- merge_score_event_history(existing, downloaded)
replaced_row <- merged[
  merged$round_number == 1000L & merged$score_day == 57L &
    merged$metric_name == "canon_corr60",
  ,
  drop = FALSE
]
stopifnot(
  nrow(merged) == 5L,
  nrow(replaced_row) == 1L,
  identical(replaced_row$first_downloaded_at_utc, "2026-08-22T10:00:00Z"),
  identical(replaced_row$last_downloaded_at_utc, "2026-08-22T11:00:00Z"),
  identical(replaced_row$value, 0.015),
  isTRUE(replaced_row$score_resolved)
)

cells <- combined_score_cells(merged, score_config)
stopifnot(
  nrow(cells) == 2L,
  isTRUE(all.equal(
    cells$combined_score[cells$score_day == 57L],
    3 * 0.015 + 15 * 0.02,
    tolerance = 1e-12
  )),
  isTRUE(all.equal(
    cells$combined_score[cells$score_day == 60L],
    3 * 0.03 + 15 * 0.04,
    tolerance = 1e-12
  )),
  any(merged$round_number == 1001L),
  !any(cells$round_number == 1001L)
)

panels <- materialize_maturity_score_panels(
  model_histories = list(fixture_model = merged),
  model_df = data.frame(name = "fixture_model", start = 1000L),
  min_from_round = 1000L,
  current_round = 1001L,
  score_config = score_config
)
stopifnot(
  identical(panels$d57$roundNumber, 1000:1001),
  identical(names(panels$d57), names(panels$d60)),
  is.finite(panels$d57$fixture_model[[1L]]),
  is.na(panels$d57$fixture_model[[2L]]),
  is.finite(panels$d60$fixture_model[[1L]]),
  is.na(panels$d60$fixture_model[[2L]])
)

# Advancing the roster start masks cached cells at every maturity without
# deleting history; restoring the earlier start makes the same cells available.
history_before <- merged
later_start <- materialize_maturity_score_panels(
  list(fixture_model = merged), data.frame(name = "fixture_model", start = 1001L),
  1000L, 1001L, score_config
)
stopifnot(all(vapply(later_start, function(panel) all(is.na(panel$fixture_model)), logical(1))),
  identical(merged, history_before))
restored_start <- materialize_maturity_score_panels(
  list(fixture_model = merged), data.frame(name = "fixture_model", start = 1000L),
  1000L, 1001L, score_config
)
stopifnot(identical(restored_start, panels))


# The GraphQL request admits unfinished maturities and exact metric version 0;
# intermediate maturity observations remain available alongside final D60 cells.
query <- build_maturity_score_query()
stopifnot(
  grepl("distinctOnRound: false", query, fixed = TRUE),
  grepl("corr: submissionScores", query, fixed = TRUE),
  grepl("mmc: submissionScores", query, fixed = TRUE),
  !grepl("resolvedOnly", query, fixed = TRUE)
)
query_runner <- function(query, variables) {
  stopifnot(
    identical(variables$lastNRounds, 75L),
    identical(variables$corrVersion, "0"),
    identical(variables$mmcVersion, "0")
  )
  record <- function(metric, value) list(
    roundNumber = 1039L,
    date = "2026-06-22T00:00:00Z",
    day = 57L,
    displayName = metric,
    version = "0",
    value = value,
    percentile = 0.5,
    resolved = FALSE,
    resolveDate = NULL,
    roundCloseStakingTime = "2026-04-22T00:00:00Z",
    roundScoreTime = "2026-06-22T00:00:00Z",
    roundResolveTime = "2026-06-25T00:00:00Z",
    submissionId = "submission-id-live"
  )
  list(
    corr = list(record("canon_corr60", 0.01)),
    mmc = list(record("canon_mmc60", 0.02))
  )
}
fetched <- fetch_model_score_events(
  model_name = "fixture_model",
  from_round = 1039L,
  current_round = 1100L,
  score_config = score_config,
  last_n_rounds = 75L,
  model_id = "model-id-1",
  downloaded_at_utc = "2026-08-22T10:00:00Z",
  query_runner = query_runner
)
stopifnot(
  nrow(fetched) == 2L,
  all(fetched$score_day == 57L),
  all(!fetched$score_resolved),
  setequal(fetched$metric_name, c("canon_corr60", "canon_mmc60"))
)
expect_error_text(
  fetch_model_score_events(
    model_name = "fixture_model",
    from_round = 1039L,
    current_round = 1100L,
    score_config = score_config,
    last_n_rounds = 61L,
    model_id = "model-id-1",
    downloaded_at_utc = "2026-08-22T10:00:00Z",
    query_runner = query_runner
  ),
  "must cover every requested round"
)


# Multi-file publication replaces the complete set while preserving unrelated
# files. This is the mechanism Step1 uses for caches, status, D57, and D60.
publication_dir <- tempfile("score-publication-")
dir.create(publication_dir)
stage_dir <- file.path(publication_dir, "stage")
destination_dir <- file.path(publication_dir, "destination")
dir.create(stage_dir)
dir.create(destination_dir)
staged <- file.path(stage_dir, c("d57.csv", "d60.csv"))
destinations <- file.path(destination_dir, c("d57.csv", "d60.csv"))
writeLines("new d57", staged[[1L]])
writeLines("new d60", staged[[2L]])
writeLines("old d57", destinations[[1L]])
writeLines("old d60", destinations[[2L]])
writeLines("keep", file.path(destination_dir, "operator-note.txt"))
publish_staged_files(staged, destinations)
stopifnot(
  identical(readLines(destinations[[1L]]), "new d57"),
  identical(readLines(destinations[[2L]]), "new d60"),
  identical(readLines(file.path(destination_dir, "operator-note.txt")), "keep"),
  !any(file.exists(staged))
)

rollback_stage <- file.path(stage_dir, c("rollback-d57.csv", "rollback-d60.csv"))
writeLines("bad d57", rollback_stage[[1L]])
writeLines("bad d60", rollback_stage[[2L]])
fail_second_publish <- function(from, to) {
  if (identical(from, rollback_stage[[2L]])) return(FALSE)
  file.rename(from, to)
}
expect_error_text(
  publish_staged_files(
    rollback_stage,
    destinations,
    rename_function = fail_second_publish
  ),
  "Could not publish a complete atomic artifact set"
)
stopifnot(
  identical(readLines(destinations[[1L]]), "new d57"),
  identical(readLines(destinations[[2L]]), "new d60")
)

# Unwinding via an error or interrupt must restore existing files and remove
# newly published files even when there was no previous destination.
local({
  folder <- tempfile("publication-unwind-")
  dir.create(folder)
  on.exit(unlink(folder, recursive = TRUE), add = TRUE)
  for (phase in c("backup", "publish")) for (condition in c("error", "interrupt")) {
    staged <- file.path(folder, c("stage-a", "stage-b", "stage-c"))
    destinations <- file.path(folder, c("new-a", "old-b", "old-c"))
    for (path in staged) writeLines("replacement", path)
    writeLines("previous b", destinations[[2L]])
    writeLines("previous c", destinations[[3L]])
    rename_with_failure <- function(from, to) {
      fail <- if (phase == "backup") identical(from, destinations[[3L]]) else
        identical(from, staged[[3L]])
      if (fail) {
        if (condition == "interrupt") stop(structure(
          list(message = "simulated interrupt"), class = c("interrupt", "condition")))
        stop("simulated error")
      }
      file.rename(from, to)
    }
    failure <- tryCatch(publish_staged_files(staged, destinations,
      rename_function = rename_with_failure), error = conditionMessage, interrupt = conditionMessage)
    stopifnot(grepl("simulated", failure), !file.exists(destinations[[1L]]),
      identical(readLines(destinations[[2L]]), "previous b"),
      identical(readLines(destinations[[3L]]), "previous c"))
  }
  # A failed restoration is visible and preserves the original backup even
  # when another file in the set can still be restored successfully.
  for (path in staged) writeLines("replacement", path)
  retained_backup <- NULL
  rename_with_failed_restore <- function(from, to) {
    if (identical(from, staged[[3L]])) stop("simulated publication error")
    if (identical(to, destinations[[3L]]) && endsWith(from, ".previous")) {
      retained_backup <<- from
      stop("simulated restoration error")
    }
    file.rename(from, to)
  }
  rollback_warning <- character()
  failure <- tryCatch(withCallingHandlers(publish_staged_files(staged, destinations,
    rename_function = rename_with_failed_restore), warning = function(warning) {
      rollback_warning <<- c(rollback_warning, conditionMessage(warning))
      invokeRestart("muffleWarning")
    }), error = conditionMessage)
  stopifnot(grepl("simulated publication error", failure),
    any(grepl("rollback was incomplete", rollback_warning)),
    any(grepl(retained_backup, rollback_warning, fixed = TRUE)),
    identical(readLines(retained_backup), "previous c"),
    !file.exists(destinations[[1L]]),
    identical(readLines(destinations[[2L]]), "previous b"))
})
unlink(publication_dir, recursive = TRUE, force = TRUE)
