read_pipeline_parameters <- function(parameter_path = "parameters.csv") {
  if (!file.exists(parameter_path)) {
    stop("Missing parameter file: ", parameter_path)
  }

  parameter_ext <- tolower(tools::file_ext(parameter_path))
  if (parameter_ext != "csv")
    stop("Parameter file must be a .csv file: ", parameter_path)
  raw_params <- utils::read.csv(
    parameter_path,
    stringsAsFactors = FALSE,
    check.names = FALSE,
    na.strings = c("", "NA")
  )

  if (nrow(raw_params) == 0) {
    stop("Parameter file `", parameter_path, "` is empty.")
  }

  normalized_names <- tolower(trimws(names(raw_params)))
  parameter_col_idx <- which(normalized_names == "parameter")
  value_col_idx <- which(normalized_names == "value")

  if (length(parameter_col_idx) != 1 || length(value_col_idx) != 1) {
    stop("Parameter file must contain one `Parameter` column and one `Value` column.")
  }

  params <- data.frame(
    parameter = trimws(as.character(raw_params[[parameter_col_idx]])),
    value = trimws(as.character(raw_params[[value_col_idx]])),
    stringsAsFactors = FALSE
  )

  params <- params[!is.na(params$parameter) & params$parameter != "", , drop = FALSE]
  if (nrow(params) == 0) {
    stop("No valid parameter rows found in `", parameter_path, "`.")
  }

  duplicated_keys <- unique(params$parameter[duplicated(params$parameter)])
  if (length(duplicated_keys) > 0) {
    stop(
      "Duplicate parameter keys found in `", parameter_path, "`: ",
      paste(duplicated_keys, collapse = ", "),
      "."
    )
  }

  params
}

normalize_model_name <- function(x) {
  x <- trimws(as.character(x))
  tolower(x)
}

get_required_parameter <- function(params, parameter_name, allow_empty = FALSE) {
  value <- params$value[params$parameter == parameter_name]

  if (length(value) != 1) {
    stop("Missing required parameter `", parameter_name, "` in parameter file.")
  }

  value <- trimws(as.character(value[[1]]))
  if (is.na(value)) {
    value <- ""
  }
  if (!allow_empty && value == "") {
    stop("Parameter `", parameter_name, "` is empty in parameter file.")
  }

  value
}

get_param_numeric <- function(params, parameter_name) {
  raw_value <- get_required_parameter(params, parameter_name)
  numeric_value <- suppressWarnings(as.numeric(raw_value))

  if (!is.finite(numeric_value)) {
    stop("Parameter `", parameter_name, "` must be numeric, got `", raw_value, "`.")
  }

  as.numeric(numeric_value)
}

get_param_integer <- function(params, parameter_name) {
  numeric_value <- get_param_numeric(params, parameter_name)

  if (!isTRUE(all.equal(numeric_value, round(numeric_value), tolerance = 1e-8))) {
    stop("Parameter `", parameter_name, "` must be an integer, got `", numeric_value, "`.")
  }

  as.integer(round(numeric_value))
}

get_param_character_vector <- function(params, parameter_name, allow_empty = FALSE) {
  raw_value <- get_required_parameter(params, parameter_name, allow_empty = allow_empty)

  if (raw_value == "") {
    return(character())
  }

  split_values <- unlist(strsplit(raw_value, ",", fixed = TRUE), use.names = FALSE)
  split_values <- trimws(split_values)
  split_values <- split_values[split_values != ""]

  unique(as.character(split_values))
}

read_score_profile_config <- function(params) {
  tournament_id <- get_param_integer(params, "tournament_id")
  corr_metric_name <- get_required_parameter(params, "corr_metric_name")
  corr_metric_version <- get_required_parameter(params, "corr_metric_version")
  mmc_metric_name <- get_required_parameter(params, "mmc_metric_name")
  mmc_metric_version <- get_required_parameter(params, "mmc_metric_version")
  selection_score_day <- get_param_integer(params, "selection_score_day")
  historical_window <- get_param_integer(params, "historical_window")
  final_score_day <- get_param_integer(params, "final_score_day")
  score_availability_buffer_rounds <- get_param_integer(
    params,
    "score_availability_buffer_rounds"
  )
  corr_multiplier <- get_param_numeric(params, "corr_multiplier")
  mmc_multiplier <- get_param_numeric(params, "mmc_multiplier")
  model_names_to_exclude <- normalize_model_name(get_param_character_vector(
    params,
    "model_names_to_exclude",
    allow_empty = TRUE
  ))

  if (corr_metric_name == mmc_metric_name) {
    stop("`corr_metric_name` and `mmc_metric_name` must be different.")
  }
  if (tournament_id < 1L) {
    stop("Parameter `tournament_id` must be positive.")
  }
  if (score_availability_buffer_rounds < 0L) {
    stop("Parameter `score_availability_buffer_rounds` must be non-negative.")
  }
  if (
    selection_score_day != 60L || historical_window != 9L || final_score_day != 60L ||
      corr_metric_version != "0" || mmc_metric_version != "0"
  ) {
    stop("The selected runtime requires D60+|W9 and D60 metric-version-0 scores.")
  }

  list(
    tournament_id = tournament_id,
    corr_metric_name = corr_metric_name,
    corr_metric_version = corr_metric_version,
    mmc_metric_name = mmc_metric_name,
    mmc_metric_version = mmc_metric_version,
    selection_score_day = selection_score_day,
    historical_window = historical_window,
    final_score_day = final_score_day,
    score_availability_buffer_rounds = score_availability_buffer_rounds,
    selection_source_lag_rounds =
      selection_score_day + score_availability_buffer_rounds,
    final_source_lag_rounds =
      final_score_day + score_availability_buffer_rounds,
    corr_multiplier = corr_multiplier,
    mmc_multiplier = mmc_multiplier,
    model_names_to_exclude = model_names_to_exclude
  )
}
