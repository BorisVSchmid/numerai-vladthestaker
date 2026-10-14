publish_staged_files <- function(
  staged_paths,
  destination_paths,
  rename_function = file.rename,
  remove_function = unlink
) {
  staged_paths <- as.character(staged_paths)
  destination_paths <- as.character(destination_paths)
  if (
    !length(staged_paths) || length(staged_paths) != length(destination_paths) ||
      any(!file.exists(staged_paths)) || anyDuplicated(staged_paths) ||
      anyDuplicated(destination_paths)
  ) {
    stop("Atomic file-set publication inputs are invalid.", call. = FALSE)
  }

  destination_dirs <- unique(dirname(destination_paths))
  for (destination_dir in destination_dirs) {
    dir.create(destination_dir, recursive = TRUE, showWarnings = FALSE)
  }
  if (!all(dir.exists(destination_dirs))) {
    stop("Could not create every publication directory.", call. = FALSE)
  }

  had_previous <- file.exists(destination_paths)
  backup_paths <- rep(NA_character_, length(destination_paths))
  previous_moved <- rep(FALSE, length(destination_paths))
  staged_moved <- rep(FALSE, length(destination_paths))
  published <- FALSE

  rollback <- function() {
    restored <- TRUE
    for (index in rev(seq_along(destination_paths))) {
      if (staged_moved[[index]] && file.exists(destination_paths[[index]])) {
        restored <- isTRUE(
          tryCatch(remove_function(destination_paths[[index]], force = TRUE) == 0L,
            error = function(error) FALSE)
        ) && restored
      }
      if (previous_moved[[index]] && file.exists(backup_paths[[index]])) {
        restored <- isTRUE(tryCatch(rename_function(
          backup_paths[[index]],
          destination_paths[[index]]
        ), error = function(error) FALSE)) && restored
      }
    }
    restored
  }
  # Errors and user interrupts must restore the previous set before callers
  # remove their staging directories. Keep backups if restoration fails.
  on.exit({
    if (!published && !suspendInterrupts(rollback())) {
      warning("Publication failed and rollback was incomplete; retained backups: ",
        paste(backup_paths[!is.na(backup_paths) & file.exists(backup_paths)], collapse = ", "),
        call. = FALSE)
    }
  }, add = TRUE)

  for (index in which(had_previous)) {
    backup_paths[[index]] <- tempfile(
      pattern = paste0(".", basename(destination_paths[[index]]), "."),
      tmpdir = dirname(destination_paths[[index]]),
      fileext = ".previous"
    )
    # Defer interrupts until the move and its rollback flag agree.
    suspendInterrupts({
      if (!rename_function(destination_paths[[index]], backup_paths[[index]]))
        stop("Could not stage an existing artifact for atomic replacement.", call. = FALSE)
      previous_moved[[index]] <- TRUE
    })
  }

  for (index in seq_along(destination_paths)) {
    suspendInterrupts({
      if (!rename_function(staged_paths[[index]], destination_paths[[index]]))
        stop("Could not publish a complete atomic artifact set.", call. = FALSE)
      staged_moved[[index]] <- TRUE
    })
  }
  published <- TRUE

  backup_existing <- backup_paths[!is.na(backup_paths) & file.exists(backup_paths)]
  if (
    length(backup_existing) &&
      any(remove_function(backup_existing, force = TRUE) != 0L)
  ) {
    warning("Published the new artifact set but could not remove every backup.")
  }
  invisible(destination_paths)
}


write_csv_safely <- function(data, path) {
  output_dir <- dirname(path)
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  temporary_path <- tempfile(
    pattern = paste0(basename(path), "."),
    tmpdir = output_dir,
    fileext = ".tmp"
  )
  on.exit(unlink(temporary_path), add = TRUE)
  utils::write.csv(data, temporary_path, row.names = FALSE, na = "")
  publish_staged_files(temporary_path, path)
  invisible(path)
}


validate_combined_score_panel <- function(
  panel,
  context = "Combined-score panel",
  expected_models = NULL,
  expected_rounds = NULL
) {
  if (
    !is.data.frame(panel) || nrow(panel) < 1L || ncol(panel) < 2L ||
      names(panel)[[1L]] != "roundNumber"
  ) {
    stop(context, " must start with roundNumber and contain model columns.", call. = FALSE)
  }
  rounds <- suppressWarnings(as.numeric(panel$roundNumber))
  if (
    any(!is.finite(rounds)) || any(rounds != as.integer(rounds)) ||
      is.unsorted(rounds, strictly = TRUE) || any(diff(rounds) != 1L)
  ) {
    stop(context, " roundNumber must contain a dense, unique, increasing integer grid.", call. = FALSE)
  }
  models <- names(panel)[-1L]
  if (
    any(is.na(models) | models == "") || any(models != tolower(models)) ||
      anyDuplicated(models)
  ) {
    stop(context, " has invalid or duplicate lower-case model columns.", call. = FALSE)
  }
  numeric_or_all_na <- function(x) {
    is.numeric(x) || (is.logical(x) && all(is.na(x)))
  }
  if (!all(vapply(panel[-1L], numeric_or_all_na, logical(1L)))) {
    stop(context, " contains a non-numeric model column.", call. = FALSE)
  }
  if (!is.null(expected_models) && !identical(models, as.character(expected_models))) {
    stop(context, " does not have the expected model columns and order.", call. = FALSE)
  }
  if (!is.null(expected_rounds) && !identical(as.integer(rounds), as.integer(expected_rounds))) {
    stop(context, " does not have the expected round calendar.", call. = FALSE)
  }
  panel$roundNumber <- as.integer(rounds)
  panel
}


validate_maturity_score_panels <- function(panels, context = "Maturity score panels") {
  expected_names <- names(maturity_score_artifact_names())
  if (!is.list(panels) || !identical(names(panels), expected_names))
    stop(context, " must contain D38 through D57 and D60 in that order.", call. = FALSE)
  first <- validate_combined_score_panel(panels[[1L]], paste(context, "D38"))
  panels[[1L]] <- first
  for (name in expected_names[-1L]) panels[[name]] <- validate_combined_score_panel(
    panels[[name]], paste(context, name), expected_models = names(first)[-1L],
    expected_rounds = first$roundNumber)
  panels
}


maturity_score_artifact_names <- function() {
  days <- c(38:57, 60L)
  setNames(paste0("d", days, "_combined_scores.csv"), paste0("d", days))
}

maturity_score_artifact_paths <- function(output_dir) {
  artifacts <- maturity_score_artifact_names()
  setNames(file.path(output_dir, "scores", unname(artifacts)), names(artifacts))
}
