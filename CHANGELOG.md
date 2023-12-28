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