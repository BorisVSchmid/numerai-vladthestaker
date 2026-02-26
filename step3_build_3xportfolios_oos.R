########
# Rscript to build top-decile averaged portfolios from step2 grid results.
#
# Build on R4.5.2
#
# - Reads step2 grid metrics and step1 corr/mmc abs files.
# - Rebuilds per-cell portfolios for selected return/maxdd cell sets.
# - Writes 3 averaged portfolios + forward OOS cumulative return chart.
#
########

# -------------------- Reproducible libraries --------------------
options(repos = c(CRAN = "https://cran.r-project.org"))
if (!requireNamespace("groundhog", quietly = TRUE)) install.packages("groundhog")
if (!requireNamespace("conflicted", quietly = TRUE)) install.packages("conflicted")
quiet_startup <- tolower(Sys.getenv("VLAD_QUIET_STARTUP", "1")) %in% c("1", "true", "yes", "y")
run_startup_quietly <- function(expr) {
  expr_sub <- substitute(expr)
  if (quiet_startup) {
    invisible(
      suppressWarnings(
        suppressMessages(
          utils::capture.output(
            eval(expr_sub, envir = parent.frame()),
            type = "output"
          )
        )
      )
    )
  } else {
    eval(expr_sub, envir = parent.frame())
  }
}

run_startup_quietly(library(groundhog))
run_startup_quietly(library(conflicted))

run_startup_quietly(groundhog::set.groundhog.folder(
  if (.Platform$OS.type == "windows") {
    file.path(Sys.getenv("LOCALAPPDATA"), "R_groundhog", "groundhog_library")
  } else {
    file.path(path.expand("~"), "R_groundhog", "groundhog_library")
  }
))

run_startup_quietly(conflicts_prefer(dplyr::select))
run_startup_quietly(conflicts_prefer(dplyr::filter))
run_startup_quietly(conflicts_prefer(dplyr::lag))

pkgs <- c(
  "dplyr",
  "tidyr",
  "tibble",
  "ggplot2",
  "readxl",
  "fPortfolio",
  "PerformanceAnalytics",
  "MASS"
)
run_startup_quietly(groundhog.library(pkgs, "2025-06-01"))

# Suppress stray default-device artifacts from non-interactive runs.
if (file.exists("Rplots.pdf")) {
  invisible(file.remove("Rplots.pdf"))
}

source("functions-config.R")


## Settings
#
params <- read_pipeline_parameters("Optimize-Me.xlsx")

base_round_param <- get_param_integer(params, "base_round")
corr_multiplier <- get_param_numeric(params, "corr_multiplier")
mmc_multiplier <- get_param_numeric(params, "mmc_multiplier")
model_names_to_exclude <- get_param_character_vector(params, "model_names_to_exclude", allow_empty = TRUE)
min_models_submitting_per_round <- get_param_integer(params, "min_models_submitting_per_round")

step2_grid_path <- get_param_character(params, "step2_grid_path")
corr_abs_path <- get_param_character(params, "corr_abs_path")
mmc_abs_path <- get_param_character(params, "mmc_abs_path")

weights_out <- get_param_character(params, "weights_out")
returns_plot_out <- get_param_character(params, "returns_plot_out")

old_step3_outputs <- c(
  "output/step3-top90-portfolio-weights.csv",
  "output/step3-avg-model-weights-by-threshold.csv",
  "output/step3-avg-return-by-threshold.png",
  "output/step3-avg-maxdd-by-threshold.png"
)


## Helpers
#
make_cell_key <- function(offset_value, window_value) {
  paste0(as.integer(offset_value), "__", as.integer(window_value))
}

