## Define model performance query
#
run_query <- function(query) {
  # Construct the request
  req <- request("https://api-tournament.numer.ai/") %>%
    req_body_json(query)
  
  # Perform the request with error handling
  resp <- tryCatch({
    req_perform(req)
  }, error = function(e) {
    stop(paste("Request failed:", conditionMessage(e)))
  })
  
  # Check for HTTP errors
  # Debug: Log the raw response content
  if (resp_status(resp) >= 400) {
    print(resp_body_raw(resp))
    stop(paste("HTTP Error:", resp_status_desc(resp), "- Status Code:", resp_status(resp)))
  }
  
  # Parse the response
  content <- resp_body_raw(resp)
  if (length(content) == 0) {
    stop("Empty response from server.")
  }
  
  # Return the parsed JSON response
  resp_body_json(resp)
}

custom_query_modelID <- function(username) {
  q <- paste0('query($modelName: String!) { v3UserProfile(modelName: $modelName) { id } }')
  # Pass modelName as a variable in the query
  o <- run_query(query = list(query = q, variables = list(modelName = username)))
  return(o$data$v3UserProfile$id)
}

custom_query_current_round <- function() {
  q <- paste0('query { rounds(tournament: 8) { number } }')
  # Pass modelName as a variable in the query
  o <- run_query(query = list(query = q))
  return(max(unlist(o$data$rounds)))
}

custom_query <- function(userid, lastNRounds) {
  qry <- paste0('query { v2RoundModelPerformances(modelId: "', userid, '", tournament: 8, lastNRounds: ', lastNRounds, ') { 
                  roundNumber
                  submissionScores {
                    date
                    day
                    displayName
                    value
                  }
                }
              }')
  return(list(query = qry, variables = NULL))
}


model_performance <- function(modelName, fromRound, currentRound) {
  # Don't rate-limit the API
  Sys.sleep(1)
  #
  lastNRounds <- currentRound - fromRound
  print(paste0("Fetching data from ", fromRound, " to ", currentRound, ", aka ", lastNRounds, " rounds."))
  n_tries <- 3
  retry_delay <- 10 # Seconds
  
  for (i in 1:n_tries) {
    tryCatch({
      # Fetch data
      raw_output <- run_query(query = custom_query(custom_query_modelID(tolower(modelName)), lastNRounds))$data$v2RoundModelPerformances
      
      # Check if output is empty
      if (length(raw_output) == 0) {
        message(paste("No data found for", modelName))
        return(data.frame(roundNumber = integer(), corr = numeric(), mmc = numeric(), bmc = numeric()))
      }
      
      # Process the output safely
      processed_data <- lapply(raw_output, function(round) {
        if (is.null(round$submissionScores)) {
          return(NULL)  # Skip rounds with no data
        }
        
        # Flatten submissionScores for this round
        scores <- round$submissionScores
        round_df <- do.call(rbind, lapply(scores, function(score) {
          data.frame(
            roundNumber = round$roundNumber,
            displayName = score$displayName,
            value = score$value,
            day = score$day,
            stringsAsFactors = FALSE
          )
        }))
        return(round_df)
      })
      
      # Combine all processed data into a single data frame
      combined_data <- do.call(rbind, processed_data)
      
      # Filter and pivot as needed
      filtered_data <- combined_data %>%
        dplyr::filter(day > 10 & day <= 20) %>%
        tidyr::pivot_wider(names_from = displayName, values_from = value) %>%
        dplyr::select(roundNumber, canon_corr, canon_mmc, canon_bmc)
      
      colnames(filtered_data) <- c("roundNumber", "corr", "mmc", "bmc")
      
      return(filtered_data)
    }, error = function(e) {
      if (grepl("HTTP 500", e$message) || grepl("500 - Internal Server Error", e$message)) {
        message(paste("Attempt", i, "failed with HTTP 500 error. Retrying in", retry_delay, "seconds..."))
        Sys.sleep(retry_delay)
      } else {
        stop(e)
      }
    })
  }
  stop("Failed to fetch data after multiple retries.")
}


# Function to remove NAs from list elements
remove_na <- function(lst) {
  lapply(lst, function(x) x[!is.na(x)])
}

# Define a function to replace numeric(0) with NA
replace_numeric0_with_na <- function(x) {
  if (length(x) == 0) {
    return(NA)
  } else {
    return(x)
  }
}


# Load in the performance data. 
#
build_RAW <- function (model_df, MinfromRound = 1, currentRound, corr_multiplier = 0.5, mmc_multiplier = 2, bmc_multiplier = 0) {
  
  model_names <- model_df$name
  model_starts <- model_df$start
  
  RAW <- data.frame()
  for (i in 1:length(model_names)) {
    # Don't spam the API.
    Sys.sleep(0.2)
    print(model_names[i])
    
    temp <- model_performance(model_names[i], max(MinfromRound, model_starts[i]), currentRound)
    
    # Handle empty data frames
    if (nrow(temp) == 0) {
      message(paste("No data found for model", model_names[i], "from round", MinfromRound, "to", currentRound))
      next  # Skip to the next iteration if no data is found
    }
    
    temp <- dplyr::select(temp, roundNumber, corr, mmc, bmc)
    
    # Calculate score
    if (mmc_multiplier == 0 & bmc_multiplier == 0) {
      temp$score <- corr_multiplier * temp$corr
    } else {
      temp$score <- corr_multiplier * temp$corr + mmc_multiplier * temp$mmc + bmc_multiplier * temp$bmc
    }
    temp <- dplyr::select(temp, roundNumber, score)
    temp$name <- model_names[i]
    RAW <- rbind(RAW, temp)    
  }
  
  if (nrow(RAW) == 0) {
    stop("No data retrieved for any model. Please check your inputs.")
  }
  
  data_ts1 <- unique(RAW) %>%
    group_by(name, roundNumber) %>%
    ungroup()
  data_ts <- data_ts1 %>% na.omit() %>%
    tidyr::pivot_wider(names_from = name, values_from = score, values_fill = list(value = NA))
  
  data_ts <- data.frame(dplyr::arrange(data_ts, roundNumber))
  data_ts <- data_ts %>% mutate(across(everything(), remove_na))
  data_ts <- data_ts %>% mutate_all(~ sapply(., replace_numeric0_with_na))
  
  return(data_ts)
}