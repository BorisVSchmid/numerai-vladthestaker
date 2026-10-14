# numerai-vladthestaker

Follow the [workspace coding guidance](../../AGENTS.md).
See [README.md](README.md) for commands, outputs, and diagnostic interpretation.

## Code ownership

- Single-step helpers live in their numbered script; `R/` contains only helpers
  shared by numbered steps. Tests load definitions with
  `tests/load-step-functions.R` without running workflows.
- Numbered steps share startup input checks in `R/functions-inputs.R`. Test
  those checks once in `tests/test-pipeline-inputs.R`; step tests cover their
  scientific behavior and publication failures.
- Step 3 contains its preparation, Stan fit, diagnostics, and plots. Step 4
  contains only live portfolio generation, validation, and publication.
- `step_standalone.R` contains the complete download-to-portfolio path, with no
  sourced application helpers, replay, plots, or Stan. Keep its independent
  implementation in agreement with the score rule, timing, and portfolio
  permissions. No step invokes another.
- Shared settings come from `parameters.csv`; the workbook supplies the Models
  roster and `Include?` permissions. This pipeline applies the fixed rule rather
  than rerunning the separate hyperparameter research described in the README.

## Scientific contract

- Fixed rule: EW(pos) D60+|W9. Target `t` averages nine exact finite cells,
  D60(t-64) through D60(t-72); no partial window or source-round fallback.
- Each cell is `3 * canon_corr60 + 15 * canon_mmc60`, version 0, paired by
  model, submission, round, maturity, and timestamp.
- Select strictly positive means and equal-weight the roster. One selected model
  is sufficient; no selected models means no submission and zero replay score.
- Steps 3–4 and standalone apply the Models sheet's `Include?` Yes/No permission
  to account portfolios and current weights. Step 3 retains annotated individual
  diagnostics for No models, with zero account-posterior contribution.
- Evaluate D60(t) without changing the selected roster. Internal missing outcomes
  contribute zero at original weights. Exclude inactive edges and unavailable
  initial/final signal windows. Scores are arithmetic averages, not rescored
  blended predictions or compounded returns.
- Step 3 uses the same active rounds and zero policy for EW(pos) versus EW(all).
  EW(all) includes zero signals. Never use replay zeros as observed Stan evidence.
- Fit the binary inclusion signal; show positive-accuracy posteriors conditional
  on inclusion, with the overall D60-positive rate as context. Keep models without
  included paired rounds visible, with positive accuracy unavailable rather than
  displaying prior/pooling-only positive-state estimates as evidence.
  No 25-per-sign or 95%-certainty gate; label fewer than 25 shared account rounds
  as limited history. The diagnostic never changes live weights automatically.
- Treat Step 3 summaries as historical evidence conditional on the rule and fit.
  They do not account for hyperparameter selection or establish independent
  future performance. Manual model exclusions based on them add selection.

## Data and publication

- Preserve the workbook, parameters, raw events, and intermediate downloads.
  Step 1 freezes the download round, merges events idempotently, extends lookback
  after outages, and publishes complete D38–D57 and D60 panels in `output/scores/`.
- Step 3 writes the inclusion figure and supporting files in `output/stan/`
  (unpooled under `unpooled/`), copying it to `output/step3_inclusion-posteriors.png`.
  Do not generate a Markdown report or reuse posteriors from another rule.
- Step 4 writes `output/portfolio/portfolio_<roundnr>.csv`; standalone writes
  `output_standalone/portfolio_<roundnr>.csv`. Both publish header-only CSVs when
  empty. Standalone's optional Step 1 archive is read-only; finite fresh API
  cells override the exact archived cells.
- Once the API target is known, invalidate only that round's prior portfolio,
  retaining its `.last-successful` backup. Preserve other rounds without using
  them as fallbacks. Re-fetch the current round immediately before publication;
  failure or a changed round must not publish a replacement.
- These scripts generate weights. Metamodel construction, prediction submission,
  and stake management remain separate.

## Checks

Run `Rscript.exe --vanilla tests/run-tests.R` for code changes. The separate
compiled-Stan likelihood and saved-Step-4 artifact checks are documented in the
README. Preserve the configured sampler limits; do not auto-scale parallelism.
