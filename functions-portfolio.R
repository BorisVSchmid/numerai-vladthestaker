

#
# Statistics function.
#
acf1_pairwise <- function(series) {
  if (!is.numeric(series) || length(series) < 2) {
    stop("Series must be a numeric vector with at least two elements.")
  }
  
  # Create a lagged version of the series
  lagged_series <- c(NA, series[-length(series)])
  
  # Calculate the correlation with complete observations
  acf1_value <- cor(series, lagged_series, use = "complete.obs")
  
  return(acf1_value)
}


## Cumulative Plotting function.
# 
cumulative_plot <- function(model_df,starting_era,good_models_all,daily,type) {
  
  subset_daily <- dplyr::filter(daily,roundNumber >= starting_era)
  subset_data <- dplyr::select(subset_daily,roundNumber,paste0(good_models_all,type)) %>%
                 mutate(across(-roundNumber, ~cumsum(replace_na(.x, 0))))
  subset_data <- subset_data %>% pivot_longer(cols = -roundNumber, names_to = "model", values_to = "value")
  ggplot(subset_data) + geom_line(aes(x=roundNumber,y=value,color=model))
}



tangency_portfolio <- function(daily_data) {
  data <- daily_data
  dates <- seq.Date(from = as.Date("1900-01-01"), by = "day", length.out = dim(data)[1])
  spec <- portfolioSpec()
  setType(spec) <- "CVAR"
  setSolver(spec) <- "solveRglpk.CVAR"
  TS <- timeSeries(data,dates)
  colnames(TS) <- colnames(data)
  optimized <- tangencyPortfolio(TS, spec = spec, constraints = "LongOnly")
  return(optimized)
}



minvariance_portfolio <- function(daily_data) {
  data <- daily_data
  dates <- seq.Date(from = as.Date("1900-01-01"), by = "day", length.out = dim(data)[1])
  spec <- portfolioSpec()
  setType(spec) <- "CVAR"
  setSolver(spec) <- "solveRglpk.CVAR"
  TS <- timeSeries(data,dates)
  colnames(TS) <- colnames(data)
  optimized <- minvariancePortfolio(TS, spec = spec, constraints = "LongOnly")
  return(optimized)
}




## Clean up the returned portfolio into something we can add to a dataframe.
#
cleanup_portfolio <- function(portfolio) {
  
  weights <- data.frame(getWeights(portfolio))
  colnames(weights) <- c("weight")
  weights <- rownames_to_column(weights, var = "name")
  return(weights[weights$weight > 0.001,])
} 

## Calculate returns
#
virtual_returns <- function(daily,portfolio) {
  
  daily <- dplyr::select(daily,portfolio$name) %>% na.omit()
  dates <- seq.Date(from = as.Date("1900-01-01"), by = "day", length.out = dim(daily)[1])
  
  ewSpec <- portfolioSpec()
  setType(ewSpec) <- "CVAR"
  setSolver(ewSpec) <- "solveRglpk.CVAR"

  setWeights(ewSpec) <- portfolio$weight
  port <- feasiblePortfolio(timeSeries(daily, dates), spec = ewSpec, constraints = "LongOnly")
  output <- c(round(fPortfolio::getTargetReturn(port)[1],4),
           round(fPortfolio::getTargetRisk(port)[1],4),
           round(fPortfolio::getTargetRisk(port)[3],4),
           round(fPortfolio::getTargetRisk(port)[4],4),
           samplesize = dim(daily)[1])
  return(t(output))
}


# Build portfolios.
#
build_portfolio <- function(daily,threshold) {

  portfolio1 <- tangency_portfolio(daily[sample(nrow(daily),replace = TRUE),]) %>% cleanup_portfolio()
  portfolio2 <- minvariance_portfolio(daily[sample(nrow(daily),replace = TRUE),]) %>% cleanup_portfolio()
  for (i in 1:39) {
    portfolio1 <- rbind(portfolio1,tangency_portfolio(daily[sample(nrow(daily),replace = TRUE),]) %>% cleanup_portfolio())
    portfolio2 <- rbind(portfolio2,minvariance_portfolio(daily[sample(nrow(daily),replace = TRUE),]) %>% cleanup_portfolio())
  } 
  portfolio <- rbind(portfolio1,portfolio2) %>% group_by(name) %>% summarise(weight = mean(weight))
  
  # rebalance to remove small weights
  portfolio <- portfolio[portfolio$weight > threshold,]
  portfolio$weight <- round(portfolio$weight * 1/sum(portfolio$weight),3)
  #
  # Calculating stakesize for different multipliers
  #
  portfolio$stake <- round(portfolio$weight * NMR)
  return(portfolio)
}

build_plot <- function(portfolio,starting_point) { # name weights starting round
  plot_data <- dplyr::select(daily_data,c(roundNumber,portfolio$name))
  plot_data <- plot_data[complete.cases(plot_data),]
  weighted_data <- plot_data %>%
    mutate(across(all_of(portfolio$name), 
                  ~ . * portfolio$weight[portfolio$name == cur_column()])) %>%
    select(-roundNumber) %>%
    rowSums()
  result <- data.frame(roundNumber = plot_data$roundNumber, cumulative_portfolio_score = cumsum(weighted_data), starting_round = starting_point)  
  
  return(result)
} 