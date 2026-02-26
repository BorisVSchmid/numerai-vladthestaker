# vladthestaker

For changelog, see `CHANGELOG.md`.
For a Python alternative, see [numerai-portfolio-opt](https://github.com/eses-wk/numerai-portfolio-opt).

## Warnings

- This is not financial advice.
- This is an optimization/backtest workflow and can overfit historical behavior.
- Re-run with the latest data before changing live stake.
- The examples below are snapshots from the current `output/` directory and will change after reruns.

## Overview

Vlad helps you decide stake weights in Numerai using historical model score data. Use at your own risk.

Current workflow is a 3-step pipeline:

1. Fetch model performance history.
2. Sweep train/validation grid cells across different start offsets and training-window sizes that are used to build an average between a minvariance and tangency portfolio.
3. Build three averaged portfolios (`return_p90`, `maxdd_p10`, `overlap`) and compare forward OOS behavior.

Current default staking pick is `overlap` from `output/step3-3xportfolio-weights.csv`.

## How to use

1. Edit `Optimize-Me.xlsx`:
   - Sheet `Models`: `ModelName`, `Starting Era`, `Notes`
   - Sheet `Parameters`: `Parameter`, `Value`, `Notes`
2. Run pipeline (recommended):
   - macOS/Linux: `./run_pipeline.sh`
   - Windows: `run_pipeline.bat`
3. Manual run (equivalent):

```bash
Rscript step1_get_data.R
Rscript step2_sweep_grid_windows.R
Rscript step3_build_3xportfolios_oos.R
```

4. Inspect outputs in `output/`:
   - Step1: `daily_data_corr_abs.csv`, `daily_data_corr_rel.csv`, `daily_data_mmc_abs.csv`, `daily_data_mmc_rel.csv`
   - Step2: `step2-grid-window-sweep.csv`, `step2-grid-window-sweep-oos-heatmap.png`, `model-performances-abs-corr-mmc.png`, `model-performances-rel-corr-mmc.png`
   - Step3: `step3-3xportfolio-weights.csv`, `step3-forward-oos-cumulative-returns.png`

## Under the hood

Older Vlad versions relied heavily on resampling. The current version does not. Variation now comes from evaluating many grid cells with different training start offsets and training window sizes, then selecting strong regions from forward-OOS behavior.

Step3 builds three portfolio families:

- `return_p90`: top decile by forward OOS return
- `maxdd_p10`: lowest decile by forward OOS max drawdown
- `overlap`: intersection of return and maxdd selected cells

In practice, use `overlap` when you want a balanced default between return focus and drawdown control.

## How does the output look?

First, inspect model performance diagnostics from Step2:

![model-performances-abs-corr-mmc](output/model-performances-abs-corr-mmc.png)

Use this absolute-performance plot as the primary diagnostic.  
If you want stricter universe control before optimization, use `output/model-performances-rel-corr-mmc.png` to pre-filter models before editing `Optimize-Me.xlsx`.

Snapshot of current Step1 coverage (`output/daily_data_corr_abs.csv`):

```text
rows=355 cols=33 rounds=843-1197
```

Second, inspect the Step2 sweep heatmap:

![step2-grid-window-sweep-oos-heatmap](output/step2-grid-window-sweep-oos-heatmap.png)

Snapshot of current Step2 grid summary (`output/step2-grid-window-sweep.csv`):

```text
total_cells=2304 valid_cells=1128
return_q90=0.0105 maxdd_q10=0.1916
```

Then inspect Step3 portfolio weights and metrics (`output/step3-3xportfolio-weights.csv`).

Current `overlap` summary row:

```text
n_selected_cells=64
n_oos_rounds=60
oos_return=0.006919844
oos_CVaR=-0.02265425
oos_maxdd=0.1286154
```

Current top `overlap` models by weight:

```text
SHATTEREDX           0.23818283
EGG_001              0.17604081
NB_TARGET_ENSEMBLE   0.11080958
JOS_STACK            0.10542928
FEARINDEX            0.09935092
NB_FEAT_NEUTRAL      0.06507597
```

For our example models, we used Numer.ai's benchmark models, and the highest-staked model of the 10 masters and grandmasters of the 2025 season.

## Visualisation of cumulative portfolios

Finally, inspect forward OOS cumulative behavior from Step3:

![step3-forward-oos-cumulative-returns](output/step3-forward-oos-cumulative-returns.png)

Use this figure to compare the stability and trajectory of `return_p90`, `maxdd_p10`, and `overlap` over shared forward-OOS periods.

## Tunable parameters

All tunable settings are read from `Optimize-Me.xlsx` sheet `Parameters`. Scripts fail fast if required keys are missing or invalid.

Step1 keys:

- `base_round`

Step2 keys:

- `base_round`
- `corr_multiplier`
- `mmc_multiplier`
- `min_roundwindow_size`
- `max_roundwindow_size`
- `min_validation_rounds`
- `min_models_submitting_per_round`
- `offset_step`
- `roundwindow_step`
- `model_names_to_exclude`

Step3 keys:

- `base_round`
- `corr_multiplier`
- `mmc_multiplier`
- `model_names_to_exclude`
- `min_models_submitting_per_round`
- `step2_grid_path`
- `corr_abs_path`
- `mmc_abs_path`
- `weights_out`
- `returns_plot_out`

Runtime verbosity controls:

- `VLAD_QUIET_STARTUP` (default `1`)
- `VLAD_VERBOSE` (default `0`)

Environment:

- Intended for R `4.5.2`
- Uses `groundhog` for date-pinned package installs

## Disclaimer

- The information and code in this repository are for educational and operational tooling purposes only.
- No guarantee is provided on accuracy, completeness, or fitness for financial decisions.
- You are responsible for validating outputs before using them for staking decisions.
