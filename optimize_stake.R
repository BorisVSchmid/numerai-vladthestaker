# To make groundhogr work in Rstudio, go to Tools -> Global Options, and change the following two settings:
# Code -> Completion -> Show code Completion (set to Never)
# Code -> Diagnostics -> Show Diagnostics (remove tick from box)
#

library(groundhog)
pkgs <- c("conflicted","dplyr","tidyr","knitr","readxl","tibble","stringr","memoise","Rnumerai","fPortfolio","ggplot2","ggrepel","PerformanceAnalytics")
groundhog.library(pkgs, "2023-07-05") # For R-4.3.x. You can use "2023-04-21 for R-4.2.x


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



## Read in program-specific functions
#
source("functions.R")
options(scipen = 999)



## Vlad Input Data and Settings
#
NMR <- 142.6
model_df <- read_excel("Optimize-Me-30nov2023.xlsx")          # Read in the list of model names and their start (and possibly end) round.
colnames(model_df) <- c("name","start","notes")
current_round <- Rnumerai::get_current_round()
oldest_round <- min(model_df$start)



## Collect daily scores, and filter for models that have at least 60 data points (you shouldn't use Vlad for models with less data points)
#  I have set the starting round at 339, as that is the first round of the daily tournament, but you are free to change that round back and forth.
#
daily_data <- build_RAW(model_df, MinfromRound = 339, corr_multiplier = 0.5, mmc_multiplier = 3)
daily_data <- daily_data[,colnames(daily_data) %in% colnames(daily_data)[colSums(!is.na(daily_data)) > 60]]



## calculate stats
#
model_stats <- data.frame(name = colnames(daily_data), 
                          first_round = daily_data$roundNumber[apply(daily_data, 2, function(x) which(!is.na(x))[1])],
                          mean = colMeans(daily_data, na.rm = TRUE), 
                          sd = colSds(daily_data, na.rm = TRUE), 
                          drawdown = apply(daily_data, MARGIN = 2, FUN = function(column) {maxDrawdown(column)}),
                          size = colSums(!is.na(daily_data)),
                          row.names = NULL) %>% dplyr::filter(name != "roundNumber")

model_stats <- model_stats %>% mutate(sharpe = mean / sd,
                                      rho = acf(mean, lag.max = 1, plot = FALSE)$acf[2],
                                      tSSR = ((mean / sd) * sqrt(size - 1)) / sqrt(1 - rho + rho * size))

# plot stats
model_stats$scaled <- unlist(lapply(unlist((lapply(model_stats$tSSR,max,0.01))),sqrt))
ggplot(model_stats) + 
  geom_point(aes(y=mean,x=sd, size=scaled, fill = drawdown),color="black",shape=21) + 
  scale_fill_gradient2(low="green",mid="red",high="black",midpoint=0.9) +
  labs(size = "tSSR Sharpe") +
  geom_text_repel(aes(y=mean,x=sd,label=name),box.padding = 0.6,max.overlaps = 15, force_pull = 0.7,min.segment.length = 1.5)
ggsave("model-performances.png",scale=1,width=15,height=15)



## Define your threshold for what is a good model.
#
# To guide you, I've calculated what the stake-weighted mean performance is of numer.ai's benchmark models,
# and what their stake-weighted drawdown is. I put the thresholds a little below that mean and a little above that drawdown.
#
# numerai_perf <- left_join(model_df,dplyr::select(model_stats,name,mean,drawdown)) %>% na.omit()
# sum(numerai_perf$mean * numerai_perf$notes) / sum(numerai_perf$notes) # weighted mean
benchmark_mean <- 0.00653
# sum(numerai_perf$drawdown * numerai_perf$notes) / sum(numerai_perf$notes) # weighted drawdown
benchmark_drawdown <- 0.841
#
# Tweak these thresholds as you feel is most appropriate
good_models <- model_stats %>% dplyr::filter(mean > benchmark_mean * 0.8, drawdown < benchmark_drawdown / 0.8)



## When do these models start?
#
starting_points <- unique(good_models %>% pull(first_round))
table(starting_points)

  
  
## Calculate portfolios from each of the starting points onwards.
#
# use threshold to remove small stakes from the portfolios (this limits the
# final number of models you would have to stake on)
threshold <- 0.05
#
combined <- data.frame()
for (point in starting_points) {
  print(point)
  tryCatch({
    relevant_models <- dplyr::filter(good_models,first_round <= point) %>% pull(name)
    daily <- daily_data %>% dplyr::filter(roundNumber >= point) %>% dplyr::select(all_of(relevant_models)) %>% na.omit()
    portfolio <- build_portfolio(daily,threshold = threshold)
    newreturns <- as.data.frame(unlist(virtual_returns(daily_data,portfolio)))
    merged <- cbind(portfolio,newreturns)
    merged$starting_round <- point
    merged[2:nrow(merged),4:9] <- ""
    combined <- rbind(combined,merged,"")
  }, error = function(e) {
    message("An error occurred: ", e$message)
  })
}
  
  
  
