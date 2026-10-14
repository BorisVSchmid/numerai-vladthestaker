########
# Rscript to generate model performance diagnostics from step1 outputs.
#
# Build on R4.5.2
#
# - Uses Groundhog and conflicted for reproducibility.
# - Reads the exact finalized D60 combined-score panel written by Step1.
# - Writes one calendar-time cumulative-score/drawdown diagnostic.
#
########

# -------------------- Reproducible libraries --------------------
if (!requireNamespace("groundhog", quietly = TRUE)) install.packages("groundhog")
if (!requireNamespace("conflicted", quietly = TRUE)) install.packages("conflicted")
library(groundhog)
library(conflicted)

pkgs <- c("dplyr", "tidyr", "readxl", "ggplot2", "scales")
groundhog.library(pkgs, "2025-06-01")

conflicts_prefer(dplyr::filter)
source(file.path("R", "functions-config.R"))
source(file.path("R", "functions-score-storage.R"))
source(file.path("R", "functions-hyperparam-runtime.R"))
source(file.path("R", "functions-inputs.R"))

args <- commandArgs(trailingOnly = TRUE)
get_flag <- function(name, default = NULL) {
  prefix <- paste0("--", name, "=")
  hit <- args[startsWith(args, prefix)]
  if (!length(hit)) {
    return(default)
  }
  sub(prefix, "", hit[[length(hit)]], fixed = TRUE)
}
output_dir <- get_flag("output-dir", "output")

step2_drawdown_plot_out <- file.path(output_dir, "step2_model-return-drawdown-calendar.png")


#
# Helper functions
#
build_model_score_diagnostics <- function(score_data, model_order, full_rounds) {
  observed_paths <- score_data %>%
    pivot_longer(cols = -roundNumber, names_to = "name", values_to = "score") %>%
    filter(name %in% model_order, is.finite(score)) %>%
    arrange(match(name, model_order), roundNumber)

  if (nrow(observed_paths) == 0) {
    stop("No finite weighted model scores available for drawdown diagnostics.")
  }

  observed_paths <- observed_paths %>%
    group_by(name) %>%
    mutate(
      observed_rounds = n(),
      cumulative_score = cumsum(score),
      running_peak = cummax(c(0, cumulative_score))[-1L],
      score_drawdown = cumulative_score - running_peak
    ) %>%
    ungroup()

  observed_summary <- observed_paths %>%
    group_by(name) %>%
    summarise(
      observed_rounds = as.integer(first(observed_rounds)),
      maximum_drawdown = as.numeric(-min(score_drawdown, na.rm = TRUE)),
      pain_index = as.numeric(mean(-score_drawdown, na.rm = TRUE)),
      .groups = "drop"
    )

  drawdown_summary <- data.frame(
    name = model_order,
    model_order_index = seq_along(model_order),
    stringsAsFactors = FALSE
  ) %>%
    left_join(observed_summary, by = "name") %>%
    mutate(
      observed_rounds = replace_na(observed_rounds, 0L),
      drawdown_facet_label = if_else(
        observed_rounds > 0L,
        sprintf(
          "%s\nn=%d | maxDD=%.3f | pain=%.3f",
          name,
          observed_rounds,
          maximum_drawdown,
          pain_index
        ),
        sprintf("%s\nno paired Ender60 data", name)
      )
    ) %>%
    arrange(desc(observed_rounds), model_order_index)
  model_order <- drawdown_summary$name

  calendar_df <- tidyr::crossing(
    name = model_order,
    roundNumber = as.integer(full_rounds)
  ) %>%
    left_join(
      observed_paths %>%
        select(name, roundNumber, score, cumulative_score, score_drawdown),
      by = c("name", "roundNumber")
    ) %>%
    left_join(
      drawdown_summary %>% select(name, drawdown_facet_label),
      by = "name"
    ) %>%
    mutate(
      name = factor(name, levels = model_order),
      drawdown_facet_label = factor(
        drawdown_facet_label,
        levels = drawdown_summary$drawdown_facet_label
      )
    ) %>%
    group_by(name) %>%
    mutate(path_segment = cumsum(!is.finite(score))) %>%
    ungroup() %>%
    arrange(name, roundNumber)

  missing_blocks <- calendar_df %>%
    filter(!is.finite(score)) %>%
    group_by(name) %>%
    mutate(block_id = cumsum(c(1L, as.integer(diff(roundNumber) > 1L)))) %>%
    group_by(name, block_id) %>%
    summarise(
      xmin = min(roundNumber) - 0.5,
      xmax = max(roundNumber) + 0.5,
      .groups = "drop"
    ) %>%
    left_join(
      drawdown_summary %>% select(name, drawdown_facet_label),
      by = "name"
    ) %>%
    mutate(
      name = factor(name, levels = model_order),
      drawdown_facet_label = factor(
        drawdown_facet_label,
        levels = drawdown_summary$drawdown_facet_label
      )
    )

  no_data <- drawdown_summary %>%
    filter(observed_rounds == 0L) %>%
    mutate(
      roundNumber = mean(range(full_rounds)),
      drawdown_facet_label = factor(
        drawdown_facet_label,
        levels = drawdown_summary$drawdown_facet_label
      )
    )

  list(
    calendar = calendar_df,
    missing_blocks = missing_blocks,
    no_data = no_data
  )
}

