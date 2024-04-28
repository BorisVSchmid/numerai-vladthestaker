# vladthestaker

For changelog see the CHANGELOG.md file
For a python alternative, see [numerai-portfolio-opt](https://github.com/eses-wk/numerai-portfolio-opt)

## Warnings

Vlad should only consider portfolios with an average positive return. This is because I noticed that
the tangency portfolio selection can be a bit wonky otherwise, and sometimes suggests portfolios
with a negative-return based on a single model. 

By default, Vlad filters out models with a 0.5xCORR+2xMMC < 0.005, and models with < 60 resolved rounds.

Particularly when you are just starting to use Vlad, use the model-performances-plot to see if
the models selected by Vlad make sense to you. Also check how drastically the recommendations change 
per Vlad run. In my experience, certain filtering settings (like filtering out models with a mean 
score < 0.005) help in stabilizing the recommendations made by Vlad.

## Overview

Vlad helps you decide your stake weights in Numer.ai. Use at your own risk. This script has been used by me for a while now, but no guarantees are provided.

## How to use: 

1. Change the models in the Optimize-Me-26apr2024.xlsx file to your models or models you bought on NumerBay.ai.
2. Run the R script optimize_stake.R ('Rscript.exe optimize_stake.R', or run the script in Rstudio.)
3. Set the amount of NMR you want to stake on line 35 in the script.
4. Inspect the image and the two tables that the script spits out, and consider if these stake weights make sense to you.
optional:
5. If the number of models suggested is too big or too small, you can tweak the threshold number in lin 97. That sets the
minimum % contribution a model has to have to be considered.
6. Depending on how often you have started new models, you might want to consolidate and reduce the number of starting_points in line 89. For the benchmark models, it makes sense to reduce the list of 339, 340, 553, 591, 593, 602, 627, 649 to 340, 553, 602, 649, for example.

## Under the hood:

Vlad downloads the end-of-round performances of your models and combines them to create a better portfolio (high return, low volatility). It will

* Generate a mean portfolio from 80 portfolios build from resampled model scores, to reduce the impact of the tournament's famously noisy nature. Half of these portfolios optimize for tangency and half for minvariance portfolios
* Zero out stakes with less than 10% contribution (the threshold set on line 97) to avoid spreading tiny stakes over a long list of models. You can set this threshold to other values.

## How does the output look?

First, you will get an image that shows to you how your models perform in terms of mean _\_0.5xCORR+2xMMC_ and std _\_0.5xCORR+2xMMC_, as well as the associated max drawdown (redder dots have larger drawdowns) and autocorrelation- and samplesize-corrected sharpe (bigger dots have higher tSSR).

[MMC mean and std of the models](model-performances-05corr-2mmc.png "Model performances on correlation")

Second, your models will get grouped based on how complete their time series is. Did you add a bunch of models two months ago? then two months ago is another 'starting point' for considering which models to stake on. Splitting the time series of all your models by starting points ensures that Vlad isn't disregarding the information of your older models, just because your new models don't go back that far in time.

You will get an intermediate table showing per starting point what your optimal portfolio is. 

```
  |name               |weight |stake |mean   |Cov    |CVaR   |VaR     |samplesize |starting_round |
  |:------------------|:------|:-----|:------|:------|:------|:-------|:----------|:--------------|
  |V2_EXAMPLE_PREDS   |0.253  |25    |0.0117 |0.0221 |0.0199 |0.0154  |379        |340            |
  |V3_EXAMPLE_PREDS   |0.279  |28    |       |       |       |        |           |               |
  |V4_LGBM_VICTOR20   |0.326  |33    |       |       |       |        |           |               |
  |V4_LGBM_VICTOR60   |0.142  |14    |       |       |       |        |           |               |
  |                   |       |      |       |       |       |        |           |               |
  |NB_HELLO_NUMERAI   |0.1    |10    |0.0137 |0.0134 |0.0102 |0.0048  |166        |553            |
  |V41_LGBM_CYRUS20   |0.19   |19    |       |       |       |        |           |               |
  |V41_LGBM_CYRUS60   |0.138  |14    |       |       |       |        |           |               |
  |V4_LGBM_NOMI60     |0.145  |14    |       |       |       |        |           |               |
  |V4_LGBM_RALPH20    |0.086  |9     |       |       |       |        |           |               |
  |V4_LGBM_VICTOR60   |0.133  |13    |       |       |       |        |           |               |
  |V4_LGBM_WALDO20    |0.095  |10    |       |       |       |        |           |               |
  |V4_LGBM_WALDO60    |0.113  |11    |       |       |       |        |           |               |
  |                   |       |      |       |       |       |        |           |               |
  |NB_EXAMPLE_MODEL   |0.234  |23    |0.0155 |0.0089 |0.0007 |-0.0022 |117        |602            |
  |V41_LGBM_CYRUS20   |0.181  |18    |       |       |       |        |           |               |
  |V42_EXAMPLE_PREDS  |0.195  |20    |       |       |       |        |           |               |
  |V42_RAIN_ENSEMBLE2 |0.203  |20    |       |       |       |        |           |               |
  |V4_LGBM_VICTOR20   |0.187  |19    |       |       |       |        |           |               |
  |                   |       |      |       |       |       |        |           |               |
  |NB_EXAMPLE_MODEL   |0.201  |20    |0.0131 |0.0084 |0.002  |-0.0005 |72         |649            |
  |NB_TARGET_ENSEMBLE |0.098  |10    |       |       |       |        |           |               |
  |V41_EXAMPLE_PREDS  |0.107  |11    |       |       |       |        |           |               |
  |V42_EXAMPLE_PREDS  |0.11   |11    |       |       |       |        |           |               |
  |V42_LGBM_AGNES20   |0.135  |14    |       |       |       |        |           |               |
  |V42_RAIN_ENSEMBLE  |0.099  |10    |       |       |       |        |           |               |
  |V43_LGBM_CYRUS60   |0.104  |10    |       |       |       |        |           |               |
  |V4_LGBM_TYLER20    |0.147  |15    |       |       |       |        |           |               |
```


The columns _mean_, _covariance_ and _samplesize_ should be fairly self-evident, but for _CVaR_ and _VaR_ I'll gladly let ChatGPT explain those below.

_Value-at-Risk (VaR)_: VaR is a statistical measure that estimates the maximum potential loss of an investment portfolio within a specified time horizon and at a given confidence level. For example, a 1-day 95% VaR of $1 million would imply that there is a 95% probability that the portfolio will not lose more than $1 million in value over a single day. VaR is widely used in risk management as it provides a simple way to quantify and communicate potential losses. However, it has its limitations, such as not providing information about the severity of losses beyond the given confidence level.

_Conditional Value-at-Risk (CVaR)_, also known as Expected Shortfall (ES): CVaR is an extension of VaR that aims to address some of its shortcomings. It calculates the expected loss of an investment portfolio, given that the loss exceeds the VaR. In other words, CVaR provides an estimate of the average loss that can be expected in the worst-case scenarios beyond the VaR threshold. It is a more conservative and coherent risk measure, as it accounts for the tail risk (the extreme losses) and is sensitive to the shape of the loss distribution.

## Visualisation of cumulative portfolios.

Finally, to help you make a decision on the tradeoff between sample size and performance, you get a cumulative performance plot that shows how the different ensembled perform.

[MMC mean and std of the models](portfolio-performances-05corr-2mmc.png "Portfolio performances on correlation")

## Disclaimer (copied from numerai-portfolio-opt, thanks!)
- The information and code provided in this GitHub repository are for educational and entertainment purposes only. Any information in this repository is not intended to be used as financial advice, and the owner, contributor of this repository are not financial advisors.
- The owner and contributor of this repository do not guarantee the accuracy or completeness of the information provided, and they are not responsible for any losses or damages that may arise from the use of this information or code. 
