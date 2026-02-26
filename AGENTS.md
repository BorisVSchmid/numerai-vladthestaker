# AGENTS.md

This repository contains an R-based Numerai staking workflow (`vladthestaker`).

## Purpose

Build staking guidance from historical Numerai model performance data.

## Run sequence

1. Update `Optimize-Me.xlsx`:
   - Sheet `Models` (`ModelName`, `Starting Era`, `Notes`)
   - Sheet `Parameters` (`Parameter`, `Value`, `Notes`)
2. Fetch model data:
   - `Rscript step1_get_data.R`
3. Run offset/window grid sweep diagnostics:
   - `Rscript step2_sweep_grid_windows.R`
4. Build top-decile averaged portfolios and forward-OOS cumulative diagnostics:
   - `Rscript step3_build_3xportfolios_oos.R`
5. Current portfolio choice:
   - Use `overlap` weights from `output/step3-3xportfolio-weights.csv`.

## Script responsibilities

- `step1_get_data.R`
  - Downloads model score history and writes 4 daily files:
    - `output/daily_data_corr_abs.csv`
    - `output/daily_data_corr_rel.csv`
    - `output/daily_data_mmc_abs.csv`
    - `output/daily_data_mmc_rel.csv`
  - Skips empty/`NA` model names from `Optimize-Me.xlsx` sheet `Models`.
  - Reads required settings (for example `base_round`) from `Optimize-Me.xlsx` sheet `Parameters`.
- `step2_sweep_grid_windows.R`
  - Builds weighted score data from corr/mmc absolute values.
  - Reads required grid/optimization settings from `Optimize-Me.xlsx` sheet `Parameters`.
  - Writes model performance diagnostics:
    - `output/model-performances-abs-corr-mmc.png`
    - `output/model-performances-rel-corr-mmc.png`
  - Runs a 2D grid sweep over `round_offset_from_base_round` (offset from `base_round`) and `roundwindow_size`.
  - For each grid cell, builds one portfolio and evaluates IS + forward OOS metrics.
  - Writes:
    - `output/step2-grid-window-sweep.csv`
    - `output/step2-grid-window-sweep-oos-heatmap.png` (combined 2-panel plot: mean return left, max drawdown right)
- `step3_build_3xportfolios_oos.R`
  - Consumes `output/step2-grid-window-sweep.csv`.
  - Reads required step3 settings and paths from `Optimize-Me.xlsx` sheet `Parameters`.
  - Builds three averaged portfolios:
    - `return_p90` (top decile by forward OOS return)
    - `maxdd_p10` (lowest decile by forward OOS max drawdown)
    - `overlap` (intersection of the two sets)
  - Computes forward-OOS cumulative returns using intersection forward windows.
  - For `overlap`, evaluation is further restricted to the shared forward window between `return_p90` and `maxdd_p10`.
  - Writes:
    - `output/step3-3xportfolio-weights.csv`
    - `output/step3-forward-oos-cumulative-returns.png`
  - Current selected portfolio for staking is `overlap`.
- `functions-fetch.R`
  - GraphQL/data-fetch helper functions.
- `functions-portfolio.R`
  - Portfolio construction and return/metric helper functions.

## Inputs and key outputs

- Input: `Optimize-Me.xlsx`
- Step1 outputs:
  - `output/daily_data_corr_abs.csv`
  - `output/daily_data_corr_rel.csv`
  - `output/daily_data_mmc_abs.csv`
  - `output/daily_data_mmc_rel.csv`
- Step2 outputs:
  - `output/model-performances-abs-corr-mmc.png`
  - `output/model-performances-rel-corr-mmc.png`
  - `output/step2-grid-window-sweep.csv`
  - `output/step2-grid-window-sweep-oos-heatmap.png`
- Step3 outputs:
  - `output/step3-3xportfolio-weights.csv`
  - `output/step3-forward-oos-cumulative-returns.png`

## Environment

- Intended for R 4.5.2.
- Uses `groundhog` for date-pinned package installs.

## Contributor guidance

- Keep changes focused and minimal.
- Preserve output file contracts unless explicitly asked to change them.
- If you change filtering/optimization behavior, update docs.
