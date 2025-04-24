# Build on R4.4.3
# Groundhog and conflicted to improve reproducability and reduce configuration errors across systems.
library(groundhog)
pkgs <- c("conflicted", "dplyr", "tidyr", "readxl", "tibble", "stringr", "httr2", "ggplot2", "ggrepel")
groundhog.library(pkgs, "2024-12-01")


#
# Read in helper functions for data fetching and processing.
#
# Sometimes you can get an error message when downloading the daily data while Numer.ai. This seems to happen
# if you run Vlad while the API scores are getting updated at that moment. Wait a few hours and try again.
#
source("functions-fetch.R")


#
# Vlad Input Data and Settings
#
# Read in the list of model names and their start round.
#
model_df <- read_excel("Optimize-Me-13jan2025.xlsx")
colnames(model_df) <- c("name","start","notes")
current_round <- custom_query_current_round()
oldest_round <- min(model_df$start)

#
# Collect daily scores and write them to disk. V5 era started september 27th, 2024. Which is round 843.
#
daily_data <- build_RAW(model_df, MinfromRound = 843, currentRound = current_round, corr_multiplier = 0.5, mmc_multiplier = 2, bmc_multiplier = 0)

write.csv(daily_data,"output/daily_data.csv")
