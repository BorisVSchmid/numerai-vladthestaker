source("R/functions-config.R")
source("R/functions-score-storage.R")
source("R/functions-hyperparam-runtime.R")
source("R/functions-inputs.R")

expect_error <- function(expression, pattern) {
  error <- tryCatch({force(expression); NA_character_}, error = conditionMessage)
  stopifnot(!is.na(error), grepl(pattern, error, fixed = TRUE))
}

# All numbered steps use this contract. Test broken upstream files once here;
# individual step tests focus on scoring, reporting, and publication behavior.
local({
  folder <- tempfile("pipeline-inputs-")
  dir.create(folder)
  on.exit(unlink(folder, recursive = TRUE), add = TRUE)
  # CSV failures must identify the parameter file, including the branches that
  # previously referenced removed workbook variables after the merge.
  parameter_path <- file.path(folder, "parameters.csv")
  utils::write.csv(data.frame(Parameter = character(), Value = character()),
    parameter_path, row.names = FALSE)
  expect_error(read_pipeline_parameters(parameter_path), "is empty")
  utils::write.csv(data.frame(Parameter = c("base_round", "base_round"), Value = "100"),
    parameter_path, row.names = FALSE)
  expect_error(read_pipeline_parameters(parameter_path), "Duplicate parameter keys")
  params <- read_pipeline_parameters("parameters.csv")
  params$value[params$parameter == "base_round"] <- "100"
  roster <- data.frame(name = c(" A ", "b", ""), start = c(100, 101, NA))
  roster[["Include?"]] <- c("Yes", "No", NA)
  d60 <- data.frame(roundNumber = 100:210, a = .1, b = -.1)
  d60$a[3L] <- NA_real_
  path <- maturity_score_artifact_paths(folder)[["d60"]]
  write_csv_safely(d60, path)

  inputs <- check_pipeline_inputs(4L, params, folder, roster)
  stopifnot(identical(inputs$panel$outcome, d60),
    identical(inputs$panel$portfolio_included, c(TRUE, FALSE)))
  invalid_roster <- roster
  invalid_roster[["Include?"]][1L] <- "maybe"
  expect_error(check_pipeline_inputs(4L, params, folder, invalid_roster), "Include? must be Yes or No")
  invalid_roster <- roster
  invalid_roster$start[1L] <- "bad"
  expect_error(check_pipeline_inputs(1L, params, folder, invalid_roster),
    "positive integer starting round")
  invalid_roster <- roster
  invalid_roster$name[2L] <- "a"
  expect_error(check_pipeline_inputs(1L, params, folder, invalid_roster), "Duplicate Models")

  file.remove(path)
  expect_error(check_pipeline_inputs(4L, params, folder, roster), "Missing Step1 D60 scores")

  broken <- d60
  broken$a <- "bad"
  write_csv_safely(broken, path)
  expect_error(check_pipeline_inputs(4L, params, folder, roster), "non-numeric model column")
  broken <- d60
  broken$roundNumber[2L] <- broken$roundNumber[1L]
  write_csv_safely(broken, path)
  expect_error(check_pipeline_inputs(4L, params, folder, roster), "unique, increasing integer grid")
})
