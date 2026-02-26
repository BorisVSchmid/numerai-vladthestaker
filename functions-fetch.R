## Define model performance query
#
is_vlad_verbose <- function() {
  verbose_flag <- tolower(Sys.getenv("VLAD_VERBOSE", "0"))
  verbose_flag %in% c("1", "true", "yes", "y")
}

vlad_log <- function(...) {
  if (is_vlad_verbose()) {
    message(...)
  }
}

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
                    percentile
                  }
                }
              }')
  return(list(query = qry, variables = NULL))
}


model_performance <- function(modelName, fromRound, currentRound) {
  empty_result <- data.frame(
    roundNumber = integer(),
    corr_abs = numeric(),
    corr_rel = numeric(),
    mmc_abs = numeric(),
    mmc_rel = numeric()
  )

  # Don't rate-limit the API
  Sys.sleep(1)
  #
  lastNRounds <- currentRound - fromRound + 1
  vlad_log(
    "Fetching data from ",
    fromRound,
    " to ",
    currentRound,
    ", aka ",
    lastNRounds,
    " rounds."
  )
  if (lastNRounds <= 0) {
    message(paste("No rounds to fetch for", modelName, "from", fromRound, "to", currentRound))
    return(empty_result)
  }
  n_tries <- 3
  retry_delay <- 10 # Seconds
  
  for (i in 1:n_tries) {
    tryCatch({
      # Fetch data
      raw_output <- run_query(query = custom_query(custom_query_modelID(tolower(modelName)), lastNRounds))$data$v2RoundModelPerformances
      
      # Check if output is empty
      if (length(raw_output) == 0) {
        message(paste("No data found for", modelName))
        return(empty_result)
      }
      
      # Process the output safely
      processed_data <- lapply(raw_output, function(round) {
        if (is.null(round$submissionScores) || length(round$submissionScores) == 0) {
          return(NULL)  # Skip rounds with no data
        }
        
        # Flatten submissionScores for this round
        scores <- round$submissionScores
        round_rows <- lapply(scores, function(score) {
          if (is.null(score)) {
            return(NULL)
          }
          display_name <- if (is.null(score$displayName) || length(score$displayName) == 0) {
            NA_character_
          } else {
            as.character(score$displayName[[1]])
          }
          score_value <- if (is.null(score$value) || length(score$value) == 0) {
            NA_real_
          } else {
            as.numeric(score$value[[1]])
          }
          score_percentile <- if (is.null(score$percentile) || length(score$percentile) == 0) {
            NA_real_
          } else {
            as.numeric(score$percentile[[1]])
          }
          score_day <- if (is.null(score$day) || length(score$day) == 0) {
            NA_integer_
          } else {
            as.integer(score$day[[1]])
          }
          data.frame(
            roundNumber = round$roundNumber,
            displayName = display_name,
            value = score_value,
            percentile = score_percentile,
            day = score_day,
            stringsAsFactors = FALSE
          )
        })
        round_rows <- round_rows[!sapply(round_rows, is.null)]
        if (length(round_rows) == 0) {
          return(NULL)
        }
        round_df <- do.call(rbind, round_rows)
        return(round_df)
      })
      
      processed_data <- processed_data[!sapply(processed_data, is.null)]
      if (length(processed_data) == 0) {
        message(paste("No data found for", modelName))
        return(empty_result)
      }

      # Combine all processed data into a single data frame
      combined_data <- do.call(rbind, processed_data)

      if (nrow(combined_data) == 0) {
        message(paste("No data found for", modelName))
        return(empty_result)
      }
      
      # Filter and pivot as needed. Keep the latest available day per round/target.
      latest_scores <- combined_data %>%
        dplyr::filter(roundNumber >= fromRound, roundNumber <= currentRound) %>%
        dplyr::filter(!is.na(day), day > 10 & day <= 20) %>%
        dplyr::group_by(roundNumber, displayName) %>%
        dplyr::slice_max(order_by = day, n = 1, with_ties = FALSE) %>%
        dplyr::ungroup() %>%
        dplyr::select(roundNumber, displayName, value, percentile)

      if (nrow(latest_scores) == 0) {
        message(paste("No data found for", modelName))
        return(empty_result)
      }

      value_data <- latest_scores %>%
        dplyr::select(roundNumber, displayName, value) %>%
        dplyr::group_by(roundNumber, displayName) %>%
        dplyr::summarise(value = dplyr::last(value), .groups = "drop") %>%
        tidyr::pivot_wider(
          names_from = displayName,
          values_from = value,
          values_fill = list(value = NA_real_)
        )

      percentile_data <- latest_scores %>%
        dplyr::select(roundNumber, displayName, percentile) %>%
        dplyr::group_by(roundNumber, displayName) %>%
        dplyr::summarise(percentile = dplyr::last(percentile), .groups = "drop") %>%
        tidyr::pivot_wider(
          names_from = displayName,
          values_from = percentile,
          values_fill = list(percentile = NA_real_)
        )

      ensure_metric_columns <- function(df) {
        required_columns <- c("canon_corr", "canon_mmc")
        for (metric_column in required_columns) {
          if (!metric_column %in% names(df)) {
            df[[metric_column]] <- NA_real_
          }
        }
        df
      }

      value_data <- ensure_metric_columns(value_data)
      percentile_data <- ensure_metric_columns(percentile_data)

      if (anyDuplicated(value_data$roundNumber) > 0 || anyDuplicated(percentile_data$roundNumber) > 0) {
        stop("Duplicate roundNumber rows found after widening value/percentile data.")
      }

      filtered_data <- dplyr::full_join(
        value_data %>% dplyr::select(roundNumber, canon_corr, canon_mmc),
        percentile_data %>% dplyr::select(roundNumber, canon_corr, canon_mmc),
        by = "roundNumber",
        suffix = c("_abs", "_rel")
      ) %>%
        dplyr::arrange(roundNumber) %>%
        dplyr::rename(
          corr_abs = canon_corr_abs,
          corr_rel = canon_corr_rel,
          mmc_abs = canon_mmc_abs,
          mmc_rel = canon_mmc_rel
        )
      
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
build_RAW <- function (model_df, MinfromRound = 1, currentRound) {
  
  model_names <- model_df$name
  model_starts <- model_df$start

  metric_names <- c("corr_abs", "corr_rel", "mmc_abs", "mmc_rel")
  raw_tables <- lapply(metric_names, function(metric_name) {
    data.frame(roundNumber = integer(), name = character(), score = numeric(), stringsAsFactors = FALSE)
  })
  names(raw_tables) <- metric_names

  progress_bar <- NULL
  if (length(model_names) > 0) {
    progress_bar <- utils::txtProgressBar(min = 0, max = length(model_names), style = 3)
    on.exit({
      close(progress_bar)
      cat("\n")
    }, add = TRUE)
  }

  for (i in seq_along(model_names)) {
    # Don't spam the API.
    Sys.sleep(0.2)
    if (!is.null(progress_bar)) {
      utils::setTxtProgressBar(progress_bar, i)
    }
    vlad_log("Fetching model ", model_names[i], " (", i, "/", length(model_names), ").")
    
    temp <- model_performance(model_names[i], max(MinfromRound, model_starts[i]), currentRound)
    
    # Handle empty data frames
    if (nrow(temp) == 0) {
      message(paste("No data found for model", model_names[i], "from round", MinfromRound, "to", currentRound))
      next  # Skip to the next iteration if no data is found
    }

    for (metric_name in metric_names) {
      temp_metric <- data.frame(
        roundNumber = temp$roundNumber,
        name = model_names[i],
        score = temp[[metric_name]],
        stringsAsFactors = FALSE
      )
      raw_tables[[metric_name]] <- rbind(raw_tables[[metric_name]], temp_metric)
    }
  }

  build_metric_table <- function(raw_metric, metric_name) {
    metric_table <- raw_metric %>%
      na.omit() %>%
      dplyr::distinct(roundNumber, name, score) %>%
      tidyr::pivot_wider(
        names_from = name,
        values_from = score,
        values_fill = NA_real_
      ) %>%
      dplyr::arrange(roundNumber)

    if (nrow(metric_table) == 0) {
      stop("No data retrieved for metric `", metric_name, "`. Please check your inputs.")
    }

    data.frame(metric_table)
  }

  data_ts <- lapply(metric_names, function(metric_name) {
    build_metric_table(raw_tables[[metric_name]], metric_name)
  })
  names(data_ts) <- metric_names

  return(data_ts)
}
