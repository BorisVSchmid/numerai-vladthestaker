# To make groundhogr work in Rstudio, go to Tools -> Global Options, and change the following two settings:
# Code -> Completion -> Show code Completion (set to Never)
# Code -> Diagnostics -> Show Diagnostics (remove tick from box)
#

library(groundhog)
pkgs <- c("conflicted","dplyr","tidyr","knitr","readxl","tibble","stringr","memoise","Rnumerai","fPortfolio","ggplot2","ggrepel","PerformanceAnalytics")
groundhog.library(pkgs, "2024-01-01") # For R-4.3.x. You can use "2023-04-21 for R-4.2.x


#
# WARNING
#
# Vlad should only consider models with a average positive return. This is because I noticed that 
# when the portfolios contain models with negative returns, the tangency portfolio selection
# can be a bit wonky, and sometimes suggests portfolios with a negative-return based on a 
# single model.
#
# Particularly when you are just starting to use Vlad, use the model-performances-plot to see if 
# the models selected by Vlad make sense to you.
#

# Sometimes you can get this error
## Error in UseMethod("filter") : 
##   no applicable method for 'filter' applied to an object of class "list"
# It seems to happen if the API scores are getting updated at that moment

## Read in program-specific functions
#
source("functions.R")
options(scipen = 999)

## Vlad Input Data and Settings
#
NMR <- 100
model_df <- read_excel("Optimize-Me-26apr2024.xlsx")          # Read in the list of model names and their start (and possibly end) round.
colnames(model_df) <- c("name","start","notes")
current_round <- Rnumerai::get_current_round()
model_df <- dplyr::filter(model_df, start < current_round - 30) # Models that started less than 30 rounds ago have barely any resolved tournaments, and don't need to be added in.
oldest_round <- min(model_df$start)


## Collect daily scores, and filter for models that have at least 60 data points (you shouldn't use Vlad for models with less data points)
#  I have set the starting round at 339, as that is the first round of the daily tournament, but you are free to change that round back and forth.
#
daily_data <- build_RAW(model_df, MinfromRound = 339, corr_multiplier = 0.5, mmc_multiplier = 2, bmc_multiplier = 0)
daily_data <- daily_data[,colnames(daily_data) %in% colnames(daily_data)[colSums(!is.na(daily_data)) > 60]]



## calculate stats
#
calculate_acf <- function(df) {sapply(df, function(column) acf1_pairwise(column))}
model_stats <- data.frame(name = colnames(daily_data), 
                          first_round = daily_data$roundNumber[apply(daily_data, 2, function(x) which(!is.na(x))[1])],
                          mean = colMeans(daily_data, na.rm = TRUE), 
                          rho = calculate_acf(daily_data),
                          sd = colSds(daily_data, na.rm = TRUE), 
                          drawdown = apply(daily_data, MARGIN = 2, FUN = function(column) {maxDrawdown(column)}),
                          size = colSums(!is.na(daily_data)),
                          row.names = NULL) %>% dplyr::filter(name != "roundNumber")

model_stats <- model_stats %>% mutate(sharpe = mean / sd,
                                      tSSR = ((mean / sd) * sqrt(size - 1)) / sqrt(1 - rho + rho * size))

# plot stats
model_stats$scaled <- 2 * (0.5 + unlist(lapply(unlist((lapply(model_stats$tSSR,max,0.01))),sqrt)))^2
ggplot(model_stats) + 
  geom_point(aes(y=mean,x=sd, size=scaled, fill = drawdown),color="black",shape=21) + 
  scale_fill_gradient2(low="green",mid="red",high="black",midpoint=0.9) +
  labs(size = "tSSR Sharpe") +
  geom_text_repel(aes(y=mean,x=sd,label=name),box.padding = 0.6,max.overlaps = 15, force_pull = 0.7,min.segment.length = 1.5)
ggsave("model-performances-05corr-2mmc.png",scale=1,width=15,height=15)



## Define your threshold for what is a good model.
good_models <- dplyr::filter(model_stats,mean >= 0.005)


## When do these models start?
#
starting_points <- sort(unique(good_models %>% pull(first_round)))
table(starting_points)

# 
# Manual step. You can reduce the number of starting points here.
# 
# starting_points <- c(340,553,602,649)
  
  
## Calculate portfolios from each of the starting points onwards.
#

# use threshold to remove small stakes from the portfolios (this limits the
# final number of models you would have to stake on)
threshold <- 0.125 # Tweak this number. lower numbers lead to larger ensembles. Also, this is a setting within the portfolio that I can specify. Do so.
plot_data <- data.frame()
#
combined <- data.frame()
for (point in starting_points) {
  print(point)
  tryCatch({
    relevant_models <- dplyr::filter(good_models,first_round <= point) %>% pull(name)
    daily <- daily_data %>% dplyr::filter(roundNumber >= point) %>% dplyr::select(all_of(relevant_models)) %>% na.omit()
    portfolio <- build_portfolio(daily,threshold = threshold)
    plot_data <- rbind(plot_data,build_plot(portfolio,point))
    newreturns <- as.data.frame(unlist(virtual_returns(daily_data,portfolio)))
    merged <- cbind(portfolio,newreturns)
    merged$starting_round <- point
    merged[2:nrow(merged),4:9] <- ""
    combined <- rbind(combined,merged,"")
  }, error = function(e) {
    message("An error occurred: ", e$message)
  })
}
#
# Depending on what models were selected, the models selected for being smaller than starting round X, 
# might be coinciding with the round number ranges of starting round X-1. For plotting we stay at the 
# starting round specified by the starting round.
# 
#

 
## Printout row-concatenated portfolios for different starting points.
#
kable(combined,digits=3)