build_cell_portfolio <- function(
  daily_data,
  offset_value,
  window_value,
  candidate_models,
  min_models_submitting_per_round
) {
  total_rounds <- nrow(daily_data)

  train_start_idx <- as.integer(offset_value) + 1L
  train_end_idx <- as.integer(offset_value) + as.integer(window_value)

  if (is.na(train_start_idx) || is.na(train_end_idx) || train_start_idx < 1 || train_end_idx < train_start_idx || train_end_idx > total_rounds) {
    stop(
      "Invalid train index range for cell offset=", offset_value,
      ", window=", window_value,
      " (start_idx=", train_start_idx, ", end_idx=", train_end_idx, ", total_rounds=", total_rounds, ")."
    )
  }

  train_slice <- daily_data[train_start_idx:train_end_idx, candidate_models, drop = FALSE]

  train_row_submission_counts <- rowSums(!is.na(train_slice[, candidate_models, drop = FALSE]))
  valid_train_rows <- train_row_submission_counts >= min_models_submitting_per_round
  train_slice_filtered <- train_slice[valid_train_rows, , drop = FALSE]

  if (nrow(train_slice_filtered) == 0) {
    stop(
      "No training rows remain after min-model filter for cell offset=", offset_value,
      ", window=", window_value, "."
    )
  }

  complete_train_models <- candidate_models[
    colSums(is.na(train_slice_filtered[, candidate_models, drop = FALSE])) == 0
  ]

  if (length(complete_train_models) == 0) {
    stop(
      "No complete models remain after train-row filtering for cell offset=", offset_value,
      ", window=", window_value, "."
    )
  }

  train_data <- train_slice_filtered[, complete_train_models, drop = FALSE]

  if (nrow(train_data) < 2) {
    stop(
      "Insufficient effective train rows (<2) for cell offset=", offset_value,
      ", window=", window_value, "."
    )
  }

  portfolio <- tryCatch(
    suppressMessages(
      suppressWarnings({
        utils::capture.output(
          portfolio_tmp <- build_portfolio(train_data, threshold = 0),
          type = "output"
        )
        portfolio_tmp
      })
    ),
    error = function(e) {
      stop(
        "build_portfolio failed for cell offset=", offset_value,
        ", window=", window_value,
        ": ", e$message
      )
    }
  )

  if (is.null(portfolio) || nrow(portfolio) == 0) {
    stop(
      "Empty portfolio for cell offset=", offset_value,
      ", window=", window_value, "."
    )
  }

  portfolio_names <- intersect(portfolio$name, colnames(train_data))
  if (length(portfolio_names) == 0) {
    stop(
      "Portfolio model names not found in train data for cell offset=", offset_value,
      ", window=", window_value, "."
    )
  }

  portfolio <- portfolio %>%
    dplyr::filter(name %in% portfolio_names)

  portfolio_weight_sum <- sum(portfolio$weight, na.rm = TRUE)
  if (!is.finite(portfolio_weight_sum) || portfolio_weight_sum <= 0) {
    stop(
      "Invalid portfolio weight sum for cell offset=", offset_value,
      ", window=", window_value, "."
    )
  }

  portfolio <- portfolio %>%
    dplyr::mutate(weight = weight / portfolio_weight_sum) %>%
    dplyr::arrange(dplyr::desc(weight))

  portfolio
}

build_average_portfolio <- function(selected_cells, get_portfolio_fn) {
  selected_keys <- selected_cells$cell_key

  per_cell_rows <- list()
  for (i in seq_len(nrow(selected_cells))) {
    cell_row <- selected_cells[i, , drop = FALSE]
    cell_key <- as.character(cell_row$cell_key[1])

    portfolio <- get_portfolio_fn(
      offset_value = cell_row$round_offset_from_r843[1],
      window_value = cell_row$roundwindow_size[1],
      cell_key = cell_key
    )

    per_cell_rows[[i]] <- portfolio %>%
      dplyr::transmute(
        cell_key = cell_key,
        model = as.character(name),
        weight = as.numeric(weight)
      )
  }

  per_cell_weights <- dplyr::bind_rows(per_cell_rows)

  if (nrow(per_cell_weights) == 0) {
    stop("No per-cell weights available to average.")
  }

  all_models <- sort(unique(per_cell_weights$model))

  complete_weights <- tidyr::expand_grid(
    cell_key = selected_keys,
    model = all_models
  ) %>%
    dplyr::left_join(per_cell_weights, by = c("cell_key", "model")) %>%
    dplyr::mutate(weight = tidyr::replace_na(as.numeric(weight), 0))

  averaged_weights <- complete_weights %>%
    dplyr::group_by(model) %>%
    dplyr::summarise(weight = mean(weight, na.rm = TRUE), .groups = "drop")

  weight_sum <- sum(averaged_weights$weight, na.rm = TRUE)
  if (!is.finite(weight_sum) || weight_sum <= 0) {
    stop("Averaged weights have invalid sum.")
  }

  averaged_weights <- averaged_weights %>%
    dplyr::mutate(weight = weight / weight_sum) %>%
    dplyr::arrange(dplyr::desc(weight))

  averaged_weights
}

