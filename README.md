# vladthestaker

For changelog see the CHANGELOG.md file
For a python alternative, see [numerai-portfolio-opt](https://github.com/eses-wk/numerai-portfolio-opt)

## Warnings

Vlad should only consider portfolios with an average positive return. This is because I noticed that
the tangency portfolio selection can be a bit wonky otherwise, and sometimes suggests portfolios
with a negative-return based on a single model. By default, Vlad uses 80% of the mean benchmark-models 
scores, which in general is positive.

Particularly when you are just starting to use Vlad, use the model-performances-plot to see if
the models selected by Vlad make sense to you.

## Overview

Vlad helps you decide your stake weights in Numer.ai. Use at your own risk. This script has been used by me for a while now, but no guarantees are provided.

## How to use: 

1. Change the models in the Optimize-Me-23nov2023.xlsx file to your models or models you bought on NumerBay.ai.
2. Run the R script optimize_stake.R ('Rscript.exe optimize_stake.R', or run the script in Rstudio.)
3. Inspect the images and the two tables that the script spits out, and consider if these make sense to you.

## Under the hood:

Vlad downloads the end-of-round performances of your models and combines them to create a better portfolio (high return, low volatility). It will

* Generate a mean portfolio from 80 portfolios build from resampled model scores, to reduce the impact of the tournament's famously noisy nature. Half of these portfolios optimize for tangency and half for minvariance.
* Zero out stakes with less than 10% contribution to avoid spreading tiny stakes over a long list of models. You can set this threshold to other values. Look for the threshold variable in the script.

## How does the output look?

First, you will get an image that shows to you how your models perform in terms of mean _\_mmc_ and std _\_mmc_, as well as the associated max drawdown (bigger dots have less drawdowns) and autocorrelation- and samplesize-corrected sharpe (blacker dots have higher sharpes)

[MMC mean and std of the models](model-performances.png "Model performances on correlation")

Second, your models will get grouped based on how complete their time series is. Did you add a bunch of models two months ago? then two months ago is another 'starting point' for considering which models to stake on. Splitting the time series of all your models by starting points ensures that Vlad isn't disregarding the information of your older models, just because your new models don't go back that far in time.

You will get an intermediate table showing per starting point what your optimal portfolio is. In the case of the Numer.ai benchmark models, the V3_EXAMPLE_PREDS model has no scores for round 339, so is excluded from the portfolio optimization starting from round 339. But it has values from round 340 onwards, so round 340 is a second starting point, and there the V3_EXAMPLE_PREDS model is considered when calculating which models to stake on.

```
   |name             |weight |stake |mean   |Cov    |CVaR   |VaR    |samplesize |starting_round |
   |:----------------|:------|:-----|:------|:------|:------|:------|:----------|:--------------|
   |INTEGRATION_TEST |0.412  |59    |0.0128 |0.0219 |0.0216 |0.0184 |273        |339            |
   |V4_LGBM_VICTOR20 |0.458  |65    |       |       |       |       |           |               |
   |V4_LGBM_VICTOR60 |0.13   |19    |       |       |       |       |           |               |
   |                 |       |      |       |       |       |       |           |               |
   |INTEGRATION_TEST |0.416  |59    |0.0128 |0.0218 |0.0215 |0.0182 |273        |340            |
   |V4_LGBM_VICTOR20 |0.46   |66    |       |       |       |       |           |               |
   |V4_LGBM_VICTOR60 |0.124  |18    |       |       |       |       |           |               |
   |                 |       |      |       |       |       |       |           |               |
```

Finally, the last table merges the suggested stake distributions of your different starting points into a single stake distribution. 
For Numer.ai's models, the two timepoints (starting_round 339 and 340) don't matter much, so merging them changes little.

```
   |name             | weight| stake|mean   |Cov    |CVaR   |VaR    |samplesize |
   |:----------------|------:|-----:|:------|:------|:------|:------|:----------|
   |INTEGRATION_TEST |  0.414|    59|0.0128 |0.0218 |0.0216 |0.0183 |273        |
   |V4_LGBM_VICTOR20 |  0.459|    66|       |       |       |       |           |
   |V4_LGBM_VICTOR60 |  0.127|    18|       |       |       |       |           |
```
The columns _mean_, _covariance_ and _samplesize_ should be fairly self-evident, but for _CVaR_ and _VaR_ I'll gladly let ChatGPT explain those below.

_Value-at-Risk (VaR)_: VaR is a statistical measure that estimates the maximum potential loss of an investment portfolio within a specified time horizon and at a given confidence level. For example, a 1-day 95% VaR of $1 million would imply that there is a 95% probability that the portfolio will not lose more than $1 million in value over a single day. VaR is widely used in risk management as it provides a simple way to quantify and communicate potential losses. However, it has its limitations, such as not providing information about the severity of losses beyond the given confidence level.

_Conditional Value-at-Risk (CVaR)_, also known as Expected Shortfall (ES): CVaR is an extension of VaR that aims to address some of its shortcomings. It calculates the expected loss of an investment portfolio, given that the loss exceeds the VaR. In other words, CVaR provides an estimate of the average loss that can be expected in the worst-case scenarios beyond the VaR threshold. It is a more conservative and coherent risk measure, as it accounts for the tail risk (the extreme losses) and is sensitive to the shape of the loss distribution.

## Disclaimer (copied from numerai-portfolio-opt, thanks!)
- The information and code provided in this GitHub repository are for educational and entertainment purposes only. Any information in this repository is not intended to be used as financial advice, and the owner, contributor of this repository are not financial advisors.
- The owner and contributor of this repository do not guarantee the accuracy or completeness of the information provided, and they are not responsible for any losses or damages that may arise from the use of this information or code. 