# |name               |weight |stake |mean   |Cov    |CVaR   |VaR     |samplesize |starting_round |
# |:------------------|:------|:-----|:------|:------|:------|:-------|:----------|:--------------|
# |V2_EXAMPLE_PREDS   |0.253  |25    |0.0117 |0.0221 |0.0199 |0.0154  |379        |340            |
# |V3_EXAMPLE_PREDS   |0.279  |28    |       |       |       |        |           |               |
# |V4_LGBM_VICTOR20   |0.326  |33    |       |       |       |        |           |               |
# |V4_LGBM_VICTOR60   |0.142  |14    |       |       |       |        |           |               |
# |                   |       |      |       |       |       |        |           |               |
# |NB_HELLO_NUMERAI   |0.1    |10    |0.0137 |0.0134 |0.0102 |0.0048  |166        |553            |
# |V41_LGBM_CYRUS20   |0.19   |19    |       |       |       |        |           |               |
# |V41_LGBM_CYRUS60   |0.138  |14    |       |       |       |        |           |               |
# |V4_LGBM_NOMI60     |0.145  |14    |       |       |       |        |           |               |
# |V4_LGBM_RALPH20    |0.086  |9     |       |       |       |        |           |               |
# |V4_LGBM_VICTOR60   |0.133  |13    |       |       |       |        |           |               |
# |V4_LGBM_WALDO20    |0.095  |10    |       |       |       |        |           |               |
# |V4_LGBM_WALDO60    |0.113  |11    |       |       |       |        |           |               |
# |                   |       |      |       |       |       |        |           |               |
# |NB_EXAMPLE_MODEL   |0.234  |23    |0.0155 |0.0089 |0.0007 |-0.0022 |117        |602            |
# |V41_LGBM_CYRUS20   |0.181  |18    |       |       |       |        |           |               |
# |V42_EXAMPLE_PREDS  |0.195  |20    |       |       |       |        |           |               |
# |V42_RAIN_ENSEMBLE2 |0.203  |20    |       |       |       |        |           |               |
# |V4_LGBM_VICTOR20   |0.187  |19    |       |       |       |        |           |               |
# |                   |       |      |       |       |       |        |           |               |
# |NB_EXAMPLE_MODEL   |0.201  |20    |0.0131 |0.0084 |0.002  |-0.0005 |72         |649            |
# |NB_TARGET_ENSEMBLE |0.098  |10    |       |       |       |        |           |               |
# |V41_EXAMPLE_PREDS  |0.107  |11    |       |       |       |        |           |               |
# |V42_EXAMPLE_PREDS  |0.11   |11    |       |       |       |        |           |               |
# |V42_LGBM_AGNES20   |0.135  |14    |       |       |       |        |           |               |
# |V42_RAIN_ENSEMBLE  |0.099  |10    |       |       |       |        |           |               |
# |V43_LGBM_CYRUS60   |0.104  |10    |       |       |       |        |           |               |
# |V4_LGBM_TYLER20    |0.147  |15    |       |       |       |        |           |               |
# |                   |       |      |       |       |       |        |           |               |

  
## Use this plot to decide on what group of models to pick
#
# adjusted data shifts the starting offset of later performance time series to that of the previous starting point time series
# 
adjusted_data <- plot_data %>% arrange(starting_round,roundNumber)
offsets <- c()
for (i in 1:(length(starting_points) - 1)) {
  actual_starting_point <- adjusted_data %>% dplyr::filter(starting_round == starting_points[i + 1]) %>% pull(roundNumber) %>% min()
  offset <- adjusted_data %>% dplyr::filter(roundNumber == actual_starting_point & roundNumber > starting_round) %>% pull(cumulative_portfolio_score) %>% dplyr::last()
  offsets <- c(offsets,offset)
  adjusted_data[adjusted_data$starting_round == starting_points[i + 1],]$cumulative_portfolio_score <- adjusted_data[adjusted_data$starting_round == starting_points[i + 1],]$cumulative_portfolio_score + offset
}
ggplot(adjusted_data) + 
  geom_line(aes(x=roundNumber,y=cumulative_portfolio_score+offset,color=as.factor(starting_round)),linewidth=1,alpha=0.7) +
  labs(color = "starting round") + ylab("cumulative portfolio score") + 
  ggtitle("Cumulative performance of ensembles of models predating the indicated starting round")
ggsave("portfolio-performances-05corr-2mmc.png",scale=0.5,width=20,height=15)
