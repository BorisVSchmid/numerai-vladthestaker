# vladthestaker

For changelog see the CHANGELOG.md file
For a python alternative, see [numerai-portfolio-opt](https://github.com/eses-wk/numerai-portfolio-opt)

## Warnings

Vlad only considers portfolios with a average positive return. This is because I noticed that
the tangency portfolio selection can be a bit wonky otherwise, and sometimes suggests portfolios
with a negative-return based on a single model.

An additional safeguard in Vlad is that if either the tangency or the minvariance portfolio has
a negative expected return, then it is discarded and only the portfolio with a positive return
is used.

Particularly when you are just starting to use Vlad, use the model-performances-plot to see if
the models selected by Vlad make sense to you.

## Overview

Vlad helps you decide your stake weights in Numer.ai. Use at your own risk. This script has been used by me for a while now, but no guarantees are provided.

## How to use: 

1. Change the models in the Optimize-Me.xlsx file to your models or models you bought on NumerBay.ai.
2. Run the R script optimize_stake.R ('Rscript.exe optimize_stake.R', or run the script in Rstudio.)
3. Inspect the two images and the two tables that the script spits out, and consider if these make sense to you.

## Under the hood:

Vlad downloads the end-of-round performances of your models and combines them to create a better portfolio (high return, low volatility). It will

* Split up models into a _\_corr_ and a _\_tc_  model. That gives the optimizer (and you!) the freedom to stake on corr and tc in any ratio you like.
* Generate a mean portfolio from 80 portfolios build from resampled model scores, to reduce the impact of the tournament's famously noisy nature. Half of these portfolios optimize for tangency and half for minvariance.
* Zero out stakes with less than 5% contribution to avoid spreading tiny stakes over a long list of models.

## How does the output look?

First, you will get two images shown to you that show how your models perform in terms of mean _\_corr_ and std _\_corr_, and mean _\_tc_ and std _\_tc_.

[correlation mean and std of the models](model-performances-corr.png "Model performances on correlation")

[TC mean and std of the models](model-performances-tc.png "Model performances on True Contribution")

Second, you will get two tables back. The first table suggests how to distribute your stake. For models with both a _\_corr_ and a _\_tc_ component, either set up two model slots, or find a multiplier that works for both stakes.

In the example below, the first two columns give the relative weights on _corr_ and on _tc_ for each of the models. This doesn't always add up to exactly 1 because the script zeroes out some of the <5% suggestions of the optimizer. The next 8 columns translate those corr and tc weights into the amount of NMR to stake for different multipliers (rounded to the nearest 10 NMR). For example, for INTEGRATION_TEST, the optimizer suggests to pick a stake of 160 NMR at 1x corr, and a stake of 60 NMR at 3x TC, which you cannot do within a single model slot. You can follow the staking advice more precisely by using different multipliers, and the script helps with that. In this case, you could stake 165 NMR at 1x corr and 1x TC, which is a compromise between the suggested 160 NMR at 1x corr and 170 NMR at 1x TC. If the suggested stakesizes between corr and TC are incompatible for all multipliers, you could use two model slots so you can stake the suggested stake weights exactly.

As Vlad doesn't take into account potential saving or shortcomings of NMR by using multipliers other than 1, you might have to adjust the target NMR value you specify in the beginning of the script.

```
Table: Suggested portfolio. 

|name                | corr_weight| tc_weight| corr_0.5x| corr_1x| tc_0.5x| tc_1x| tc_1.5x| tc_2x| tc_2.5x| tc_3x|
|:-------------------|-----------:|---------:|---------:|-------:|-------:|-----:|-------:|-----:|-------:|-----:|
|INTEGRATION_TEST    |       0.160|     0.170|       320|     160|     340|   170|     110|    90|      70|    60|
|LG_LGBM_V4_JEROME20 |       0.026|     0.128|        50|      30|     260|   130|      90|    60|      50|    40|
|LG_LGBM_V4_RALPH20  |       0.097|     0.000|       190|     100|       0|     0|       0|     0|       0|     0|
|LG_LGBM_V4_TYLER20  |       0.000|     0.342|         0|       0|     680|   340|     230|   170|     140|   110|
|LG_LGBM_V4_WALDO20  |       0.069|     0.006|       140|      70|      10|    10|       0|     0|       0|     0|
```

The second table starts with showing the expected returns of the suggested portfolio. The two lines below show you how the tangency and minvariance portfolio differ in risk. Finally, you see the individual performance of each of the recommended models. 

```
Table: Expected returns based on separated weights

|                       |   mean|    Cov|   CVaR|    VaR| samplesize|
|:----------------------|------:|------:|------:|------:|----------:|
|portfolio              | 0.0094| 0.0238| 0.0375| 0.0313|        140|
|portfolio1_tangency    | 0.0102| 0.0252| 0.0387| 0.0307|        140|
|portfolio2_minvariance | 0.0085| 0.0235| 0.0367| 0.0313|        140|
|INTEGRATION_TEST       | 0.0032| 0.0078| 0.0147| 0.0108|        140|
|LG_LGBM_V4_JEROME20    | 0.0013| 0.0042| 0.0068| 0.0061|        140|
|LG_LGBM_V4_RALPH20     | 0.0006| 0.0025| 0.0041| 0.0039|        140|
|LG_LGBM_V4_TYLER20     | 0.0036| 0.0122| 0.0153| 0.0138|        140|
|LG_LGBM_V4_WALDO20     | 0.0007| 0.0019| 0.0032| 0.0031|        140|
```
The columns _mean_, _covariance_ and _samplesize_ should be fairly self-evident, but for _CVaR_ and _VaR_ I'll gladly let ChatGPT explain those below.

_Value-at-Risk (VaR)_: VaR is a statistical measure that estimates the maximum potential loss of an investment portfolio within a specified time horizon and at a given confidence level. For example, a 1-day 95% VaR of $1 million would imply that there is a 95% probability that the portfolio will not lose more than $1 million in value over a single day. VaR is widely used in risk management as it provides a simple way to quantify and communicate potential losses. However, it has its limitations, such as not providing information about the severity of losses beyond the given confidence level.

_Conditional Value-at-Risk (CVaR)_, also known as Expected Shortfall (ES): CVaR is an extension of VaR that aims to address some of its shortcomings. It calculates the expected loss of an investment portfolio, given that the loss exceeds the VaR. In other words, CVaR provides an estimate of the average loss that can be expected in the worst-case scenarios beyond the VaR threshold. It is a more conservative and coherent risk measure, as it accounts for the tail risk (the extreme losses) and is sensitive to the shape of the loss distribution.
