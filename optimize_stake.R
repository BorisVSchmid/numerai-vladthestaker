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
model_df <- read_excel("Optimize-Me-21dec2023.xlsx")            # Read in the list of model names and their start round. For the Benchmark models, I excluded INTEGRATION_TEST, as that model is being changed over time.
NMR <- 215.541 # sum(model_df$Stakes)
colnames(model_df) <- c("name","start","stakes")
current_round <- Rnumerai::get_current_round()
model_df <- dplyr::filter(model_df, start < current_round - 30) # These models have barely resolved, and don't need to be added in yet (and the query to collect the daily data will fail.)
oldest_round <- min(model_df$start)



## Collect daily scores, and filter for models that have at least 60 data points (you shouldn't use Vlad for models with less data points)
#  I have set the starting round at 339, as that is the first round of the daily tournament, but you are free to change that round back and forth.
#
daily_data <- build_RAW(model_df, MinfromRound = 339, corr_multiplier = 0.5, mmc_multiplier = 2)
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



## Define your own threshold for what the minimal quality of a model is, for it to be considered for portfolio building.
#
good_models <- model_stats %>% dplyr::filter(mean > 0.005)



## When do these models start?
#
starting_points <- unique(good_models %>% pull(first_round))
table(starting_points)

  
  
## Calculate portfolios from each of the starting points onwards.
#
# use threshold to remove small stakes from the portfolios (this limits the
# final number of models you would have to stake on)
threshold <- 0.1
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

# Run 1: from round 339
#   |name               |weight |stake |mean   |Cov    |CVaR  |VaR    |samplesize |starting_round |
#   |:------------------|:------|:-----|:------|:------|:-----|:------|:----------|:--------------|
#   |V42_LGBM_CLAUDIA20 |0.272  |59    |0.0195 |0.0264 |0.026 |0.0221 |291        |339            |
#   |V42_LGBM_CT_BLEND  |0.116  |25    |       |       |      |       |           |               |
#   |V42_LGBM_ROWAN20   |0.09   |19    |       |       |      |       |           |               |
#   |V42_LGBM_TEAGER20  |0.315  |68    |       |       |      |       |           |               |
#   |V42_LGBM_TEAGER60  |0.095  |20    |       |       |      |       |           |               |
#   |V4_LGBM_VICTOR20   |0.112  |24    |       |       |      |       |           |               |
#   |                   |       |      |       |       |      |       |           |               |

# Run 2: from round 339. There is some variation, but not a crazy amount. 
#   |name               |weight |stake |mean   |Cov    |CVaR   |VaR   |samplesize |starting_round |
#   |:------------------|:------|:-----|:------|:------|:------|:-----|:----------|:--------------|
#   |V42_LGBM_CLAUDIA20 |0.249  |54    |0.0197 |0.0266 |0.0262 |0.022 |291        |339            |
#   |V42_LGBM_CT_BLEND  |0.098  |21    |       |       |       |      |           |               |
#   |V42_LGBM_ROWAN20   |0.091  |20    |       |       |       |      |           |               |
#   |V42_LGBM_TEAGER20  |0.369  |80    |       |       |       |      |           |               |
#   |V42_LGBM_TEAGER60  |0.089  |19    |       |       |       |      |           |               |
#   |V4_LGBM_VICTOR20   |0.105  |23    |       |       |       |      |           |               |
#   |                   |       |      |       |       |       |      |           |               |  

# Run 3: from round 370, to see how much effect a shorter time series has. Some more variation, but not bad.
#   |name               |weight |stake |mean   |Cov    |CVaR   |VaR    |samplesize |starting_round |
#   |:------------------|:------|:-----|:------|:------|:------|:------|:----------|:--------------|
#   |V42_EXAMPLE_PREDS  |0.067  |14    |0.0205 |0.0288 |0.0275 |0.0219 |260        |370            |
#   |V42_LGBM_CLAUDIA20 |0.33   |71    |       |       |       |       |           |               |
#   |V42_LGBM_CT_BLEND  |0.092  |20    |       |       |       |       |           |               |
#   |V42_LGBM_ROWAN20   |0.083  |18    |       |       |       |       |           |               |
#   |V42_LGBM_TEAGER20  |0.311  |67    |       |       |       |       |           |               |
#   |V42_LGBM_TEAGER60  |0.116  |25    |       |       |       |       |           |               |
#   |                   |       |      |       |       |       |       |           |               |

## Printout combined portfolio across starting rounds (equal weight for each starting points for now)
# For Numer.ai's models, all models go (almost) equally far back, so there is nothing to merge
#
kable(condensed,digits=3)


# This is numer.ai's current stake distribution for models with a samplesize > 100. (nov 2023)
numerai_stake <- dplyr::filter(model_df,name %in% (dplyr::filter(model_stats, first_round < 400) %>% pull(name)))
colnames(numerai_stake) <- c("name","weight","stake")
numerai_stake$weight <- numerai_stake$stake / sum(numerai_stake$stake)


# You can calculate its return by feeding virtual_returns the daily_data and a dataframe of c(name, weight)
kable(virtual_returns(daily_data,numerai_stake), digits=4)

#   |   mean|    Cov|   CVaR|    VaR| samplesize|
#   |------:|------:|------:|------:|----------:|
#   | 0.0079| 0.0213| 0.0397| 0.0316|        290|

# So, using Vlad suggests a higher account-wide return is possible against a lower CVaR and VaR.
