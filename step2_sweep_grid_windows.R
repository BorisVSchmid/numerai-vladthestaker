########
# Rscript to run offset/window grid portfolio diagnostics.
#
# Build on R4.5.2
#
# - Uses Groundhog and conflicted for reproducibility.
# - Reads step1 corr/mmc abs/rel files.
# - Writes model-performance diagnostics + grid sweep CSV/heatmap.
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

pkgs <- c("dplyr", "tidyr", "knitr", "readxl", "tibble", "stringr", "memoise", "httr2", "fPortfolio", "ggplot2", "ggrepel", "PerformanceAnalytics", "MASS", "jsonlite", "patchwork")
run_startup_quietly(groundhog.library(pkgs, "2025-06-01"))

# Suppress stray default-device artifacts from non-interactive runs.
if (file.exists("Rplots.pdf")) {
  invisible(file.remove("Rplots.pdf"))
}

source("functions-config.R")


#
# Helper functions
#
prepare_model_performance <- function(corr_data, mmc_data, corr_scale = 1, mmc_scale = 1) {
  corr_long <- corr_data %>%
    tidyr::pivot_longer(cols = -roundNumber, names_to = "name", values_to = "corr") %>%
    dplyr::mutate(corr = corr * corr_scale)

  mmc_long <- mmc_data %>%
    tidyr::pivot_longer(cols = -roundNumber, names_to = "name", values_to = "mmc") %>%
    dplyr::mutate(mmc = mmc * mmc_scale)

  dplyr::inner_join(corr_long, mmc_long, by = c("roundNumber", "name")) %>%
    dplyr::group_by(name) %>%
    dplyr::summarise(
      corr = mean(corr, na.rm = TRUE),
      mmc = mean(mmc, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    dplyr::filter(is.finite(corr), is.finite(mmc))
}

build_placeholder_plot <- function(title_text, label_text) {
  ggplot() +
    annotate("text", x = 1, y = 1, label = label_text, size = 5) +
    xlim(0, 2) +
    ylim(0, 2) +
    theme_void() +
    ggtitle(title_text)
}

build_highlight_tiles <- function(df, metric_col, higher_is_better = TRUE, percentile = 0.90) {
  valid_df <- df %>%
    dplyr::filter(is.finite(.data[[metric_col]]))

  if (nrow(valid_df) == 0) {
    return(list(top_tile = valid_df, p90_tiles = valid_df))
  }

  if (higher_is_better) {
    top_idx <- which.max(valid_df[[metric_col]])
    threshold <- as.numeric(stats::quantile(valid_df[[metric_col]], probs = percentile, na.rm = TRUE))
    p90_tiles <- valid_df %>%
      dplyr::filter(.data[[metric_col]] >= threshold)
  } else {
    top_idx <- which.min(valid_df[[metric_col]])
    threshold <- as.numeric(stats::quantile(valid_df[[metric_col]], probs = 1 - percentile, na.rm = TRUE))
    p90_tiles <- valid_df %>%
      dplyr::filter(.data[[metric_col]] <= threshold)
  }

  top_tile <- valid_df[top_idx, , drop = FALSE]

  list(
    top_tile = top_tile %>% dplyr::distinct(round_offset_from_base_round, roundwindow_size),
    p90_tiles = p90_tiles %>% dplyr::distinct(round_offset_from_base_round, roundwindow_size)
  )
}

compute_color_limits <- function(x, lower_prob = 0.02, upper_prob = 0.98) {
  finite_x <- x[is.finite(x)]
  if (length(finite_x) == 0) {
    return(c(NA_real_, NA_real_))
  }

  limits <- as.numeric(stats::quantile(finite_x, probs = c(lower_prob, upper_prob), na.rm = TRUE))
  if (!all(is.finite(limits))) {
    limits <- range(finite_x, na.rm = TRUE)
  }

  if (limits[1] == limits[2]) {
    delta <- if (limits[1] == 0) 1e-6 else abs(limits[1]) * 1e-6
    limits <- limits + c(-delta, delta)
  }

  limits
}


#
# Read in Vlad Input Data
#
daily_data_corr_abs <- read.csv("output/daily_data_corr_abs.csv")
daily_data_corr_rel <- read.csv("output/daily_data_corr_rel.csv")
daily_data_mmc_abs <- read.csv("output/daily_data_mmc_abs.csv")
daily_data_mmc_rel <- read.csv("output/daily_data_mmc_rel.csv")


#
# Step2 settings
#
params <- read_pipeline_parameters("Optimize-Me.xlsx")

base_round <- get_param_integer(params, "base_round")
corr_multiplier <- get_param_numeric(params, "corr_multiplier")
mmc_multiplier <- get_param_numeric(params, "mmc_multiplier")

min_roundwindow_size <- get_param_integer(params, "min_roundwindow_size")
max_roundwindow_size <- get_param_integer(params, "max_roundwindow_size")
min_validation_rounds <- get_param_integer(params, "min_validation_rounds")
min_models_submitting_per_round <- get_param_integer(params, "min_models_submitting_per_round")

offset_step <- get_param_integer(params, "offset_step")
roundwindow_step <- get_param_integer(params, "roundwindow_step")

model_names_to_exclude <- get_param_character_vector(params, "model_names_to_exclude", allow_empty = TRUE)


#
# Restrict inputs to base_round onward
#
daily_inputs <- list(
  corr_abs = daily_data_corr_abs,
  corr_rel = daily_data_corr_rel,
  mmc_abs = daily_data_mmc_abs,
  mmc_rel = daily_data_mmc_rel
)

for (input_name in names(daily_inputs)) {
  input_df <- daily_inputs[[input_name]]

  if (!"roundNumber" %in% names(input_df)) {
    stop("Missing required column `roundNumber` in input ", input_name, ".")
  }

  input_df <- input_df %>%
    dplyr::filter(roundNumber >= base_round)

  if (nrow(input_df) == 0) {
    stop(
      "No rows left in input ", input_name,
      " after applying base_round=", base_round, "."
    )
  }

  daily_inputs[[input_name]] <- input_df
}

daily_data_corr_abs <- daily_inputs$corr_abs
daily_data_corr_rel <- daily_inputs$corr_rel
daily_data_mmc_abs <- daily_inputs$mmc_abs
daily_data_mmc_rel <- daily_inputs$mmc_rel


#
# Generate model performance plots (absolute + relative)
#
model_performance_abs <- prepare_model_performance(
  corr_data = daily_data_corr_abs,
  mmc_data = daily_data_mmc_abs,
  corr_scale = corr_multiplier,
  mmc_scale = mmc_multiplier
)

model_performance_abs_plot <- ggplot(model_performance_abs, aes(x = corr, y = mmc, label = name)) +
  geom_point(shape = 21, size = 3.5, fill = "steelblue2", color = "black", alpha = 0.9) +
  ggrepel::geom_text_repel(box.padding = 0.5, max.overlaps = 30) +
  labs(
    title = "Model Performance (Absolute)",
    x = paste0("canon_corr * ", corr_multiplier),
    y = paste0("canon_mmc * ", mmc_multiplier)
  )
ggsave("output/model-performances-abs-corr-mmc.png", plot = model_performance_abs_plot, width = 12, height = 10, scale = 1)

model_performance_rel <- prepare_model_performance(
  corr_data = daily_data_corr_rel,
  mmc_data = daily_data_mmc_rel
)

model_performance_rel_plot <- ggplot(model_performance_rel, aes(x = corr, y = mmc, label = name)) +
  geom_point(shape = 21, size = 3.5, fill = "seagreen3", color = "black", alpha = 0.9) +
  ggrepel::geom_text_repel(box.padding = 0.5, max.overlaps = 30) +
  labs(
    title = "Model Performance (Relative Percentile)",
    x = "canon_corr percentile",
    y = "canon_mmc percentile"
  )
ggsave("output/model-performances-rel-corr-mmc.png", plot = model_performance_rel_plot, width = 12, height = 10, scale = 1)


#
# Build weighted daily_data from corr/mmc absolute values
#
daily_data <- dplyr::inner_join(
  daily_data_corr_abs %>%
    tidyr::pivot_longer(cols = -roundNumber, names_to = "name", values_to = "corr_abs"),
  daily_data_mmc_abs %>%
    tidyr::pivot_longer(cols = -roundNumber, names_to = "name", values_to = "mmc_abs"),
  by = c("roundNumber", "name")
) %>%
  dplyr::mutate(score = corr_multiplier * corr_abs + mmc_multiplier * mmc_abs) %>%
  dplyr::select(roundNumber, name, score) %>%
  tidyr::pivot_wider(names_from = name, values_from = score, values_fill = NA_real_) %>%
  dplyr::arrange(roundNumber) %>%
  data.frame()

model_columns <- setdiff(names(daily_data), "roundNumber")
if (length(model_columns) == 0) {
  stop("No model columns available in daily_data.")
}

# Drop rounds with zero model submissions.
enough_rows <- rowSums(!is.na(daily_data[, model_columns, drop = FALSE])) > 0
daily_data <- daily_data[enough_rows, , drop = FALSE]

if (nrow(daily_data) == 0) {
  stop("No rows left after coverage filters. Check step1 outputs and thresholds.")
}

# Ensure base anchor is still honored after row filtering.
daily_data <- daily_data %>%
  dplyr::filter(roundNumber >= base_round) %>%
  dplyr::arrange(roundNumber)

if (nrow(daily_data) == 0) {
  stop("No rows remain at or after base_round=", base_round, ".")
}

# Reuse portfolio helpers.
source("functions-portfolio.R")
options(scipen = 999)


#
# Grid sweep setup
#
total_rounds <- nrow(daily_data)
max_offset <- total_rounds - min_roundwindow_size - min_validation_rounds
if (max_offset < 0) {
  stop(
    "Insufficient rounds for grid sweep: total_rounds=", total_rounds,
    ", need at least ", min_roundwindow_size + min_validation_rounds, "."
  )
}

offsets <- seq(0, max_offset, by = offset_step)

window_upper <- min(max_roundwindow_size, total_rounds - min_validation_rounds)
if (window_upper < min_roundwindow_size) {
  stop(
    "No valid roundwindow_size values. Check min/max_roundwindow_size and min_validation_rounds."
  )
}

window_sizes <- seq(min_roundwindow_size, window_upper, by = roundwindow_step)
if (length(window_sizes) == 0) {
  stop("No window sizes produced by current settings.")
}

total_cells <- length(offsets) * length(window_sizes)
cat(
  "Grid dimensions: offsets=", length(offsets),
  ", window_sizes=", length(window_sizes),
  ", total_cells=", total_cells, "\n",
  sep = ""
)

candidate_models <- setdiff(model_columns, model_names_to_exclude)
if (length(candidate_models) == 0) {
  stop("No candidate models after applying exclusions.")
}


#
# Evaluate each grid cell
#
grid_rows <- list()
cell_index <- 0L
progress_bar <- utils::txtProgressBar(min = 0, max = total_cells, style = 3)

for (offset_value in offsets) {
  for (window_size in window_sizes) {
    cell_index <- cell_index + 1L
    utils::setTxtProgressBar(progress_bar, cell_index)

    train_start_idx <- offset_value + 1L
    train_end_idx <- offset_value + window_size

    train_start_round <- as.integer(daily_data$roundNumber[train_start_idx])

    # Default row skeleton; status + metrics updated below.
    row_out <- data.frame(
      base_round = as.integer(base_round),
      round_offset_from_base_round = as.integer(offset_value),
      roundwindow_size = as.integer(window_size),
      train_start_round = as.integer(train_start_round),
      train_end_round = NA_integer_,
      oos_start_round = NA_integer_,
      oos_end_round = NA_integer_,
      raw_oos_round_count = NA_integer_,
      n_models = NA_integer_,
      validation_sample_size = NA_integer_,
      mean_is_return = NA_real_,
      mean_forward_oos_return = NA_real_,
      is_maxdrawdown = NA_real_,
      forward_oos_maxdrawdown = NA_real_,
      status = "init",
      stringsAsFactors = FALSE
    )

    if (train_end_idx > total_rounds) {
      row_out$status <- "skipped_train_window_out_of_range"
      grid_rows[[cell_index]] <- row_out
      next
    }

    train_end_round <- as.integer(daily_data$roundNumber[train_end_idx])
    raw_oos_round_count <- total_rounds - train_end_idx

    row_out$train_end_round <- train_end_round
    row_out$raw_oos_round_count <- as.integer(raw_oos_round_count)

    if (raw_oos_round_count > 0) {
      row_out$oos_start_round <- as.integer(daily_data$roundNumber[train_end_idx + 1L])
      row_out$oos_end_round <- as.integer(daily_data$roundNumber[total_rounds])
    }

    if (raw_oos_round_count < min_validation_rounds) {
      row_out$status <- "skipped_raw_oos_lt_min_validation_rounds"
      grid_rows[[cell_index]] <- row_out
      next
    }

    train_slice <- daily_data[train_start_idx:train_end_idx, candidate_models, drop = FALSE]

    # Exclude sparse train rounds before selecting complete models.
    train_row_submission_counts <- rowSums(!is.na(train_slice[, candidate_models, drop = FALSE]))
    valid_train_rows <- train_row_submission_counts >= min_models_submitting_per_round
    train_slice_filtered <- train_slice[valid_train_rows, , drop = FALSE]

    if (nrow(train_slice_filtered) == 0) {
      row_out$n_models <- 0L
      row_out$status <- "skipped_no_train_rows_after_min_models_filter"
      grid_rows[[cell_index]] <- row_out
      next
    }

    complete_train_models <- candidate_models[
      colSums(is.na(train_slice_filtered[, candidate_models, drop = FALSE])) == 0
    ]

    if (length(complete_train_models) == 0) {
      row_out$n_models <- 0L
      row_out$status <- "skipped_no_complete_models_after_train_row_filter"
      grid_rows[[cell_index]] <- row_out
      next
    }

    train_data <- train_slice_filtered[, complete_train_models, drop = FALSE]

    if (nrow(train_data) < 2) {
      row_out$n_models <- as.integer(ncol(train_data))
      row_out$status <- "skipped_effective_train_rows_lt_2"
      grid_rows[[cell_index]] <- row_out
      next
    }

    row_out$n_models <- as.integer(ncol(train_data))

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
        message(
          "Cell failed in build_portfolio: offset=", offset_value,
          ", window=", window_size,
          ", error=", e$message
        )
        NULL
      }
    )

    if (is.null(portfolio) || nrow(portfolio) == 0) {
      row_out$status <- "skipped_empty_or_failed_portfolio"
      grid_rows[[cell_index]] <- row_out
      next
    }

    portfolio_names <- intersect(portfolio$name, colnames(train_data))
    if (length(portfolio_names) == 0) {
      row_out$status <- "skipped_portfolio_names_missing"
      grid_rows[[cell_index]] <- row_out
      next
    }

    portfolio <- portfolio %>%
      dplyr::filter(name %in% portfolio_names)

    portfolio_weight_sum <- sum(portfolio$weight, na.rm = TRUE)
    if (!is.finite(portfolio_weight_sum) || portfolio_weight_sum <= 0) {
      row_out$status <- "skipped_invalid_portfolio_weights"
      grid_rows[[cell_index]] <- row_out
      next
    }

    portfolio <- portfolio %>%
      dplyr::mutate(weight = weight / portfolio_weight_sum)

    daily_is <- daily_data[train_start_idx:train_end_idx, c("roundNumber", portfolio$name), drop = FALSE]
    daily_oos <- daily_data[(train_end_idx + 1L):total_rounds, c("roundNumber", portfolio$name), drop = FALSE]

    is_metrics <- suppressWarnings(virtual_returns(daily_is, portfolio, prefix = "IS"))
    oos_metrics <- suppressWarnings(virtual_returns(daily_oos, portfolio, prefix = "OOS"))

    is_n <- as.integer(is_metrics$IS_n[1])
    oos_n <- as.integer(oos_metrics$OOS_n[1])

    row_out$validation_sample_size <- oos_n

    if (is.na(is_n) || is_n < 2) {
      row_out$status <- "skipped_effective_is_n_lt_2"
      grid_rows[[cell_index]] <- row_out
      next
    }

    if (is.na(oos_n) || oos_n < min_validation_rounds) {
      row_out$status <- "skipped_effective_oos_n_lt_min_validation_rounds"
      grid_rows[[cell_index]] <- row_out
      next
    }

    mean_is_return <- as.numeric(is_metrics$IS_mean[1])
    mean_oos_return <- as.numeric(oos_metrics$OOS_mean[1])
    is_maxdd <- as.numeric(is_metrics$IS_MaxDD[1])
    oos_maxdd <- as.numeric(oos_metrics$OOS_MaxDD[1])

    if (!all(is.finite(c(mean_is_return, mean_oos_return, is_maxdd, oos_maxdd)))) {
      row_out$status <- "skipped_non_finite_metrics"
      grid_rows[[cell_index]] <- row_out
      next
    }

    row_out$mean_is_return <- mean_is_return
    row_out$mean_forward_oos_return <- mean_oos_return
    row_out$is_maxdrawdown <- is_maxdd
    row_out$forward_oos_maxdrawdown <- oos_maxdd
    row_out$n_models <- as.integer(nrow(portfolio))
    row_out$status <- "ok"

    grid_rows[[cell_index]] <- row_out
  }
}
close(progress_bar)
cat("\n")

