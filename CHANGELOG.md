2023-11-23: [NEW VERSION].

New version in response to the new scoring mechanism that will be activated at the end of 2023/early 2024.

Many changes, but this sums it up:

* input columns are now just name, starting round, notes (dropped end rounds column).
* made it easier to redefine within the code from what round onwards you want to consider your models
* as we are switching to a world without stake multipliers, it is just MMC now (added an option to do X corr + Y mmc for when Numer.ai switches to a mixture of corr and MMC).
* model stats have gotten fancier, including drawdown and tSSR (sharpe ratio modified for autocorrelation and sample size).
* your models likely don't all start at the same round. Vlad now calculates per starting point what the optimal portfolio is, presents all of those portfolios, and also (dumbly/blindly) combines those portfolios into a single one by equal weighting and merging the different starting point portfolios.
* pretty printing of portfolios.

2023-07-12: [BUGFIX]. Vlad now actually only considers resolved rounds (as promised in the readme). There is a new toggle in optimize_stake.R that allows you to choose the behavior.

If you want to use unresolved rounds, change the below line to onlyresolved = FALSE.

> daily_data <- build_RAW(model_df,onlyresolved = TRUE)

Also added a warning and a check for when people start tinkering with what models to add. Sometimes the tangency portfolio algorithm malfunctions, and picks a single negative-return stock. Now you get a warning that says which portfolio was excluded 