compute_forward_oos_series <- function(daily_data, selected_cells, averaged_weights, min_eval_round = NA_integer_) {
  train_end_rounds <- as.integer(selected_cells$train_end_round)
  train_end_rounds <- train_end_rounds[is.finite(train_end_rounds)]

  if (length(train_end_rounds) == 0) {
    stop("No valid train_end_round values in selected cells.")
  }

  # Forward windows in step2 are suffixes to the end of daily_data.
  # Intersection starts after the latest train_end_round.
  oos_intersection_rounds <- daily_data$roundNumber[
    daily_data$roundNumber > as.integer(max(train_end_rounds))
  ]

  if (is.finite(min_eval_round)) {
    oos_intersection_rounds <- oos_intersection_rounds[oos_intersection_rounds >= as.integer(min_eval_round)]
  }

  # Union is the set of rounds that are forward-OOS for at least one selected cell.
  oos_union_rounds <- sort(unique(unlist(
    lapply(train_end_rounds, function(train_end_round_value) {
      daily_data$roundNumber[daily_data$roundNumber > as.integer(train_end_round_value)]
    }),
    use.names = FALSE
  )))

  if (length(oos_intersection_rounds) == 0) {
    stop("No forward-OOS rounds found for selected cells.")
  }

  if (length(oos_union_rounds) < length(oos_intersection_rounds)) {
    stop(
      "Invalid OOS round sets: union count (", length(oos_union_rounds),
      ") is smaller than intersection count (", length(oos_intersection_rounds), ")."
    )
  }

  oos_panel <- daily_data %>%
    dplyr::filter(roundNumber %in% oos_intersection_rounds) %>%
    dplyr::arrange(roundNumber) %>%
    dplyr::select(roundNumber, all_of(averaged_weights$model))

  complete_mask <- stats::complete.cases(oos_panel[, averaged_weights$model, drop = FALSE])
  effective_panel <- oos_panel[complete_mask, c("roundNumber", averaged_weights$model), drop = FALSE]

  if (nrow(effective_panel) == 0) {
    stop("No effective OOS rows remain after complete-case filtering.")
  }

  round_returns <- as.numeric(
    as.matrix(effective_panel[, averaged_weights$model, drop = FALSE]) %*%
      matrix(averaged_weights$weight, ncol = 1)
  )

  n_oos_rounds <- as.integer(nrow(effective_panel))
  oos_return <- as.numeric(mean(round_returns, na.rm = TRUE))
  oos_CVaR <- tryCatch(
    suppressWarnings(as.numeric(PerformanceAnalytics::CVaR(round_returns, method = "historical"))),
    error = function(e) NA_real_
  )
  oos_maxdd <- tryCatch(
    suppressWarnings(as.numeric(PerformanceAnalytics::maxDrawdown(round_returns))),
    error = function(e) NA_real_
  )

  if (!all(is.finite(c(oos_return, oos_CVaR, oos_maxdd)))) {
    stop("Failed to compute finite OOS summary metrics (oos_return/oos_CVaR/oos_maxdd).")
  }

  data.frame(
    roundNumber = as.integer(effective_panel$roundNumber),
    round_return = round_returns,
    cumulative_return = cumsum(round_returns),
    n_oos_rounds = n_oos_rounds,
    oos_return = oos_return,
    oos_CVaR = oos_CVaR,
    oos_maxdd = oos_maxdd,
    stringsAsFactors = FALSE
  )
}

rebase_cumulative_by_entry_points <- function(returns_df) {
  if (nrow(returns_df) == 0) {
    return(returns_df)
  }

  entry_rounds <- returns_df %>%
    dplyr::group_by(portfolio_type) %>%
    dplyr::summarise(entry_round = min(roundNumber), .groups = "drop")

  reset_points <- sort(unique(entry_rounds$entry_round))
  rebased_segments <- list()

  for (i in seq_along(reset_points)) {
    reset_start <- reset_points[i]
    reset_end <- if (i < length(reset_points)) reset_points[i + 1] - 1L else Inf

    active_portfolios <- entry_rounds %>%
      dplyr::filter(entry_round <= reset_start) %>%
      dplyr::pull(portfolio_type)

    segment_rows <- returns_df %>%
      dplyr::filter(
        portfolio_type %in% active_portfolios,
        roundNumber >= reset_start,
        roundNumber <= reset_end
      )

    if (nrow(segment_rows) == 0) {
      next
    }

    baselines <- segment_rows %>%
      dplyr::group_by(portfolio_type) %>%
      dplyr::slice_min(roundNumber, n = 1, with_ties = FALSE) %>%
      dplyr::ungroup() %>%
      dplyr::transmute(portfolio_type, baseline = cumulative_return)

    segment_rows <- segment_rows %>%
      dplyr::left_join(baselines, by = "portfolio_type") %>%
      dplyr::mutate(
        cumulative_return_rebased = cumulative_return - baseline,
        reset_round = as.integer(reset_start)
      ) %>%
      dplyr::select(-baseline)

    rebased_segments[[length(rebased_segments) + 1]] <- segment_rows
  }

  if (length(rebased_segments) == 0) {
    stop("Failed to build rebased cumulative series.")
  }

  dplyr::bind_rows(rebased_segments) %>%
    dplyr::arrange(portfolio_type, roundNumber)
}