grid_results <- dplyr::bind_rows(grid_rows)

if (nrow(grid_results) == 0) {
  stop("Grid sweep produced no rows.")
}


#
# Write grid CSV + combined heatmap
#
grid_csv_out <- "output/step2-grid-window-sweep.csv"
return_heatmap_out <- "output/step2-grid-window-sweep-oos-heatmap.png"

write.csv(grid_results, grid_csv_out, row.names = FALSE)

heatmap_data <- grid_results %>%
  dplyr::mutate(
    round_offset_from_base_round = as.integer(round_offset_from_base_round),
    roundwindow_size = as.integer(roundwindow_size)
  )
offset_axis_label <- paste0("round offset from base_round (r", base_round, ")")

if (!any(is.finite(heatmap_data$mean_forward_oos_return))) {
  heatmap_plot <- build_placeholder_plot(
    title_text = "Step2 Grid Sweep: Forward OOS Mean Return",
    label_text = "No valid OOS return points"
  )
} else {
  return_highlights <- build_highlight_tiles(
    heatmap_data,
    metric_col = "mean_forward_oos_return",
    higher_is_better = TRUE,
    percentile = 0.90
  )
  return_limits <- compute_color_limits(heatmap_data$mean_forward_oos_return)
  # Anchor 0.0 at yellow for mean return and use the MaxDD palette reversed
  # so higher returns map toward green and lower returns toward red.
  return_limits <- c(min(return_limits[1], 0), max(return_limits[2], 0))
  if (!all(is.finite(return_limits)) || return_limits[1] == return_limits[2]) {
    return_limits <- c(-1e-6, 1e-6)
  }
  return_palette_reversed <- c("#D73027", "#FDAE61", "#FEE08B", "#66BD63", "#1A9850")
  if (return_limits[1] < 0 && return_limits[2] > 0) {
    return_scale <- scale_fill_gradientn(
      colours = return_palette_reversed,
      values = scales::rescale(
        c(return_limits[1], return_limits[1] / 2, 0, return_limits[2] / 2, return_limits[2]),
        from = return_limits
      ),
      limits = return_limits,
      oob = scales::squish,
      na.value = "grey80"
    )
  } else {
    return_scale <- scale_fill_gradient2(
      low = "#D73027",
      mid = "#FEE08B",
      high = "#1A9850",
      midpoint = 0,
      limits = return_limits,
      oob = scales::squish,
      na.value = "grey80"
    )
  }

  heatmap_plot <- ggplot(
    heatmap_data,
    aes(
      x = round_offset_from_base_round,
      y = roundwindow_size,
      fill = mean_forward_oos_return
    )
  ) +
    geom_tile(color = "grey92", linewidth = 0.2) +
    labs(
      title = "Step2 Grid Sweep: Forward OOS Mean Return",
      x = offset_axis_label,
      y = "round window size",
      fill = "mean OOS return"
    ) +
    return_scale +
    geom_tile(
      data = return_highlights$p90_tiles,
      inherit.aes = FALSE,
      aes(x = round_offset_from_base_round, y = roundwindow_size),
      fill = NA,
      color = "black",
      linewidth = 0.4
    ) +
    geom_tile(
      data = return_highlights$top_tile,
      inherit.aes = FALSE,
      aes(x = round_offset_from_base_round, y = roundwindow_size),
      fill = NA,
      color = "black",
      linewidth = 1.2
    ) +
    scale_x_continuous(breaks = scales::pretty_breaks()) +
    scale_y_continuous(breaks = scales::pretty_breaks())
}

