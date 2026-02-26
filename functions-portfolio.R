

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

# Evaluate an expression while suppressing stdout/stderr messages from solver internals.
quiet_eval <- function(expr) {
  expr_sub <- substitute(expr)
  result <- NULL
  suppressWarnings(
    suppressMessages(
      utils::capture.output(
        utils::capture.output(
          result <- eval(expr_sub, envir = parent.frame()),
          type = "message"
        ),
        type = "output"
      )
    )
  )
  result
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
  optimized <- quiet_eval({
    spec <- portfolioSpec()
    setType(spec) <- "CVAR"
    setSolver(spec) <- "solveRglpk.CVAR"
    TS <- timeSeries(data,dates)
    colnames(TS) <- colnames(data)
    tangencyPortfolio(TS, spec = spec, constraints = "LongOnly")
  })
  return(optimized)
}



minvariance_portfolio <- function(daily_data) {
  data <- daily_data
  dates <- seq.Date(from = as.Date("1900-01-01"), by = "day", length.out = dim(data)[1])
  optimized <- quiet_eval({
    spec <- portfolioSpec()
    setType(spec) <- "CVAR"
    setSolver(spec) <- "solveRglpk.CVAR"
    TS <- timeSeries(data,dates)
    colnames(TS) <- colnames(data)
    minvariancePortfolio(TS, spec = spec, constraints = "LongOnly")
  })
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
virtual_returns <- function(daily, portfolio, prefix = "") {

  daily <- dplyr::select(daily, portfolio$name) %>% na.omit()

  if (nrow(daily) < 2) {
    output <- data.frame(mean = NA, Cov = NA, CVaR = NA, VaR = NA, MaxDD = NA, n = 0)
    if (prefix != "") names(output) <- paste0(prefix, "_", names(output))
    return(output)
  }

  weighted_returns <- as.numeric(as.matrix(daily) %*% matrix(portfolio$weight, ncol = 1))
  max_dd <- tryCatch(
    round(as.numeric(PerformanceAnalytics::maxDrawdown(weighted_returns)), 4),
    error = function(e) NA_real_
  )

  dates <- seq.Date(from = as.Date("1900-01-01"), by = "day", length.out = dim(daily)[1])

  port <- quiet_eval({
    ewSpec <- portfolioSpec()
    setType(ewSpec) <- "CVAR"
    setSolver(ewSpec) <- "solveRglpk.CVAR"
    setWeights(ewSpec) <- portfolio$weight
    feasiblePortfolio(timeSeries(daily, dates), spec = ewSpec, constraints = "LongOnly")
  })
  output <- data.frame(mean = round(fPortfolio::getTargetReturn(port)[1], 4),
                       Cov = round(fPortfolio::getTargetRisk(port)[1], 4),
                       CVaR = round(fPortfolio::getTargetRisk(port)[3], 4),
                       VaR = round(fPortfolio::getTargetRisk(port)[4], 4),
                       MaxDD = max_dd,
                       n = dim(daily)[1])
  if (prefix != "") names(output) <- paste0(prefix, "_", names(output))
  return(output)
}


# Build portfolios.
#
build_portfolio <- function(daily,threshold, max_single_model_weight = 0.35) {
  if (ncol(daily) == 0) {
    stop("No models available to build a portfolio.")
  }

  if (ncol(daily) == 1) {
    portfolio <- data.frame(name = colnames(daily), weight = 1)
    return(portfolio)
  }

  tangency_weights <- tangency_portfolio(daily) %>%
    cleanup_portfolio() %>%
    dplyr::rename(weight_tangency = weight)

  minvariance_weights <- minvariance_portfolio(daily) %>%
    cleanup_portfolio() %>%
    dplyr::rename(weight_minvariance = weight)

  portfolio <- dplyr::full_join(
    tangency_weights,
    minvariance_weights,
    by = "name"
  ) %>%
    dplyr::mutate(
      weight_tangency = tidyr::replace_na(weight_tangency, 0),
      weight_minvariance = tidyr::replace_na(weight_minvariance, 0),
      weight = (weight_tangency + weight_minvariance) / 2
    ) %>%
    dplyr::select(name, weight)

  weight_sum <- sum(portfolio$weight, na.rm = TRUE)
  if (!is.finite(weight_sum) || weight_sum <= 0) {
    stop("Deterministic tangency/minvariance averaging produced invalid weights.")
  }

  portfolio <- portfolio %>%
    dplyr::mutate(weight = weight / weight_sum) %>%
    dplyr::arrange(dplyr::desc(weight))

  return(portfolio)
}

build_plot <- function(portfolio,starting_point) { # name weights starting round
  plot_data <- dplyr::select(daily_data,c(roundNumber,portfolio$name))
  plot_data <- plot_data[complete.cases(plot_data),]
  weighted_data <- plot_data %>%
    mutate(across(all_of(portfolio$name), 
                  ~ . * portfolio$weight[portfolio$name == cur_column()])) %>%
    dplyr::select(-roundNumber) %>%
    rowSums()
  result <- data.frame(roundNumber = plot_data$roundNumber, cumulative_portfolio_score = cumsum(weighted_data), starting_round = starting_point)  
  
  return(result)
} 