## Inputs
#
required_files <- c(step2_grid_path, corr_abs_path, mmc_abs_path)
for (file_path in required_files) {
  if (!file.exists(file_path)) {
    stop("Missing required input file: ", file_path)
  }
}

grid_df <- read.csv(step2_grid_path, stringsAsFactors = FALSE)
required_grid_cols <- c(
  "base_round",
  "round_offset_from_r843",
  "roundwindow_size",
  "train_start_round",
  "train_end_round",
  "oos_start_round",
  "oos_end_round",
  "mean_forward_oos_return",
  "forward_oos_maxdrawdown",
  "status"
)
missing_grid_cols <- setdiff(required_grid_cols, names(grid_df))
if (length(missing_grid_cols) > 0) {
  stop("Step2 grid CSV missing required columns: ", paste(missing_grid_cols, collapse = ", "))
}

valid_cells <- grid_df %>%
  dplyr::mutate(
    round_offset_from_r843 = as.integer(round_offset_from_r843),
    roundwindow_size = as.integer(roundwindow_size),
    train_end_round = as.integer(train_end_round),
    mean_forward_oos_return = as.numeric(mean_forward_oos_return),
    forward_oos_maxdrawdown = as.numeric(forward_oos_maxdrawdown)
  ) %>%
  dplyr::filter(
    status == "ok",
    is.finite(mean_forward_oos_return),
    is.finite(forward_oos_maxdrawdown)
  ) %>%
  dplyr::mutate(cell_key = make_cell_key(round_offset_from_r843, roundwindow_size)) %>%
  dplyr::distinct(cell_key, .keep_all = TRUE)

if (nrow(valid_cells) == 0) {
  stop("No valid cells found in step2 grid CSV.")
}

base_round_values <- sort(unique(as.integer(valid_cells$base_round)))
base_round_values <- base_round_values[is.finite(base_round_values)]
if (length(base_round_values) != 1) {
  stop("Expected exactly one base_round in step2 grid CSV, found: ", paste(base_round_values, collapse = ", "))
}
base_round <- as.integer(base_round_values[1])
if (!identical(as.integer(base_round), as.integer(base_round_param))) {
  stop(
    "base_round mismatch: step2 grid CSV has ", base_round,
    " but Parameters sheet has ", base_round_param,
    ". Re-run step2 with the current Parameters sheet before step3."
  )
}

corr_abs <- read.csv(corr_abs_path)
mmc_abs <- read.csv(mmc_abs_path)
if (!"roundNumber" %in% names(corr_abs) || !"roundNumber" %in% names(mmc_abs)) {
  stop("Step1 abs files must include `roundNumber`.")
}

# Build weighted daily data (same scoring approach as step2).
daily_data <- dplyr::inner_join(
  corr_abs %>% tidyr::pivot_longer(cols = -roundNumber, names_to = "name", values_to = "corr_abs"),
  mmc_abs %>% tidyr::pivot_longer(cols = -roundNumber, names_to = "name", values_to = "mmc_abs"),
  by = c("roundNumber", "name")
) %>%
  dplyr::mutate(score = corr_multiplier * corr_abs + mmc_multiplier * mmc_abs) %>%
  dplyr::select(roundNumber, name, score) %>%
  tidyr::pivot_wider(names_from = name, values_from = score, values_fill = NA_real_) %>%
  dplyr::arrange(roundNumber) %>%
  data.frame()