if (!any(is.finite(heatmap_data$forward_oos_maxdrawdown))) {
  maxdd_heatmap_plot <- build_placeholder_plot(
    title_text = "Step2 Grid Sweep: Forward OOS Max Drawdown",
    label_text = "No valid OOS MaxDD points"
  )
} else {
  maxdd_highlights <- build_highlight_tiles(
    heatmap_data,
    metric_col = "forward_oos_maxdrawdown",
    higher_is_better = FALSE,
    percentile = 0.90
  )
  maxdd_limits <- compute_color_limits(heatmap_data$forward_oos_maxdrawdown)

  maxdd_heatmap_plot <- ggplot(
    heatmap_data,
    aes(
      x = round_offset_from_base_round,
      y = roundwindow_size,
      fill = forward_oos_maxdrawdown
    )
  ) +
    geom_tile(color = "grey92", linewidth = 0.2) +
    labs(
      title = "Step2 Grid Sweep: Forward OOS Max Drawdown",
      x = offset_axis_label,
      y = "round window size",
      fill = "OOS MaxDD"
    ) +
    scale_fill_gradientn(
      colours = c("#1A9850", "#66BD63", "#FEE08B", "#FDAE61", "#D73027"),
      limits = maxdd_limits,
      oob = scales::squish,
      na.value = "grey80"
    ) +
    geom_tile(
      data = maxdd_highlights$p90_tiles,
      inherit.aes = FALSE,
      aes(x = round_offset_from_base_round, y = roundwindow_size),
      fill = NA,
      color = "black",
      linewidth = 0.4
    ) +
    geom_tile(
      data = maxdd_highlights$top_tile,
      inherit.aes = FALSE,
      aes(x = round_offset_from_base_round, y = roundwindow_size),
      fill = NA,
      color = "black",
      linewidth = 1.2
    ) +
    scale_x_continuous(breaks = scales::pretty_breaks()) +
    scale_y_continuous(breaks = scales::pretty_breaks())
}

