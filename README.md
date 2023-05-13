# vladthestaker

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

In the example below, the first two columns give the relative weights on _corr_ and on _tc_ for each of the models. This doesn't add up to exactly 1 because of zeroing out some of the <5% suggestions of the optimizer, but typically gets fairly close to 1. The next 8 columns translate those corr and tc weights into the amount of NMR to stake for different multipliers (rounded to the nearest 10 NMR). For example, for LG_LGBM_V4_JEROME20, the optimizer suggests to pick a stake of 20 NMR at 1x corr, and a stake of 30 NMR at 3x TC. So here you have to make a choice whether to use two model slots (so you can stake exactly 20 NMR at 1x corr and 30 NMR at 3x TC, or pick something in between and use only a single model slot.

As Vlad doesn't take into account potential saving or shortcomings of NMR by using multipliers other than 1, you might have to adjust the target NMR value you specify in the beginning of the script.

```
Table: Suggested portfolio. 

|name                | corr_weight| tc_weight| corr_0.5x| corr_1x| tc_0.5x| tc_1x| tc_1.5x| tc_2x| tc_2.5x| tc_3x|
|:-------------------|-----------:|---------:|---------:|-------:|-------:|-----:|-------:|-----:|-------:|-----:|
|INTEGRATION_TEST    |       0.000|     0.242|         0|       0|     480|   240|     160|   120|     100|    80|
|LG_LGBM_V4_JEROME20 |       0.018|     0.101|        40|      20|     200|   100|      70|    50|      40|    30|
|LG_LGBM_V4_RALPH20  |       0.076|     0.000|       150|      80|       0|     0|       0|     0|       0|     0|
|LG_LGBM_V4_VICTOR20 |       0.443|     0.000|       890|     440|       0|     0|       0|     0|       0|     0|
|LG_LGBM_V4_WALDO20  |       0.001|     0.105|         0|       0|     210|   100|      70|    50|      40|    30|
```

The second table starts with showing the expected returns of the suggested portfolio. The two lines below show you how the tangency and minvariance portfolio differ in risk. Finally, you see the individual performance of each of the recommended models. The columns mean, covariance and samplesize should be fairly self-evident, but for CVaR and VaR I'll gladly let ChatGPT explain those below.

```
Table: Expected returns based on separated weights

|                       |   mean|    Cov|   CVaR|    VaR| samplesize|
|:----------------------|------:|------:|------:|------:|----------:|
|portfolio              | 0.0226| 0.0239| 0.0145| 0.0105|         94|
|portfolio1_tangency    | 0.0259| 0.0250| 0.0157| 0.0124|         94|
|portfolio2_minvariance | 0.0196| 0.0243| 0.0141| 0.0107|         94|
|INTEGRATION_TEST       | 0.0042| 0.0085| 0.0105| 0.0097|         94|
|LG_LGBM_V4_JEROME20    | 0.0014| 0.0034| 0.0040| 0.0031|         94|
|LG_LGBM_V4_RALPH20     | 0.0017| 0.0025| 0.0038| 0.0031|         94|
|LG_LGBM_V4_VICTOR20    | 0.0140| 0.0134| 0.0100| 0.0063|         94|
|LG_LGBM_V4_WALDO20     | 0.0012| 0.0040| 0.0044| 0.0036|         94|
```

Value-at-Risk (VaR): VaR is a statistical measure that estimates the maximum potential loss of an investment portfolio within a specified time horizon and at a given confidence level. For example, a 1-day 95% VaR of $1 million would imply that there is a 95% probability that the portfolio will not lose more than $1 million in value over a single day. VaR is widely used in risk management as it provides a simple way to quantify and communicate potential losses. However, it has its limitations, such as not providing information about the severity of losses beyond the given confidence level.

Conditional Value-at-Risk (CVaR), also known as Expected Shortfall (ES): CVaR is an extension of VaR that aims to address some of its shortcomings. It calculates the expected loss of an investment portfolio, given that the loss exceeds the VaR. In other words, CVaR provides an estimate of the average loss that can be expected in the worst-case scenarios beyond the VaR threshold. It is a more conservative and coherent risk measure, as it accounts for the tail risk (the extreme losses) and is sensitive to the shape of the loss distribution.
