run_query <- function(query, variables = list()) {
  response <- httr2::request("https://api-tournament.numer.ai/") |>
    httr2::req_body_json(list(query = query, variables = variables)) |>
    httr2::req_timeout(seconds = 180) |>
    httr2::req_retry(
      max_tries = 5L,
      retry_on_failure = TRUE,
      is_transient = function(response) {
        httr2::resp_status(response) %in% c(429L, 500L, 502L, 503L, 504L)
      }
    ) |>
    httr2::req_perform() |>
    httr2::resp_body_json(simplifyVector = FALSE)

  if (length(response$errors) > 0L) {
    error_messages <- vapply(
      response$errors,
      function(error) error$message,
      character(1L)
    )
    stop("Numerai API error: ", paste(error_messages, collapse = "; "), call. = FALSE)
  }
  if (is.null(response$data)) {
    stop("Numerai API response did not contain data.", call. = FALSE)
  }
  response$data
}


fetch_current_round <- function(tournament_id = 8L, query_runner = run_query) {
  query <- paste(
    "query CurrentRound($tournament: Int!) {",
    "rounds(tournament: $tournament, number: 0) { number }",
    "}"
  )
  data <- query_runner(query, list(tournament = as.integer(tournament_id)))
  if (length(data$rounds) != 1L) {
    stop("Numerai did not return one current tournament round.", call. = FALSE)
  }
  as.integer(data$rounds[[1L]]$number)
}


