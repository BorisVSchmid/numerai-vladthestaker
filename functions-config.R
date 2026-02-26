read_pipeline_parameters <- function(workbook_path = "Optimize-Me.xlsx", sheet = "Parameters") {
  if (!file.exists(workbook_path)) {
    stop("Missing workbook: ", workbook_path)
  }

  raw_params <- readxl::read_excel(
    path = workbook_path,
    sheet = sheet,
    col_types = "text"
  )

  if (nrow(raw_params) == 0) {
    stop("Parameter sheet `", sheet, "` is empty in ", workbook_path, ".")
  }

  normalized_names <- tolower(trimws(names(raw_params)))
  parameter_col_idx <- which(normalized_names == "parameter")
  value_col_idx <- which(normalized_names == "value")

  if (length(parameter_col_idx) != 1 || length(value_col_idx) != 1) {
    stop("Parameter sheet must contain exactly `Parameter` and `Value` columns.")
  }

  params <- data.frame(
    parameter = trimws(as.character(raw_params[[parameter_col_idx]])),
    value = trimws(as.character(raw_params[[value_col_idx]])),
    stringsAsFactors = FALSE
  )

  params <- params[!is.na(params$parameter) & params$parameter != "", , drop = FALSE]
  if (nrow(params) == 0) {
    stop("No valid parameter rows found in sheet `", sheet, "`.")
  }

  duplicated_keys <- unique(params$parameter[duplicated(params$parameter)])
  if (length(duplicated_keys) > 0) {
    stop(
      "Duplicate parameter keys found in sheet `", sheet, "`: ",
      paste(duplicated_keys, collapse = ", "),
      "."
    )
  }

  params
}

get_required_parameter <- function(params, parameter_name, allow_empty = FALSE) {
  value <- params$value[params$parameter == parameter_name]

  if (length(value) != 1) {
    stop("Missing required parameter `", parameter_name, "` in Parameters sheet.")
  }

  value <- trimws(as.character(value[[1]]))
  if (is.na(value)) {
    value <- ""
  }
  if (!is.finite(nchar(value)) || (!allow_empty && value == "")) {
    stop("Parameter `", parameter_name, "` is empty in Parameters sheet.")
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

get_param_character <- function(params, parameter_name) {
  get_required_parameter(params, parameter_name, allow_empty = FALSE)
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