combined_heatmap_plot <- heatmap_plot + maxdd_heatmap_plot + patchwork::plot_layout(ncol = 2)
ggsave(return_heatmap_out, plot = combined_heatmap_plot, width = 22, height = 8, scale = 1)


#
# Remove stale legacy step2 artifacts
#
legacy_patterns <- c(
  "output/step2-sweep-start*.csv",
  "output/step2-sweep-start*.png",
  "output/step2-sweep-churn-by-starting-round.png",
  "output/step2-sweep-average-return-by-starting-round.png",
  "output/step2-grid-window-sweep-oos-maxdd-heatmap.png"
)
for (pattern in legacy_patterns) {
  legacy_files <- Sys.glob(pattern)
  if (length(legacy_files) > 0) {
    invisible(file.remove(legacy_files))
  }
}


#
# Console summary
#
cat("Step2 complete.\n")
cat("base_round:", base_round, "\n")
cat("Grid cells evaluated:", nrow(grid_results), "\n")
cat("Valid cells:", sum(grid_results$status == "ok", na.rm = TRUE), "\n\n")
cat("Wrote:\n")
cat(" - ", grid_csv_out, "\n", sep = "")
cat(" - ", return_heatmap_out, "\n", sep = "")
cat(" - output/model-performances-abs-corr-mmc.png\n")
cat(" - output/model-performances-rel-corr-mmc.png\n")

# Ensure no default-device PDF artifact is left behind.
if (file.exists("Rplots.pdf")) {
  invisible(file.remove("Rplots.pdf"))
}
