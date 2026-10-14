# Vlad the Staker

Builds equal-weight portfolios based including only models with recently
positive performance. Step 3 assesses whether this rule suits the account and
its models; it does not change allocation.

This is quite a large departure from earlier Vlad the Stakers that tried to
find non-changing tangency or minvariance portfolios. In retrospect, these
portfolios deteriorated in performance over time. It seems the market is enough
in flux that a single blend of models doesn't hold up indefinetly. There are
also legitimate questions on whether the amount of noise in the tournament is a good
match for establishing any kind of reliable covariance matrix between models. 

In this version, we used a hyperparameter sweep on the best ensemble portfolios
for 14 public accounts, and settled on **EW(pos) D60+|W9**, shorthand for
*"make an equal-weight portfolio based on the available models in
Optimize-Me.xlsx that score on average above 0 in the last nine finalized
rounds"*. The hyperparameter sweep included, online-EW, tangency, minvariance,
EW, and EW(pos) for various time windows and for finalized and unfinalized
rounds, and **EW(pos) D60+|W9** came out as a good strategy for most, but not
all of the accounts. To know if your account benefits from this strategy, run
step3, which does a per-model statistical analysis on the predictive value of
D60+|W9 for the sign of the model at the next rounds' realization.

Strategy selection used historical walk-forward backtests with score-availability
timing enforced. The reported research contains no independent validation of the
final rule on an untouched future period, so it can overfit historical behavior.
This is not financial advice.

## Run

Run from this directory with R 4.5.2 and the Groundhog package setup. The scripts
use the pinned package date `2025-06-01`; Step 3 also needs CmdStanR and CmdStan.

```powershell
Rscript.exe --vanilla step1_get_data.R
Rscript.exe --vanilla step2_generate_model_performance_figures.R
Rscript.exe --vanilla step3_analyze_default_rule.R output pooled
Rscript.exe --vanilla step4_generate_portfolio_replay_and_weights.R
```

Each step runs independently. Edit the Models sheet in `Optimize-Me.xlsx` and
the settings in `parameters.csv`, then run Steps 1–3 to review model histories
and account suitability. If you change model permissions, rerun Step 3 to see
the revised account comparison and Step 4 to generate current weights. Step 3
fits a statistical model and can take an hour or more, depending on the data
and machine. It does not automatically exclude models or retune the rule.

For routine portfolio refreshes, use `step_standalone.R`, described below.

The `Optimize-Me.xlsx` Models sheet uses its first column for model names and
its second for positive integer starting rounds. Blank-name rows are ignored;
invalid starting rounds and duplicate names fail the run before exclusions.
Starting rounds apply to cached and fresh scores alike. Updating a start requires
rerunning Step 1 before the numbered analysis steps; raw histories are preserved.

Steps 3–4 and standalone also read the `Include?` column: each named model must
have `Yes` or `No` (case-insensitive). `No` models cannot enter the current
portfolio or either historical account portfolio, EW(pos) and EW(all). Step 3
keeps their individual diagnostics and labels them `[excluded]`; supporting model CSVs record
`portfolio_included`. Their model-panel counts still describe positive historical
signals, not permission to allocate. They remain in the joint diagnostic fit,
but have zero account-posterior contribution. Changing `Include?` takes effect
on the next Step 3, Step 4, or standalone run without rerunning Step 1. All `No`
produces header-only Step 4 and standalone portfolios and no Step 3 account
comparison.

Each numbered step calls `check_pipeline_inputs()` from `R/functions-inputs.R`
before processing data. The shared check covers parameters, the workbook roster
for every step, and the D60 score file for Steps 2–4. Scores need numeric columns
and a valid round calendar. Missing score cells remain
valid; eligibility still requires nine finite cells for the selected model.


| Step | Purpose | Main outputs |
|---|---|---|
| 1 | Read the Models sheet in `Optimize-Me.xlsx` and `parameters.csv`; refresh canonical score histories | `data/model_history/` and aligned D38–D57/D60 panels in `output/scores/` |
| 2 | Plot additive D60 score paths and drawdowns | `output/step2_model-return-drawdown-calendar.png` |
| 3 | Fit account/model suitability diagnostics | `output/step3_inclusion-posteriors.png`; supporting files in `output/stan/` |
| 4 | Generate and publish current-round weights | `output/portfolio/portfolio_<roundnr>.csv` |

Step 1 shows model lookup/download progress and publication phases. It merges
observations idempotently, extends refresh lookback after an outage, and replaces
the complete archive only after success. Keep the workbook, parameters, and raw
histories. Intermediate maturity downloads remain enabled even though this rule
uses only D60.

Publication errors and user interrupts restore the previous file set. If recovery
fails, the run stops and reports retained backup paths. A leftover
`data/.download-lock` may be removed only after confirming no download is running.

Step 3 requires CmdStanR and a configured CmdStan C++ toolchain. Its settings
currently specify four chains and four parallel chains; change the explicit
`stan_parallel_chains` setting to reduce concurrency. Reporting requires passing
sampler diagnostics. Use `output unpooled` for the sensitivity fit: its files
go to `output/stan/unpooled/`. The top-level inclusion figure shows the last
successful fit and labels its mode. Step 3 generates no Markdown report.