calendar_plot_theme <- function() {
  theme_bw(base_size = 9) +
    theme(
      panel.grid.minor = element_blank(),
      panel.spacing = grid::unit(0.65, "lines"),
      strip.text = element_text(size = 7, lineheight = 0.9),
      axis.text = element_text(size = 7),
      plot.subtitle = element_text(size = 9, color = "grey35")
    )
}

build_score_drawdown_calendar_plot <- function(calendar_df, missing_blocks, no_data,
                                               full_rounds, corr_scale, mmc_scale,
                                               ncol = 8L) {
  finite_paths <- calendar_df %>%
    filter(is.finite(cumulative_score), is.finite(score_drawdown))

  score_limits <- range(
    c(0, finite_paths$cumulative_score, finite_paths$score_drawdown),
    finite = TRUE
  )
  score_padding <- max(0.01, diff(score_limits) * 0.03)
  score_limits <- score_limits + c(-score_padding, score_padding)
  score_span <- diff(score_limits)
  no_data_label_y <- 0.12 * score_span
  score_limits[[2L]] <- max(
    score_limits[[2L]],
    no_data_label_y + 0.04 * score_span
  )
  calendar_x_limits <- range(full_rounds) + c(-0.5, 0.5)
  calendar_breaks <- pretty(full_rounds, n = 4)
  calendar_breaks <- calendar_breaks[
    calendar_breaks >= min(full_rounds) & calendar_breaks <= max(full_rounds)
  ]
  calendar_breaks <- sort(unique(c(calendar_breaks, max(full_rounds))))

  ggplot(calendar_df, aes(x = roundNumber, group = name)) +
    geom_rect(
      data = missing_blocks,
      inherit.aes = FALSE,
      aes(xmin = xmin, xmax = xmax),
      ymin = score_limits[[1]],
      ymax = score_limits[[2]],
      fill = "grey91",
      alpha = 0.5
    ) +
    geom_hline(yintercept = 0, color = "grey35", linewidth = 0.35) +
    geom_ribbon(
      data = finite_paths,
      inherit.aes = FALSE,
      aes(
        x = roundNumber,
        ymin = score_drawdown,
        ymax = 0,
        group = interaction(name, path_segment),
        fill = "Drawdown"
      ),
      alpha = 0.42,
      na.rm = TRUE
    ) +
    geom_line(
      data = finite_paths,
      inherit.aes = FALSE,
      aes(
        x = roundNumber,
        y = cumulative_score,
        group = interaction(name, path_segment),
        color = "Cumulative combined score"
      ),
      linewidth = 0.5,
      na.rm = TRUE
    ) +
    geom_text(
      data = no_data,
      inherit.aes = FALSE,
      aes(
        x = roundNumber,
        y = no_data_label_y,
        label = "no paired\nEnder60 data"
      ),
      color = "grey40",
      size = 2.4,
      lineheight = 0.9
    ) +
    facet_wrap(~drawdown_facet_label, ncol = ncol, scales = "fixed", drop = FALSE) +
    scale_x_continuous(limits = calendar_x_limits, breaks = calendar_breaks) +
    scale_y_continuous(
      limits = score_limits,
      breaks = scales::breaks_pretty(n = 6),
      labels = scales::label_number(accuracy = 0.1),
      expand = expansion(mult = 0)
    ) +
    scale_color_manual(
      name = NULL,
      values = c("Cumulative combined score" = "#1F4E79")
    ) +
    scale_fill_manual(
      name = NULL,
      values = c("Drawdown" = "#D55E00")
    ) +
    guides(
      color = guide_legend(order = 1, override.aes = list(linewidth = 0.8)),
      fill = guide_legend(order = 2, override.aes = list(alpha = 0.42))
    ) +
    labs(
      title = "Model Cumulative Combined Score and Drawdown (Calendar Time)",
      subtitle = sprintf(
        paste0(
          "The line is the cumulative sum of %g x CORR60 + %g x MMC60; drawdown is shown below zero. Facets are sorted by observed rounds (n).\n",
          "Facet pain uses each model's own available history and is not a same-period cross-model comparison. The calendar ends at the latest observed D60 round (%d); grey indicates missing paired Ender60 scores within that mature calendar."
        ),
        corr_scale,
        mmc_scale,
        max(full_rounds)
      ),
      x = "Numerai round",
      y = "cumulative combined score / score drawdown"
    ) +
    calendar_plot_theme() +
    theme(
      legend.position = "top",
      legend.direction = "horizontal",
      legend.box = "horizontal"
    )
}

