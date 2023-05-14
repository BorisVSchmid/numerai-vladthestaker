#
# Functions
#
##############

custom_query <- function(username) {paste0('query{v3UserProfile(modelName: \"',username,'\") {roundModelPerformances {
                  corr
                  corrWMetamodel
                  corr20V2
                  corrPercentile
                  corr20V2Percentile
                  tc
                  tcPercentile
                  roundNumber
                  roundResolved
                }
              }
            }'
  )
}

model_performance <- function(modelName,fromRound,toRound) {
  output <- run_query(query = custom_query(tolower(modelName)), auth=FALSE)$v3UserProfile$roundModelPerformances
  return(output %>% 
           dplyr::filter(roundNumber >= fromRound) %>%
           dplyr::filter(roundNumber <= toRound))
}

if (!exists("mem_model_performance")) {
  mem_model_performance <- memoise(model_performance)
}

# Load in the performance data. 
#
# We are splitting up performance of a model into an _corr model and _tc model, and optimize those independently.
build_RAW <- function (model_df,relative=FALSE) {
  
  model_names <- model_df$ModelName
  model_starts <- model_df$`Starting Era`
  model_ends <- model_df$`Last Era`
  
  RAW <- data.frame()
  for (i in 1:length(model_names)) {
    
    # Don't spam the API.
    Sys.sleep(0.2)
    print(model_names[i])
    
    # Add corr (1x by default)
    temp <- mem_model_performance(model_names[i],model_starts[i],model_ends[i])
    if (relative == TRUE) {
      temp <- dplyr::select(temp,roundNumber,corr20V2Percentile)
    } else {
      temp <- dplyr::select(temp,roundNumber,corr20V2)
    }
    temp$name <- paste0(model_names[i],"_corr")
    colnames(temp) <- c("roundNumber","score","name")
    RAW <- rbind(RAW,temp)
    
    # Add TC (1x by default)
    temp <- mem_model_performance(model_names[i],model_starts[i],model_ends[i])
    if (relative == TRUE) {
      temp <- dplyr::select(temp,roundNumber,tcPercentile)
    } else {
      temp <- dplyr::select(temp,roundNumber,tc)
    }
    temp$name <- paste0(model_names[i],"_tc")
    colnames(temp) <- c("roundNumber","score","name")
    RAW <- rbind(RAW,temp)    
  }
  
  data_ts <-  RAW %>% group_by(name,roundNumber) %>% dplyr::ungroup() %>% tidyr::pivot_wider(names_from = name,values_from = score) %>% dplyr::select(-roundNumber)
  
  return(data_ts)
}



tangency_portfolio <- function(daily_data) {
  data <- daily_data
  spec <- portfolioSpec()
  setType(spec) <- "CVAR"
  setSolver(spec) <- "solveRglpk.CVAR"
  TS <- timeSeries(data)
  colnames(TS) <- colnames(data)
  optimized <- tangencyPortfolio(TS, spec = spec, constraints = "LongOnly")
  return(optimized)
}

minvariance_portfolio <- function(daily_data) {
  data <- daily_data
  spec <- portfolioSpec()
  setType(spec) <- "CVAR"
  setSolver(spec) <- "solveRglpk.CVAR"
  TS <- timeSeries(data)
  colnames(TS) <- colnames(data)
  optimized <- minvariancePortfolio(TS, spec = spec, constraints = "LongOnly")
  return(optimized)
}



#
# Clean up the returned portfolio into something we can add to a dataframe.
#
cleanup_portfolio <- function(portfolio) {
  
  weights <- data.frame(getWeights(portfolio))
  colnames(weights) <- c("weight")
  weights <- rownames_to_column(weights, var = "name")
  
  # Some trouble to get this into a nice dataframe
  corr_outcomes <- weights[grepl("_corr", weights$name),]
  colnames(corr_outcomes) <- c("name","corr_weight")
  corr_outcomes$name <- str_replace(corr_outcomes$name, "(_corr|_tc)","")
  tc_outcomes <- weights[grepl("_tc", weights$name),]
  colnames(tc_outcomes) <- c("name","tc_weight")
  tc_outcomes$name <- str_replace(tc_outcomes$name, "(_corr|_tc)","")
  outcome <- full_join(corr_outcomes,tc_outcomes)
  try(outcome[is.na(outcome$corr_weight),]$corr_weight <- 0, silent = TRUE)
  try(outcome[is.na(outcome$tc_weight),]$tc_weight <- 0, silent = TRUE)
  
  outcome <- outcome[outcome$corr_weight + outcome$tc_weight > 0.001,]
  
  return(outcome)
} 

virtual_returns <- function(merged_portfolio,data_ts,types="both") {
  
  if (types == "both") {
    included <- c(paste0(merged_portfolio[merged_portfolio$corr_weight > 0,]$name,"_corr"),
                  paste0(merged_portfolio[merged_portfolio$tc_weight > 0,]$name,"_tc"))
  } else {
    included <- c(paste0(merged_portfolio$name,"_",types))
  }
  
  daily_data <- dplyr::select(data_ts,any_of(included))
  daily_data <- daily_data[complete.cases(daily_data),]
  #
  ewSpec <- portfolioSpec()
  setType(ewSpec) <- "CVAR"
  setSolver(ewSpec) <- "solveRglpk.CVAR"
  
  weight_list <- c()
  for (n in colnames(daily_data)) {
    if (n %in% paste0(merged_portfolio$name,'_corr')) {
      weight_list <- append(weight_list,merged_portfolio[paste0(merged_portfolio$name,'_corr') == n,]$corr_weight)
    } else if (n %in% paste0(merged_portfolio$name,'_tc')) {
      weight_list <- append(weight_list,merged_portfolio[paste0(merged_portfolio$name,'_tc') == n,]$tc_weight)
    }
  }
  
  setWeights(ewSpec) <- weight_list
  port2 <- feasiblePortfolio(timeSeries(daily_data), spec = ewSpec, constraints = "LongOnly")
  return(c(round(fPortfolio::getTargetReturn(port2)[1],4),
           round(fPortfolio::getTargetRisk(port2)[1],4),
           round(fPortfolio::getTargetRisk(port2)[3],4),
           round(fPortfolio::getTargetRisk(port2)[4],4),
           samplesize = dim(daily_data)[1]))
}
