########
# Rscript to fetch performance data of submitted models to the numer.ai data science competition
#
# Build on R4.5.2
#
# - Uses Groundhog and conflicted to improve reproducibility and reduce configuration errors across systems. 
# - Sets the Groundhog directory to something that admin-controlled computers hopefully also tolerate.
#
########

# -------------------- Reproducible libraries --------------------
options(repos = c(CRAN = "https://cran.r-project.org"))
if (!requireNamespace("groundhog", quietly = TRUE)) install.packages("groundhog")
if (!requireNamespace("conflicted", quietly = TRUE)) install.packages("conflicted")

quiet_startup <- tolower(Sys.getenv("VLAD_QUIET_STARTUP", "1")) %in% c("1", "true", "yes", "y")
run_startup_quietly <- function(expr) {
  expr_sub <- substitute(expr)
  if (quiet_startup) {
    invisible(
      suppressWarnings(
        suppressMessages(
          utils::capture.output(
            eval(expr_sub, envir = parent.frame()),
            type = "output"
          )
        )
      )
    )
  } else {
    eval(expr_sub, envir = parent.frame())
  }
}

run_startup_quietly(library(groundhog))
run_startup_quietly(library(conflicted))

run_startup_quietly(groundhog::set.groundhog.folder(
  if (.Platform$OS.type == "windows") {
    file.path(Sys.getenv("LOCALAPPDATA"), "R_groundhog", "groundhog_library")
  } else {
    file.path(path.expand("~"), "R_groundhog", "groundhog_library")
  }
))

pkgs <- c("conflicted", "dplyr", "tidyr", "readxl", "tibble", "stringr", "httr2", "ggplot2", "ggrepel")
run_startup_quietly(groundhog.library(pkgs, "2025-06-01"))


#
# Read in helper functions for data fetching and processing.
#
# Sometimes you can get an error message when downloading the daily data while Numer.ai. This seems to happen
# if you run Vlad while the API scores are getting updated at that moment. Wait a few hours and try again.
#
source("functions-fetch.R")
source("functions-config.R")


#
# Vlad Input Data and Settings
#
# Read in the list of model names and their start round.
#
# I took the highest-staked models from the list of 2025 
# Grandmasters and Masters as an example.
workbook_path <- "Optimize-Me.xlsx"
params <- read_pipeline_parameters(workbook_path)

model_df <- read_excel(workbook_path, sheet = "Models")
colnames(model_df) <- c("name","start","notes")

# Ignore empty rows (for example, trailing blank lines in Excel).
model_df <- model_df %>%
  dplyr::mutate(name = as.character(name)) %>%
  dplyr::filter(!is.na(name), stringr::str_trim(name) != "")

# Harmonized naming with step2/step3 settings.
base_round <- get_param_integer(params, "base_round")

current_round <- custom_query_current_round()

#
# Collect daily scores and write them to disk. V5 era started september 27th, 2024. Which is round 843.
#
daily_data_by_metric <- build_RAW(model_df, MinfromRound = base_round, currentRound = current_round)

# Ensure output directory exists before writing step1 artifacts.
if (!dir.exists("output")) {
  dir.create("output", recursive = TRUE)
}

write.csv(daily_data_by_metric$corr_abs, "output/daily_data_corr_abs.csv", row.names = FALSE)
write.csv(daily_data_by_metric$corr_rel, "output/daily_data_corr_rel.csv", row.names = FALSE)
write.csv(daily_data_by_metric$mmc_abs, "output/daily_data_mmc_abs.csv", row.names = FALSE)
write.csv(daily_data_by_metric$mmc_rel, "output/daily_data_mmc_rel.csv", row.names = FALSE)