model_columns <- setdiff(names(daily_data), "roundNumber")
if (length(model_columns) == 0) {
  stop("No model columns available after building weighted daily_data.")
}

enough_rows <- rowSums(!is.na(daily_data[, model_columns, drop = FALSE])) > 0
daily_data <- daily_data[enough_rows, , drop = FALSE]
if (nrow(daily_data) == 0) {
  stop("No rows with model submissions in weighted daily_data.")
}

daily_data <- daily_data %>%
  dplyr::filter(roundNumber >= base_round) %>%
  dplyr::arrange(roundNumber)

if (nrow(daily_data) == 0) {
  stop("No rows remain after applying base_round=", base_round, ".")
}

candidate_models <- setdiff(setdiff(names(daily_data), "roundNumber"), model_names_to_exclude)
if (length(candidate_models) == 0) {
  stop("No candidate models after exclusions.")
}

source("functions-portfolio.R")
options(scipen = 999)


## Build three cell groups
#
return_q90 <- as.numeric(stats::quantile(valid_cells$mean_forward_oos_return, probs = 0.90, na.rm = TRUE))
maxdd_q10 <- as.numeric(stats::quantile(valid_cells$forward_oos_maxdrawdown, probs = 0.10, na.rm = TRUE))

return_cells <- valid_cells %>%
  dplyr::filter(mean_forward_oos_return >= return_q90)

maxdd_cells <- valid_cells %>%
  dplyr::filter(forward_oos_maxdrawdown <= maxdd_q10)

overlap_keys <- intersect(return_cells$cell_key, maxdd_cells$cell_key)
overlap_cells <- valid_cells %>%
  dplyr::filter(cell_key %in% overlap_keys)

if (nrow(return_cells) == 0) {
  stop("Empty selection for return_p90 (no cells at/above return q90).")
}
if (nrow(maxdd_cells) == 0) {
  stop("Empty selection for maxdd_p10 (no cells at/below maxdd q10).")
}

cell_groups <- list(
  return_p90 = return_cells,
  maxdd_p10 = maxdd_cells
)

return_intersection_start <- as.integer(max(as.integer(return_cells$train_end_round)) + 1L)
maxdd_intersection_start <- as.integer(max(as.integer(maxdd_cells$train_end_round)) + 1L)

if (!is.finite(return_intersection_start) || !is.finite(maxdd_intersection_start)) {
  stop("Failed to derive return/maxdd forward-validation starts.")
}

overlap_eval_start <- as.integer(max(return_intersection_start, maxdd_intersection_start))

if (nrow(overlap_cells) > 0) {
  cell_groups$overlap <- overlap_cells
} else {
  message("No overlap between return_p90 and maxdd_p10; skipping overlap portfolio.")
}


## Rebuild cell portfolios and aggregate by group
#
portfolio_cache <- new.env(parent = emptyenv())

get_cell_portfolio <- function(offset_value, window_value, cell_key) {
  if (exists(cell_key, envir = portfolio_cache, inherits = FALSE)) {
    return(get(cell_key, envir = portfolio_cache, inherits = FALSE))
  }

  portfolio <- build_cell_portfolio(
    daily_data = daily_data,
    offset_value = offset_value,
    window_value = window_value,
    candidate_models = candidate_models,
    min_models_submitting_per_round = min_models_submitting_per_round
  )

  assign(cell_key, portfolio, envir = portfolio_cache)
  portfolio
}

weights_rows <- list()
returns_rows <- list()

for (portfolio_type in names(cell_groups)) {
  selected_cells <- cell_groups[[portfolio_type]]
  min_eval_round <- if (portfolio_type == "overlap") overlap_eval_start else NA_integer_

  averaged_weights <- build_average_portfolio(
    selected_cells = selected_cells,
    get_portfolio_fn = get_cell_portfolio
  )

  series_df <- compute_forward_oos_series(
    daily_data = daily_data,
    selected_cells = selected_cells,
    averaged_weights = averaged_weights,
    min_eval_round = min_eval_round
  )

  returns_rows[[portfolio_type]] <- series_df %>%
    dplyr::transmute(
      portfolio_type = portfolio_type,
      roundNumber = as.integer(roundNumber),
      round_return = as.numeric(round_return),
      cumulative_return = as.numeric(cumulative_return)
    )

  weights_rows[[portfolio_type]] <- averaged_weights %>%
    dplyr::transmute(
      portfolio_type = portfolio_type,
      model = as.character(model),
      weight = as.numeric(weight),
      n_selected_cells = as.integer(nrow(selected_cells)),
      return_q90 = as.numeric(return_q90),
      maxdd_q10 = as.numeric(maxdd_q10),
      n_oos_rounds = as.integer(series_df$n_oos_rounds[1]),
      oos_return = as.numeric(series_df$oos_return[1]),
      oos_CVaR = as.numeric(series_df$oos_CVaR[1]),
      oos_maxdd = as.numeric(series_df$oos_maxdd[1])
    )
}

