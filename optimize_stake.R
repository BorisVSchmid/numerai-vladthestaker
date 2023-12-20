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
model_df <- read_excel("Optimize-Me-30nov2023.xlsx")          # Read in the list of model names and their start (and possibly end) round.
NMR <- 142.6 # sum(model_df$Notes) 142.6
colnames(model_df) <- c("name","start","notes")
current_round <- Rnumerai::get_current_round()
oldest_round <- min(model_df$start)



## Collect daily scores, and filter for models that have at least 60 data points (you shouldn't use Vlad for models with less data points)
#  I have set the starting round at 339, as that is the first round of the daily tournament, but you are free to change that round back and forth.
#
daily_data <- build_RAW(model_df, MinfromRound = 339, corr_multiplier = 0.5, mmc_multiplier = 2)
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
benchmark_mean <- 0.00532
# sum(numerai_perf$drawdown * numerai_perf$notes) / sum(numerai_perf$notes) # weighted drawdown
benchmark_drawdown <- 0.755
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

#   |name               |weight |stake |mean   |Cov    |CVaR   |VaR    |samplesize |starting_round |
#   |:------------------|:------|:-----|:------|:------|:------|:------|:----------|:--------------|
#   |INTEGRATION_TEST   |0.439  |63    |0.014  |0.0157 |0.0118 |0.0074 |289        |339            |
#   |V41_LGBM_XERXES20  |0.051  |7     |       |       |       |       |           |               |
#   |V42_LGBM_CLAUDIA20 |0.182  |26    |       |       |       |       |           |               |
#   |V42_LGBM_ROWAN20   |0.064  |9     |       |       |       |       |           |               |
#   |V42_LGBM_TEAGER20  |0.1    |14    |       |       |       |       |           |               |
#   |V42_LGBM_TEAGER60  |0.117  |17    |       |       |       |       |           |               |
#   |V4_LGBM_VICTOR20   |0.046  |7     |       |       |       |       |           |               |
#   |                   |       |      |       |       |       |       |           |               |
#   |INTEGRATION_TEST   |0.427  |61    |0.0142 |0.0163 |0.0129 |0.0084 |289        |340            |
#   |V41_EXAMPLE_PREDS  |0.051  |7     |       |       |       |       |           |               |
#   |V42_LGBM_CLAUDIA20 |0.163  |23    |       |       |       |       |           |               |
#   |V42_LGBM_ROWAN20   |0.063  |9     |       |       |       |       |           |               |
#   |V42_LGBM_TEAGER20  |0.099  |14    |       |       |       |       |           |               |
#   |V42_LGBM_TEAGER60  |0.152  |22    |       |       |       |       |           |               |
#   |V4_LGBM_VICTOR20   |0.045  |6     |       |       |       |       |           |               |
#   |                   |       |      |       |       |       |       |           |               |


## Printout combined portfolio across starting rounds (equal weight for each starting points for now)
# For Numer.ai's models, the two timepoints (starting_round 339 and 340) don't matter much, so merging them changes little.
#
kable(condensed,digits=3)

#   |name               | weight| stake|mean   |Cov   |CVaR   |VaR    |samplesize |
#   |:------------------|------:|-----:|:------|:-----|:------|:------|:----------|
#   |INTEGRATION_TEST   |  0.433|    62|0.0141 |0.016 |0.0123 |0.0078 |289        |
#   |V41_EXAMPLE_PREDS  |  0.026|     4|       |      |       |       |           |
#   |V41_LGBM_XERXES20  |  0.026|     4|       |      |       |       |           |
#   |V42_LGBM_CLAUDIA20 |  0.173|    25|       |      |       |       |           |
#   |V42_LGBM_ROWAN20   |  0.064|     9|       |      |       |       |           |
#   |V42_LGBM_TEAGER20  |  0.100|    14|       |      |       |       |           |
#   |V42_LGBM_TEAGER60  |  0.135|    20|       |      |       |       |           |
#   |V4_LGBM_VICTOR20   |  0.046|     7|       |      |       |       |           |


# This is numer.ai's current stake distribution for models with a samplesize > 100. (nov 2023)
numerai_stake <- dplyr::filter(model_df,name %in% (dplyr::filter(model_stats, first_round < 400) %>% pull(name)))
colnames(numerai_stake) <- c("name","weight","stake")
numerai_stake$weight <- numerai_stake$stake / sum(numerai_stake$stake)


# You can calculate its return by feeding virtual_returns the daily_data and a dataframe of c(name, weight)
kable(virtual_returns(daily_data,numerai_stake), digits=4)

#   |   mean|  Cov|  CVaR|    VaR| samplesize|
#   |------:|----:|-----:|------:|----------:|
#   | 0.0054| 0.02| 0.038| 0.0298|        288|

# So, using Vlad suggests a higher account-wide return is possible against a lower CVaR and VaR. Time for stake management? :-).