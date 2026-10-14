### 2026-10-14: V6.0.0

This release replaces the optimizer workflow of V5 with one fixed allocation rule, **EW(pos) D60+|W9**, and uses step3 to a check whether that rule suits the account and its models. Nothing in the pipeline fits or selects portfolio weights any more: the grid sweep over training offsets and window sizes, the tangency/min-CVaR/risk-parity/online-EW solvers, ranked cell selection, the Pre-IS/IS/forward-OOS evaluation and the stake-sizing output are all gone. What remains is a deterministic rule, a Bayesian diagnostic for it, and a small operator path that publishes the current-round weights.

The above is a departure of previous versions, which (for me at least) consistently showed deterioration of portfolio quality over time. Rather than fitting one-time tangency or minvariance portfolios or blends thereof, VladtheStaker v6 fits a continuously updated equal-weights portfolio of all the models whose last 9 finalized scores were on average positive. For current round `t` those are the finalized D60 cells (`3 * canon_corr60 + 15 * canon_mmc60`) of rounds `t-64` through `t-72` (a round's day-60 score only becomes actionable upon 64 rounds after the round. This choice of portfolio is based on a large hyperparameter tuning run on 14 public accounts, and exploration of different portfolio's, from equal weights to tangency, for various window lengths, using blends of finalized and non-finalized scores. This EW(pos) D60+|W9 model came out on top. In contrast to earlier portfolio's, this portfolio should be updated daily. One positive model is enough; zero positives means no submission (and a zero score in historical replay).

So, in summary, for target round t:
1. Keep models permitted by Include? = Yes.
2. Discard models that do not have 9 submissions from t-64 to t-72.
3. Calculate each model’s nine-score mean and keep those whose mean is strictly positive.
4. Give the surviving models equal weights, 1 / N.
5. If N == 0, create a portfolio CSV with headers only.
“Positive” means the nine-cell mean is positive; individual cells may be negative.

Furthermore, this changelog uses the D60 outcomes, now that Numer.ai switched to a D60 tournament, with the 3x CORR, 15x MMC weights.

### V5.1.0: added model comparisons (February 27)

This minor release clarifies documentation and adds model-performance comparisons:

* Adds two CSV files in `output/` comparing Vlad-generated portfolios with the
  input models as-is on return, CVaR, and maximum drawdown.
* Adds a Pareto-frontier column based on those three metrics.
* Includes a `corr_return` column, highlighting Numerai's SWMM as the strongest
  overall performer in the release's comparison.

### 2026-02-26: V5.0.0

This release is a major workflow refresh for Vlad the Staker. The main changes are splitting the data into In Sample data used for portfolio construction, and Out Of Sample data used for validation. We also take a new approach in robustness: rather than using resampling of rounds to generate a sense of robustness, we built portfolios across different starting rounds and training-window sizes, with a clearer forward-OOS evaluation flow.

Operationally, the project is now organized as a three-step pipeline with dedicated runners and centralized workbook-driven parameters. This makes reruns more predictable and reduces manual script editing if you want to change some of the parameters.

* Replaced legacy scripts with `step1_get_data.R`, `step2_sweep_grid_windows.R`, `step3_build_3xportfolios_oos.R`, plus `run_pipeline.sh` and `run_pipeline.bat`.
* Migrated input/config to `Optimize-Me.xlsx` and added centralized parameter loading/validation via `functions-config.R`.
* Replaced legacy outputs (`output/daily_data.csv`, old suggestion/plot files) with the current Step1/Step2/Step3 CSV and plot contracts.
* Updated README image links to local `output/*.png` paths.

### 2025-04-24: V4.0.0

* Split up collecting the data and running the optimizer in two. This way, you only hit the API once, until you decide to refresh the data.

### 2024-04-28: V3.0.0

* Added a cumulative visualisation of the starting points that works pretty well.
* The benchmark models are now only plotted from the moment they are staked.
* Tweaked the dot size when visualizing tSSR

### 2023-12-28: V2.0.4 [BUGFIX].

I was taking the Acf1 of the mean of the list of models you have, and it should have been the Acf1 of the time series of the individual models. Fixed now. Also replaced the Acf1 from R for a custom one, which ignores any pairs of sequential numbers where either one is NA. Standard Acf in R does weird things.

Also removed the benchmark model-based thresholds for what is a good model, to a simpler "consider any model with a 0.5xcorr+2xMMC score > 0.005". Selecting models on a benchmark-based threshold was discarding quite a lot of models a priori, and I would rather have the portfolio optimizer decide on that.

### 2023-12-21: V2.0.3 [WEIGHTS UPDATE].

Numer.ai changed its opinion twice and moved to a 0.5xCORR + 3xMMC weights and back to a 0.5xCORR+2xMMC weights. They also fixed a scoring bug, so I had to re-run the optimizer.

Noticed a bug in the acf1 calculations. Fixing that in the next version as it is not critical.

### 2023-11-27: V2.0.2 [WEIGHTS UPDATE].

Numer.ai published the multipliers they are going to use - it is 0.5xCORR + 2xMMC. Vlad was ready for the change.

### 2023-11-26: V2.0.1 [BUGFIX].

MMC scores are now filled in by Numer.ai, and the bug in v2.0.0 is fixed. Vlad is usable!

The bug was line 58 in functions.R, where there is a ```colnames(temp) <- c("roundNumber","score")``` that shouldn't be there, which renames the _corr20V2_ column to that of _score_

### 2023-11-23: V2.0.0 [NEW VERSION. RELEASED].

New version in response to the new scoring mechanism that will be activated at the end of 2023/early 2024.

Many changes, but this sums it up:

* input columns are now just name, starting round, notes (dropped end rounds column).
* made it easier to redefine within the code from what round onwards you want to consider your models
* as we are switching to a world without stake multipliers, it is just MMC now (added an option to do X corr + Y mmc for when Numer.ai switches to a mixture of corr and MMC).
* model stats have gotten fancier, including drawdown and tSSR (sharpe ratio modified for autocorrelation and sample size).
* your models likely don't all start at the same round. Vlad now calculates per starting point what the optimal portfolio is, presents all of those portfolios, and also (dumbly/blindly) combines those portfolios into a single one by equal weighting and merging the different starting point portfolios.
* pretty printing of portfolios.

### 2023-07-12: V1.0.1 [BUGFIX]. 

Vlad now actually only considers resolved rounds (as promised in the readme). There is a new toggle in optimize_stake.R that allows you to choose the behavior.

If you want to use unresolved rounds, change the below line to onlyresolved = FALSE.

> daily_data <- build_RAW(model_df,onlyresolved = TRUE)

Also added a warning and a check for when people start tinkering with what models to add. Sometimes the tangency portfolio algorithm malfunctions, and picks a single negative-return stock. Now you get a warning that says which portfolio was excluded 

### 2023-07-12: V1.0.0 [FIRST VERSION. RELEASED]. 

See readme.
