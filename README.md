# vladthestaker

For changelog see the CHANGELOG.md file
For a python alternative, see [numerai-portfolio-opt](https://github.com/eses-wk/numerai-portfolio-opt)

## Warnings

Vlad should only consider portfolios with an average positive return. This is because I noticed that
the tangency portfolio selection can be a bit wonky otherwise, and sometimes suggests portfolios
with a negative-return based on a single model. 

By default, Vlad filters out models with a 0.5xCORR+2xMMC < 0.001, and models with < 30 resolved rounds.

Particularly when you are just starting to use Vlad, use the model-performances-plot to see if
the models selected by Vlad make sense to you. Also check how drastically the recommendations change 
per Vlad run. In my experience, certain filtering settings (like filtering out models with a mean 
score < 0.001) help in stabilizing the recommendations made by Vlad.

## Overview

Vlad helps you decide your stake weights in Numer.ai. Use at your own risk. This script has been used by me for a while now, but no guarantees are provided.

## How to use: 

1. Change the models in the Optimize-Me-13apr2025.xlsx file to your models or models you bought on NumerBay.ai.
2. Run the R script optimize_stake_step1_get_data.R ('Rscript.exe optimize_stake_step1_get_data.R', or run the script in Rstudio.) to fetch your model performances.
3. Run the R script optimize_stake_step2_vladthestaker.R ('Rscript.exe optimize_stake_vladthestaker.R', or run the script in Rstudio.) to calculate the portfolios.
4. Inspect the image and the table that the script spits out in the output directory, and consider if these stake weights make sense to you.
optional:
5. If the number of models suggested is too big or too small, you can tweak the threshold number on line 94 ("threshold <- 0.1"). That sets the minimum % contribution a model has to have to be considered.
6. Depending on how often you have started new models, you might want to overrule the number of starting_points in line 89. For the benchmark models by uncommenting line 87 and manually define your own starting points ("starting_points <- c(843,900,950)")

## Under the hood:

Vlad downloads the end-of-round performances of your models and combines them to create a better portfolio (high return, low volatility). It will

* Generate a mean portfolio from 80 portfolios build from resampled model scores, to reduce the impact of the tournament's famously noisy nature. Half of these portfolios optimize for tangency and half for minvariance portfolios
* Zero out stakes with less than 10% contribution (the threshold set on line 94) to avoid spreading tiny stakes over a long list of models. You can set this threshold to other values.

## How does the output look?

First, you will get an image that shows to you how your models perform in terms of mean _\_0.5xCORR+2xMMC_ and std _\_0.5xCORR+2xMMC_, as well as the associated max drawdown (redder dots have larger drawdowns) and autocorrelation- and samplesize-corrected sharpe (bigger dots have higher tSSR).

![model-performances-05corr-2mmc](https://github.com/BorisVSchmid/numerai-vladthestaker/assets/25182535/4769621f-1dd1-4bb1-868b-e1f86ae9cef4)

Second, your models will get grouped based on how complete their time series is. Did you add a bunch of models two months ago? then two months ago is another 'starting point' for considering which models to stake on. Splitting the time series of all your models by starting points ensures that Vlad isn't disregarding the information of your older models, just because your new models don't go back that far in time.

You will get an intermediate table showing per starting point what your optimal portfolio is. 

```
|name               |weight |stake |mean   |Cov    |CVaR   |VaR    |samplesize |starting_round |
|:------------------|:------|:-----|:------|:------|:------|:------|:----------|:--------------|
|NB_FEAT_NEUTRAL    |0.104  |104   |0.0078 |0.0137 |0.013  |0.009  |135        |843            |
|NB_HELLO_NUMERAI   |0.233  |233   |       |       |       |       |           |               |
|NB_TARGET_ENSEMBLE |0.09   |90    |       |       |       |       |           |               |
|V5_LGBM_CT_BLEND   |0.282  |282   |       |       |       |       |           |               |
|V5_LGBM_CYRUSD     |0.29   |290   |       |       |       |       |           |               |
|                   |       |      |       |       |       |       |           |               |
|INTEGRATION_TEST   |0.369  |369   |0.0051 |0.0086 |0.0114 |0.0081 |98         |880            |
|NB_HELLO_NUMERAI   |0.156  |156   |       |       |       |       |           |               |
|V5_LGBM_CT_BLEND   |0.334  |334   |       |       |       |       |           |               |
|V5_LGBM_CYRUSD     |0.14   |140   |       |       |       |       |           |               |
|                   |       |      |       |       |       |       |           |               |
|INTEGRATION_TEST   |0.051  |51    |0.0031 |0.0088 |0.0132 |0.0116 |58         |920            |
|NB_HELLO_NUMERAI   |0.102  |102   |       |       |       |       |           |               |
|NB_TARGET_ENSEMBLE |0.089  |89    |       |       |       |       |           |               |
|V5_EXAMPLE_PREDS   |0.327  |327   |       |       |       |       |           |               |
|V5_LGBM_CT_BLEND   |0.331  |331   |       |       |       |       |           |               |
|V5_LGBM_CYRUSD     |0.101  |101   |       |       |       |       |           |               |
|                   |       |      |       |       |       |       |           |               |
```


The columns _mean_, _covariance_ and _samplesize_ should be fairly self-evident, but for _CVaR_ and _VaR_ I'll gladly let ChatGPT explain those below.

_Value-at-Risk (VaR)_: VaR is a statistical measure that estimates the maximum potential loss of an investment portfolio within a specified time horizon and at a given confidence level. For example, a 1-day 95% VaR of $1 million would imply that there is a 95% probability that the portfolio will not lose more than $1 million in value over a single day. VaR is widely used in risk management as it provides a simple way to quantify and communicate potential losses. However, it has its limitations, such as not providing information about the severity of losses beyond the given confidence level.

_Conditional Value-at-Risk (CVaR)_, also known as Expected Shortfall (ES): CVaR is an extension of VaR that aims to address some of its shortcomings. It calculates the expected loss of an investment portfolio, given that the loss exceeds the VaR. In other words, CVaR provides an estimate of the average loss that can be expected in the worst-case scenarios beyond the VaR threshold. It is a more conservative and coherent risk measure, as it accounts for the tail risk (the extreme losses) and is sensitive to the shape of the loss distribution.

## Visualisation of cumulative portfolios.

Finally, to help you make a decision on the tradeoff between sample size and performance, you get a cumulative performance plot that shows how the different ensembles perform. In this example the green and blue portfolio perform similarly over the time period that both exist, and while the red portfolio outperforms the green portfolio initially, the green one narrows the gap and is more consistent over time. 

![portfolio-performances-05corr-2mmc](https://github.com/BorisVSchmid/numerai-vladthestaker/assets/25182535/b26e5858-c955-4ad6-8da2-2c39c70a242e)

## Disclaimer (copied from numerai-portfolio-opt, thanks!)
- The information and code provided in this GitHub repository are for educational and entertainment purposes only. Any information in this repository is not intended to be used as financial advice, and the owner, contributor of this repository are not financial advisors.
- The owner and contributor of this repository do not guarantee the accuracy or completeness of the information provided, and they are not responsible for any losses or damages that may arise from the use of this information or code. 
