# Shared startup checks for numbered steps: required files and usable data.
# Missing score cells are supported.
check_pipeline_inputs <- function(step, params, output_dir = "output", workbook_models = NULL) {
  if (!step %in% 1:4) stop("Input checks require step 1, 2, 3, or 4.", call. = FALSE)
  score_config <- read_score_profile_config(params)
  contract <- default_rule_runtime_contract(params, score_config)
  base_round <- get_param_integer(params, "base_round")
  if (!is.finite(base_round) || base_round < 1L)
    stop("base_round must be a positive integer.", call. = FALSE)
  result <- list(score_config = score_config, contract = contract,
    base_round = base_round)

  if (is.null(workbook_models))
    workbook_models <- as.data.frame(readxl::read_excel("Optimize-Me.xlsx", sheet = "Models"))
  if (!is.data.frame(workbook_models) || ncol(workbook_models) < 2L)
    stop("Models sheet must contain model names and starting rounds.", call. = FALSE)
  models <- data.frame(name = normalize_model_name(workbook_models[[1L]]),
    start = suppressWarnings(as.numeric(as.character(workbook_models[[2L]]))))
  named_rows <- !is.na(models$name) & nzchar(models$name)
  models <- models[named_rows, , drop = FALSE]
  if (!nrow(models)) stop("Models sheet has no candidate models.", call. = FALSE)
  if (any(!is.finite(models$start) | models$start < 1 |
      models$start != floor(models$start) | models$start > .Machine$integer.max))
    stop("Every configured model must have a positive integer starting round.", call. = FALSE)
  if (anyDuplicated(models$name))
    stop("Duplicate Models sheet model names after lowercasing.", call. = FALSE)
  models$start <- as.integer(models$start)
  if (step >= 3L) {
    include_column <- which(tolower(trimws(names(workbook_models))) == "include?")
    if (length(include_column) != 1L)
      stop("Models sheet must contain one Include? column with Yes or No values.", call. = FALSE)
    include <- tolower(trimws(as.character(workbook_models[[include_column]][named_rows])))
    if (any(is.na(include) | !include %in% c("yes", "no")))
      stop("Include? must be Yes or No for every named model.", call. = FALSE)
    models$portfolio_included <- include == "yes"
  }
  rownames(models) <- NULL
  result$model_df <- models

  if (step == 1L) {
    initial <- get_param_integer(params, "initial_history_rounds")
    pause <- get_param_numeric(params, "request_pause_seconds")
    refresh <- get_param_integer(params, "daily_refresh_rounds")
    if (initial < refresh || pause < 0)
      stop("Initial history must cover refresh history and request pacing must be non-negative.",
        call. = FALSE)
    result$initial_history_rounds <- initial
    result$daily_refresh_rounds <- refresh
    result$request_pause_seconds <- pause
  } else {
    path <- maturity_score_artifact_paths(output_dir)[["d60"]]
    if (!file.exists(path)) stop("Missing Step1 D60 scores. Re-run Step1.", call. = FALSE)
    d60 <- validate_combined_score_panel(utils::read.csv(path, check.names = FALSE), "Step1 D60 scores")
    if (step == 2L) {
      result$d60 <- d60[d60$roundNumber >= base_round, , drop = FALSE]
      if (!nrow(result$d60) || !any(is.finite(as.matrix(result$d60[-1L]))))
        stop("No finite D60 scores remain from base_round onward.", call. = FALSE)
    } else {
      result$panel <- prepare_default_rule_score_panels(d60, contract, base_round,
        score_config$model_names_to_exclude)
      expected_models <- setdiff(models$name, score_config$model_names_to_exclude)
      if (!setequal(result$panel$models, expected_models))
        stop("D60 model columns do not match the Models sheet. Re-run Step1.", call. = FALSE)
      result$panel$portfolio_included <- models$portfolio_included[
        match(result$panel$models, models$name)]
    }
  }
  result
}