## Exact rule and replay

For the API current round `t`, each model's signal is:

```text
mean(D60(t-64), D60(t-65), ..., D60(t-72))
D60 cell = 3 * canon_corr60 + 15 * canon_mmc60   (metric version 0)
```

Pair metrics by model, submission, round, maturity, and score timestamp.
All nine exact cells must be finite. The four-round lag after score maturity
matches the research's availability rule: `t-64` is the newest eligible D60
source round. There is no current+1 shift or earlier-row fallback.

Select strictly positive signals and allocate `1 / selected_models` to each.
**One positive model is enough. Zero positives means no submission and a zero
replay score.** Zero means and incomplete windows are excluded.
In the CSV, `signal_round = t-64`, `historical_window = 9`, and
`signal_combined_score` is the nine-cell mean.

Step 3's historical assessment scores that round's selected roster on D60(t).
Inside the active period, missing selected outcomes contribute zero at their
original weights. Exclude leading/trailing inactivity and unavailable initial/final signal windows;
internal gaps remain zero-return rounds. Scores average individual model scores,
not blended predictions. Paths and drawdowns are additive, not compounded stake
returns; weights do not prescribe bankroll size.

## How the portfolio rule was chosen

The tuning research was carried out separately from this pipeline. These scripts
apply the fixed D60+|W9 rule; they do not rerun the hyperparameter search.

The research narrowed the choice in three stages:

1. **Portfolio families and window lengths.** Earlier comparisons examined
   positive-filtered equal weight, unfiltered equal weight, Online EW, tangency,
   and minimum variance. Further comparisons focused on shorter windows and
   favored simple EW(pos). That earlier study selected D60/W1 under its own
   scoring and evaluation rules; it was exploratory evidence, rather than a
   direct performance estimate for the current rule.
2. **Score maturity and history window.** A later search used a frozen cohort
   of **14 accounts and 691 models**, at download snapshot round **1364**.
   It evaluated maturities D5–D60 and windows W1–W20: **1,120 settings per
   filter**, for EW(pos), EW(all), and EW(neg). A D+/W setting varies the newest
   score maturity and the number of historical cells averaged; older cells use
   progressively more mature scores, capped at D60. Within-account comparisons
   required at least 25 shared rounds. Accounts received equal weight, and
   settings were ranked by average regret: the gap from each account's best
   within-filter win fraction. Under the final policy allowing empty portfolios
   and zero-filled internal missing outcomes, this search selected **EW(pos)
   D57/W1**.
3. **Matched-round trade-offs.** A separate Pareto study compared **1,126
   EW(pos) settings**: the original grid plus six longer D60 windows. Every
   setting used identical target rounds within each account, totaling **4,001
   account-rounds**, with 223–309 rounds per account. The objectives were higher
   equal-account mean D60 and a smaller combined shortfall, measured by the sum
   of negative account mean scores. **D60/W9 lay on this frontier** and was
   adopted as the current compromise. It was not the regret-search winner or
   the setting with the highest mean score.

The frozen matched comparison with the regret-search winner was:

| Historical metric | EW(pos) D60/W9 | EW(pos) D57/W1 |
|---|---:|---:|
| Equal-account mean D60 | 0.023304 | 0.021966 |
| Sum of negative account mean D60 values | -0.126720 | -0.137954 |

Higher is better for both metrics. D60/W9 improved the average by **0.001338
score units**, while improving 6 accounts and worsening 8. Larger gains in a
minority of accounts produced the aggregate improvement. These are historical
model-score averages, not percentage investment returns or scores from freshly
blended predictions. The numbers describe snapshot 1364, not this workbook's
current models or the latest run.

### What the forward testing establishes

Within each historical replay, the signal uses earlier scores under the
availability rule, then evaluates the selected portfolio on the subsequently
observed target-round D60 outcome. For D60/W9, the signal uses `t-64` through
`t-72`; the outcome is D60(t). This is historical walk-forward evaluation with
forward-separated signals and outcomes.

The family, maturity, window, and evaluation policies were nevertheless chosen
after inspecting those historical results. The reported research did not reserve
an outer chronological holdout for the final D60/W9 choice. Matching rounds
improves comparison fairness; multiple accounts and historical subsampling add
robustness evidence. They do not supply an independent test of the selected rule.
The cohort originated from later account/model availability, which also leaves
cohort-selection and survivorship concerns.

Step 3's posterior intervals summarize historical evidence conditional on the
rule and fitted model. They do not account for the preceding strategy search or
establish future performance. Changing `Include?` after reviewing these results
adds another historical selection decision. Independent forward validation
requires freezing the rule and model-permission policy before collecting and
evaluating newly arriving rounds, or repeating the full selection process inside
an outer chronological test.

## Read the Step 3 figure

<img width="2600" height="2702" alt="step3_inclusion-posteriors" src="https://github.com/user-attachments/assets/66eb93ff-2ed6-4164-a247-29af8f70923d" />

