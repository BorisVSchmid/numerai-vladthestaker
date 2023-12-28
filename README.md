# vladthestaker

For changelog see the CHANGELOG.md file
For a python alternative, see [numerai-portfolio-opt](https://github.com/eses-wk/numerai-portfolio-opt)

## Warnings

Vlad should only consider portfolios with an average positive return. This is because I noticed that
the tangency portfolio selection can be a bit wonky otherwise, and sometimes suggests portfolios
with a negative-return based on a single model. 

By default, Vlad filters out models with a 0.5xCORR+2xMMC < 0.005, and models with < 60 datapoints.

Particularly when you are just starting to use Vlad, use the model-performances-plot to see if
the models selected by Vlad make sense to you. Also check how drastically the recommendations change 
per Vlad run. In my experience, certain filtering settings (like the < 0.005) help in stabilizing the 
recommendations made by Vlad.

## Overview

Vlad helps you decide your stake weights in Numer.ai. Use at your own risk. This script has been used by me for a while now, but no guarantees are provided.

## How to use: 

1. Change the models in the Optimize-Me-21dec2023.xlsx file to your models or models you bought on NumerBay.ai.
2. Run the R script optimize_stake.R ('Rscript.exe optimize_stake.R', or run the script in Rstudio.)
3. Set the amount of NMR you want to stake on line 35 in the script.
4. Inspect the image and the two tables that the script spits out, and consider if these stake weights make sense to you.

## Under the hood:

Vlad downloads the end-of-round performances of your models and combines them to create a better portfolio (high return, low volatility). It will

* Generate a mean portfolio from 80 portfolios build from resampled model scores, to reduce the impact of the tournament's famously noisy nature. Half of these portfolios optimize for tangency and half for minvariance.
* Zero out stakes with less than 10% contribution (the threshold set on line 95) to avoid spreading tiny stakes over a long list of models. You can set this threshold to other values.

## How does the output look?

First, you will get an image that shows to you how your models perform in terms of mean _\_0.5xCORR+2xMMC_ and std _\_0.5xCORR+2xMMC_, as well as the associated max drawdown (redder dots have larger drawdowns) and autocorrelation- and samplesize-corrected sharpe (bigger dots have higher tSSR).

[MMC mean and std of the models](model-performances.png "Model performances on correlation")

Second, your models will get grouped based on how complete their time series is. Did you add a bunch of models two months ago? then two months ago is another 'starting point' for considering which models to stake on. Splitting the time series of all your models by starting points ensures that Vlad isn't disregarding the information of your older models, just because your new models don't go back that far in time.

You will get an intermediate table showing per starting point what your optimal portfolio is. 

```
   |name               |weight |stake |mean   |Cov    |CVaR  |VaR    |samplesize |starting_round |
   |:------------------|:------|:-----|:------|:------|:-----|:------|:----------|:--------------|
   |V42_LGBM_CLAUDIA20 |0.272  |59    |0.0195 |0.0264 |0.026 |0.0221 |291        |339            |
   |V42_LGBM_CT_BLEND  |0.116  |25    |       |       |      |       |           |               |
   |V42_LGBM_ROWAN20   |0.09   |19    |       |       |      |       |           |               |
   |V42_LGBM_TEAGER20  |0.315  |68    |       |       |      |       |           |               |
   |V42_LGBM_TEAGER60  |0.095  |20    |       |       |      |       |           |               |
   |V4_LGBM_VICTOR20   |0.112  |24    |       |       |      |       |           |               |
   |                   |       |      |       |       |      |       |           |               |
```

Finally, the last table merges the suggested stake distributions of your different starting points into a single stake distribution. In the case of the Numer.ai benchmark models, all 'good enough' models start at round 339, so there is only one starting point to consider, and the table is identical to the one above.

The columns _mean_, _covariance_ and _samplesize_ should be fairly self-evident, but for _CVaR_ and _VaR_ I'll gladly let ChatGPT explain those below.

_Value-at-Risk (VaR)_: VaR is a statistical measure that estimates the maximum potential loss of an investment portfolio within a specified time horizon and at a given confidence level. For example, a 1-day 95% VaR of $1 million would imply that there is a 95% probability that the portfolio will not lose more than $1 million in value over a single day. VaR is widely used in risk management as it provides a simple way to quantify and communicate potential losses. However, it has its limitations, such as not providing information about the severity of losses beyond the given confidence level.

_Conditional Value-at-Risk (CVaR)_, also known as Expected Shortfall (ES): CVaR is an extension of VaR that aims to address some of its shortcomings. It calculates the expected loss of an investment portfolio, given that the loss exceeds the VaR. In other words, CVaR provides an estimate of the average loss that can be expected in the worst-case scenarios beyond the VaR threshold. It is a more conservative and coherent risk measure, as it accounts for the tail risk (the extreme losses) and is sensitive to the shape of the loss distribution.

## Disclaimer (copied from numerai-portfolio-opt, thanks!)
- The information and code provided in this GitHub repository are for educational and entertainment purposes only. Any information in this repository is not intended to be used as financial advice, and the owner, contributor of this repository are not financial advisors.
- The owner and contributor of this repository do not guarantee the accuracy or completeness of the information provided, and they are not responsible for any losses or damages that may arise from the use of this information or code. 