#
# Read in Vlad input data
#
params <- read_pipeline_parameters("parameters.csv")
workbook_models <- as.data.frame(readxl::read_excel("Optimize-Me.xlsx", sheet = "Models"))
inputs <- check_pipeline_inputs(2L, params, output_dir, workbook_models)
d60_scores <- inputs$d60


#
# Step2 settings
#
base_round <- inputs$base_round
corr_multiplier <- inputs$score_config$corr_multiplier
mmc_multiplier <- inputs$score_config$mmc_multiplier


#
# Restrict the finalized outcome panel to base_round onward
#

available_drawdown_models <- setdiff(names(d60_scores), "roundNumber")
d60_matrix <- as.matrix(d60_scores[available_drawdown_models])
storage.mode(d60_matrix) <- "double"
observed_d60_round <- rowSums(is.finite(d60_matrix)) > 0L
last_observed_d60_round <- max(d60_scores$roundNumber[observed_d60_round])
d60_scores <- d60_scores %>% filter(roundNumber <= last_observed_d60_round)
panel_rounds <- as.integer(d60_scores$roundNumber)
full_rounds <- seq.int(min(panel_rounds), max(panel_rounds))
workbook_order <- inputs$model_df$name
model_order <- c(workbook_order[workbook_order %in% available_drawdown_models],
  setdiff(available_drawdown_models, workbook_order))


#
# Generate the cumulative-score/drawdown plot (calendar time)
#
score_outputs <- build_model_score_diagnostics(
  score_data = d60_scores,
  model_order = model_order,
  full_rounds = full_rounds
)

calendar_data <- score_outputs$calendar
missing_blocks <- score_outputs$missing_blocks
no_data <- score_outputs$no_data

ncol_facets <- min(8L, length(model_order))
nrow_facets <- ceiling(length(model_order) / ncol_facets)
calendar_sheet_height <- max(8, 2.1 * nrow_facets)

calendar_score_drawdown_plot <- build_score_drawdown_calendar_plot(
  calendar_df = calendar_data,
  missing_blocks = missing_blocks,
  no_data = no_data,
  full_rounds = full_rounds,
  corr_scale = corr_multiplier,
  mmc_scale = mmc_multiplier,
  ncol = ncol_facets
)
ggsave(
  step2_drawdown_plot_out,
  plot = calendar_score_drawdown_plot,
  width = 18,
  height = calendar_sheet_height,
  units = "in",
  dpi = 300
)

#
# Console summary
#
message("Step2 complete: D60 rounds ", base_round, " through ", last_observed_d60_round,
  ". Figure: ", step2_drawdown_plot_out)