**Inclusion posteriors:** the top panel shows the posterior expected historical
mean D60 score of EW(pos), with its middle-90% interval. The next panel shows
EW(pos) minus EW(all), with the axis capped at −0.05 to +0.05. Positive values
favor filtering. Below these, positive accuracy means the fraction of included
paired rounds whose eventual D60 score is strictly positive. Curves show the
Stan posterior for `P(D60 > 0 | included)`. Black triangles show each model's
overall D60-positive rate across all paired rounds, rather than accuracy on
excluded rounds. Every roster model appears. Zero included pairs means no
observed positive accuracy and no displayed posterior estimate; fewer than three
varying paired outcomes can still have observed accuracy but no fitted curve.
There is no 95% certainty cutoff. Legends identify only dots, curves, and triangles.
After the Pairs column, `rounds included?` shows positive-signal rounds divided
by all paired rounds and their percentage, such as `12/50 (24%)`.
`0/0 (--)` means no valid pairs.

Supporting account-score CSVs retain expected historical mean scores for
EW(pos), EW(all), and their paired difference, with middle-90% intervals.
Their `observed` values cover all common replay rounds; `observed_supported`
values cover only the `posterior_rounds` used to estimate those expected means.
The account summary also retains both sets of observed means.
These are historical expected means, not next-round forecasts. Step 3 no longer
generates the separate account-score PNG; existing image files are preserved.

Both historical portfolios use the same active rounds and zero policy.
EW(all) includes every complete signal, including zero/negative signals;
identical-roster rounds stay in the comparison. A round is omitted from the
account posterior when it needs an estimate for an unestimated model with an
observed contributing outcome. Both account panels show posterior-supported and
common round counts; their observed markers use the same supported rounds as
the posterior. Fewer than 25 common rounds is labeled limited history; fewer
than 25 supported rounds with longer common history is labeled limited posterior
support. Zero supported rounds means no account posterior or observed marker.

The Stan predictor is the binary inclusion decision; the outcome is D60(t).
The model pools inclusion effects and accounts for correlations between models
and across rounds. Entry requires at least three paired, varying outcomes,
not 25 observations per sign. Models observed only while included can have
positive accuracy estimated. Models never included retain their place in the
joint outcome fit, but their positive-state extrapolation is not reported as
positive-accuracy evidence. Replay zeros never become observed evidence. High
positive accuracy can reflect mostly positive outcomes, which is why the overall
positive rate and account score comparison are also shown. Accuracy counts signs;
the account comparison also accounts for score magnitudes.

The existing `model-sign-accuracy.csv` and `sign-accuracy-draws.rds` filenames now
contain conditional positive-accuracy summaries and draws. The model's correlated
outcome likelihood, priors, sampler settings, and live allocation rule are unchanged.

## Portfolio generation and publication

Step 4 reads the Step 1 D60 score panel and generates only the current-round
portfolio CSV. It has no replay, figures, or plotting dependencies. Existing
figures are preserved. The script name and optional `[OUTPUT_DIR]` argument
remain the same; that directory supplies the score panels and receives the CSV.

For the download-to-portfolio path without replay or Stan:

```powershell
Rscript.exe --vanilla step_standalone.R
```

This self-contained script reads the same workbook/parameters and downloads
only `Include? = Yes` models, also applying the parameter exclusions.
Downloads run sequentially with model progress; all `No` skips score downloads.
It writes directly to
`output_standalone/portfolio_<roundnr>.csv`; an optional `[OUTPUT_DIR]`
changes that destination. The optional, read-only
`output/scores/d60_combined_scores.csv` fills exact cells absent from the API;
fresh finite API cells take precedence. Continue Step 1 to preserve full history.

Step 4 and standalone retain earlier round files. After identifying the current
round, a rerun invalidates only that round's existing portfolio and preserves
its previous success as `.last-successful`. A refresh failure or round change
publishes no replacement. Failure to fetch the initial round leaves files intact.

Before publication, re-fetch the API round and validate the filename,
`intended_round`, unique models, and positive weights summing to one.
On a successful empty decision, **Step 4 and standalone write header-only
portfolio CSVs.** Neither uses an earlier portfolio as fallback.

These scripts generate portfolio weights. Metamodel construction, prediction
submission, and stake management are separate; the scripts do not submit
predictions, transfer stake, or cancel an existing submission.

## Development and checks

Single-step helpers live in their step; `R/` contains shared helpers.
Standalone remains independent. See [AGENTS.md](AGENTS.md) for coding guidance
and [CHANGELOG.md](CHANGELOG.md) for historical changes.

```powershell
# Routine offline suite: no download, full Stan fit, or operational publication.
Rscript.exe --vanilla tests/run-tests.R

# After compiling stan/default-rule-inclusion.stan:
Rscript.exe --vanilla tests/test-default-stan-missing-likelihood.R

# After a successful Step 4 run:
Rscript.exe --vanilla tests/test-step4-artifacts.R
```

The artifact audit uses the highest saved round; pass `output 1365`, for
example, to audit a specific round. Tests cover timing, completeness, missing
outcomes, one/zero-model portfolios, standalone/pipeline agreement, and
publication failures. Keep data, outputs, temporary runs, and compiled Stan
artifacts out of version control.