## Calculate merged portfolio (stake on this, submit a metapopulation model weighted to this.)
#
condensed <- combined %>% dplyr::filter(name != "") %>% dplyr::select(name,weight,stake)
condensed$weight <- as.numeric(condensed$weight)
condensed$stake <- as.numeric(condensed$stake)
condensed <- condensed %>% group_by(name) %>% summarise(weight = sum(weight)/sum(condensed$weight), stake = sum(stake)/sum(condensed$weight))
condensed_returns <- as.data.frame(unlist(virtual_returns(daily_data,condensed)))
condensed <- cbind(condensed,condensed_returns)
condensed[2:nrow(condensed),4:8] <- ""
condensed$stake <- round(condensed$stake)
  


## Printout row-concatenated portfolios for different starting points.
#
kable(combined,digits=3)

#   |name                |weight |stake |mean   |Cov    |CVaR   |VaR    |samplesize |starting_round |
#   |:-------------------|:------|:-----|:------|:------|:------|:------|:----------|:--------------|
#   |INTEGRATION_TEST    |0.479  |68    |0.0196 |0.0201 |0.0117 |0.0079 |279        |339            |
#   |V42_LGBM_CLAUDIA20  |0.221  |32    |       |       |       |       |           |               |
#   |V42_LGBM_TEAGER20   |0.076  |11    |       |       |       |       |           |               |
#   |V42_LGBM_TEAGER60   |0.162  |23    |       |       |       |       |           |               |
#   |V4_LGBM_VICTOR20    |0.061  |9     |       |       |       |       |           |               |
#   |                    |       |      |       |       |       |       |           |               |
#   |INTEGRATION_TEST    |0.451  |64    |0.019  |0.0197 |0.0127 |0.0089 |279        |340            |
#   |V41_LGBM_CAROLINE20 |0.049  |7     |       |       |       |       |           |               |
#   |V42_LGBM_CLAUDIA20  |0.196  |28    |       |       |       |       |           |               |
#   |V42_LGBM_TEAGER20   |0.072  |10    |       |       |       |       |           |               |
#   |V42_LGBM_TEAGER60   |0.169  |24    |       |       |       |       |           |               |
#   |V4_LGBM_VICTOR20    |0.064  |9     |       |       |       |       |           |               |
#   |                    |       |      |       |       |       |       |           |               |

## Printout combined portfolio across starting rounds (equal weight for each starting points for now)
# For Numer.ai's models, the two timepoints (starting_round 339 and 340) don't matter much, so merging them changes little.
#
kable(condensed,digits=3)

#    name                | weight| stake|mean   |Cov    |CVaR  |VaR    |samplesize |
#   |:-------------------|------:|-----:|:------|:------|:-----|:------|:----------|
#   |INTEGRATION_TEST    |  0.465|    66|0.0193 |0.0199 |0.012 |0.0089 |279        |
#   |V41_LGBM_CAROLINE20 |  0.024|     4|       |       |      |       |           |
#   |V42_LGBM_CLAUDIA20  |  0.209|    30|       |       |      |       |           |
#   |V42_LGBM_TEAGER20   |  0.074|    10|       |       |      |       |           |
#   |V42_LGBM_TEAGER60   |  0.166|    24|       |       |      |       |           |
#   |V4_LGBM_VICTOR20    |  0.062|     9|       |       |      |       |           |


# This is numer.ai's current stake distribution for models with a samplesize > 100. (nov 2023)
numerai_stake <- dplyr::filter(model_df,name %in% (dplyr::filter(model_stats, first_round < 400) %>% pull(name)))
colnames(numerai_stake) <- c("name","weight","stake")
numerai_stake$weight <- numerai_stake$stake / sum(numerai_stake$stake)


# You can calculate its return by feeding virtual_returns the daily_data and a dataframe of c(name, weight)
kable(virtual_returns(daily_data,numerai_stake), digits=4)

#   |   mean|    Cov|   CVaR|   VaR| samplesize|
#   |------:|------:|------:|-----:|----------:|
#   | 0.0066| 0.0257| 0.0486| 0.038|        278|

# So, using Vlad suggests a higher account-wide return is possible against a lower CVaR and VaR. Time for stake management? :-).