weights_df <- dplyr::bind_rows(weights_rows) %>%
  dplyr::group_by(portfolio_type) %>%
  dplyr::mutate(
    row_in_portfolio = dplyr::row_number(),
    n_selected_cells = dplyr::if_else(row_in_portfolio == 1L, n_selected_cells, as.integer(NA)),
    return_q90 = dplyr::if_else(row_in_portfolio == 1L, return_q90, NA_real_),
    maxdd_q10 = dplyr::if_else(row_in_portfolio == 1L, maxdd_q10, NA_real_),
    n_oos_rounds = dplyr::if_else(row_in_portfolio == 1L, n_oos_rounds, as.integer(NA)),
    oos_return = dplyr::if_else(row_in_portfolio == 1L, oos_return, NA_real_),
    oos_CVaR = dplyr::if_else(row_in_portfolio == 1L, oos_CVaR, NA_real_),
    oos_maxdd = dplyr::if_else(row_in_portfolio == 1L, oos_maxdd, NA_real_)
  ) %>%
  dplyr::ungroup() %>%
  dplyr::select(-row_in_portfolio)
returns_df <- dplyr::bind_rows(returns_rows)
returns_df_rebased <- rebase_cumulative_by_entry_points(returns_df)

if (nrow(weights_df) == 0 || nrow(returns_df) == 0 || nrow(returns_df_rebased) == 0) {
  stop("No outputs generated for step3 top-decile portfolios.")
}

weight_checks <- weights_df %>%
  dplyr::group_by(portfolio_type) %>%
  dplyr::summarise(weight_sum = sum(weight, na.rm = TRUE), .groups = "drop")

bad_weight_groups <- weight_checks %>%
  dplyr::filter(!is.finite(weight_sum) | abs(weight_sum - 1) > 1e-8)

if (nrow(bad_weight_groups) > 0) {
  stop(
    "Averaged weights do not sum to 1 for portfolio_type(s): ",
    paste(bad_weight_groups$portfolio_type, collapse = ", "),
    "."
  )
}


## Write outputs
#
write.csv(weights_df, weights_out, row.names = FALSE)

returns_plot <- ggplot(
  returns_df_rebased,
  aes(
    x = roundNumber,
    y = cumulative_return_rebased,
    color = portfolio_type,
    group = interaction(portfolio_type, reset_round)
  )
) +
  geom_line(linewidth = 1) +
  labs(
    title = "Step3 Forward OOS Cumulative Returns (Rebased at Portfolio Entry Points)",
    x = "roundNumber",
    y = "cumulative return",
    color = "portfolio"
  ) +
  scale_x_continuous(breaks = scales::pretty_breaks())

ggsave(returns_plot_out, plot = returns_plot, width = 12, height = 8, scale = 1)

legacy_outputs <- old_step3_outputs[file.exists(old_step3_outputs)]
if (length(legacy_outputs) > 0) {
  invisible(file.remove(legacy_outputs))
}


## Console summary
#
cat("Step3 complete.\n")
cat("base_round:", base_round, "\n")
cat("Valid grid cells:", nrow(valid_cells), "\n")
cat("return_q90:", return_q90, "\n")
cat("maxdd_q10:", maxdd_q10, "\n\n")
cat("Selected cell counts:\n")
cat(" - return_p90:", nrow(return_cells), "\n")
cat(" - maxdd_p10:", nrow(maxdd_cells), "\n")
cat(" - overlap:", nrow(overlap_cells), "\n\n")
if (nrow(overlap_cells) == 0) {
  cat("Note: overlap was skipped because no overlap cells were found.\n\n")
}
cat("Wrote:\n")
cat(" -", weights_out, "\n")
cat(" -", returns_plot_out, "\n")

# Ensure no default-device PDF artifact is left behind.
if (file.exists("Rplots.pdf")) {
  invisible(file.remove("Rplots.pdf"))
}
