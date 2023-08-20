# To make groundhogr work in Rstudio, go to Tools -> Global Options, and change the following two settings:
# Code -> Completion -> Show code Completion (set to Never)
# Code -> Diagnostics -> Show Diagnostics (remove tick from box)
#
library(groundhog)
pkgs <- c("conflicted","dplyr","tidyr","knitr","readxl","tibble","stringr","memoise","Rnumerai","fPortfolio","ggplot2","ggrepel")
groundhog.library(pkgs, "2023-07-05") # For R-4.3.x. You can use "2023-04-21 for R-4.2.x

#
# WARNING
#
# Vlad only considers portfolios with a average positive return. This is because I noticed that 
# the tangency portfolio selection can be a bit wonky otherwise, and sometimes suggests portfolios
# with a negative-return based on a single model.
#
# An additional safeguard in Vlad is that if either the tangency or the minvariance portfolio has 
# a negative expected return, then it is discarded and only the portfolio with a positive return
# is used.
#
# Particularly when you are just starting to use Vlad, use the model-performances-plot to see if 
# the models selected by Vlad make sense to you.
#



# Read in program-specific functions
source("functions.R")



# Vlad Input and Settings
#
NMR <- 1000                                                    # Set the amount of NMR you want to stake
model_df <- read_excel("Optimize-Me.xlsx")                     # Read in the list of model names and their start (and possibly end) round.
model_df$`Starting Era` <- pmax(model_df$`Starting Era`,339)   # Ignore starting eras that pre-date the start of daily staking (round 339)

# Use this section to set how far back you want to look in time. As Vlad excludes models that are missing data
# compared to their peers, setting a later starting era let's you include more recently developed models, but 
# at the cost of the sample size of your time series.
#

model_df$`Starting Era`
# As an example for why you might want to set a threshold from which era onward you want to evaluate 
# your models:
#
# In the below two lines I am telling Vlad only to consider models that have data from era 410 onward. 
# From round 450, everything got harder for LGBM's in the recent tournament, but as Vlad cannot deal (yet)
# with negative returns (it starts to give somewhat unstable predictions), the best I could do is to 
# evaluate the example models from era 410 onward, for which on average some are still positive.
#
#model_df$`Starting Era` <- pmax(model_df$`Starting Era`,410)
#model_df <- model_df[model_df$`Starting Era` <= 410,]
#
# Another reason to pick different Starting Era's is when not all your models go back very far in time. More
# recent models would get excluded by Vlad in favor for longer time series, but by setting the Starting Era 
# to the era that your recent models have data from, they get included into Vlad's calculations (at the price
# of having less eras in total to consider).
#
daily_data <- build_RAW(model_df,onlyresolved = TRUE)          # Choose whether to include only resolved rounds or not (TRUE/FALSE)



# To have more flexibility in creating good portfolios, each model is considered as an independent _corr model and _tc model
#
daily_both <- daily_data
daily_corr <- dplyr::select(daily_both,colnames(daily_both)[grep("_corr$",colnames(daily_both))])
daily_tc <- dplyr::select(daily_both,colnames(daily_both)[grep("_tc$",colnames(daily_both))])



# Plot and store the mean and standard deviation for CORR and TC
#
plot_corr <- as.data.frame(colMeans(daily_corr, na.rm = TRUE))
plot_corr$names <- rownames(plot_corr)
plot_corr$sd <- colSds(daily_corr, na.rm = TRUE)
colnames(plot_corr) <- c('mean','name','sd')
ggplot(plot_corr) + geom_point(aes(y=mean,x=sd)) + geom_label_repel(aes(y=mean,x=sd,label=name))
ggsave("model-performances-corr.png",scale=1,width=10,height=10)

plot_tc <- as.data.frame(colMeans(daily_tc, na.rm = TRUE))
plot_tc$names <- rownames(plot_tc)
plot_tc$sd <- colSds(daily_tc, na.rm = TRUE)
colnames(plot_tc) <- c('mean','name','sd')
ggplot(plot_tc) + geom_point(aes(y=mean,x=sd)) + geom_label_repel(aes(y=mean,x=sd,label=name))
ggsave("model-performances-tc.png",scale=1,width=10,height=10)



# Keep only models that have a positive average return. 
#
good_models_corr <- plot_corr[plot_corr$mean > 0,]$name
good_models_tc <- plot_tc[plot_tc$mean > 0,]$name

# You will get this error when there are no good-enough models.
# Solver set to solveRquadprog
# Error: Initialize timeSeries : length of '@units' not equal to '@.Data' extent


# Build portfolios.
#
daily_both <- daily_both[,c(good_models_corr,good_models_tc)]
daily_both <- daily_both[complete.cases(daily_both),]
portfolio1 <- tangency_portfolio(daily_both[sample(nrow(daily_both),replace = TRUE),]) %>% cleanup_portfolio()
portfolio2 <- minvariance_portfolio(daily_both[sample(nrow(daily_both),replace = TRUE),]) %>% cleanup_portfolio()
for (i in 1:39) {
  portfolio1 <- rbind(portfolio1,tangency_portfolio(daily_both[sample(nrow(daily_both),replace = TRUE),]) %>% cleanup_portfolio())
  portfolio2 <- rbind(portfolio2,minvariance_portfolio(daily_both[sample(nrow(daily_both),replace = TRUE),]) %>% cleanup_portfolio())
} 
portfolio1 <- portfolio1 %>% group_by(name) %>% summarise(corr_weight = sum(corr_weight) / 40, tc_weight = sum(tc_weight) / 40)
portfolio2 <- portfolio2 %>% group_by(name) %>% summarise(corr_weight = sum(corr_weight) / 40, tc_weight = sum(tc_weight) / 40)



# Join the two portfolios when that makes sense (positive returns)
#
portfolio1_return <- virtual_returns(portfolio1, daily_both, types="both")[1]
portfolio2_return <- virtual_returns(portfolio2, daily_both, types="both")[1]

if (portfolio1_return > 0 && portfolio2_return > 0) {
  print("both tangency and minvariance portfolios are positive. Merging them")
  portfolio <- rbind(portfolio1, portfolio2)
  portfolio <- portfolio %>% 
    group_by(name) %>% 
    summarise(corr_weight = sum(corr_weight) / 2, tc_weight = sum(tc_weight) / 2)
} else if (portfolio1_return > 0) {
  print("only tangency portfolio is positive. Using tangency portfolio")
  portfolio <- portfolio1
} else if (portfolio2_return > 0) {
  print("only minvariance portfolio is positive. Using minvariance portfolio")
  portfolio <- portfolio2
} else {
  print("neither portfolio has a positive return")
  rm(portfolio)
}



# Redistributing the averaged portfolio so that the minimal stake is > 5%.
#
portfolio <- portfolio[portfolio$corr_weight + portfolio$tc_weight > 0.05,]
portfolio$corr_weight <- portfolio$corr_weight * 1/(sum(portfolio$corr_weight) + sum(portfolio$tc_weight))
portfolio$tc_weight <- portfolio$tc_weight * 1/(sum(portfolio$corr_weight) + sum(portfolio$tc_weight))



# Calculate returns and risks of individual bets. 
#
singular <- t(virtual_returns(portfolio,daily_both,types="both"))
singular <- rbind(singular,t(virtual_returns(portfolio1,daily_both,types="both")))
singular <- rbind(singular,t(virtual_returns(portfolio2,daily_both,types="both")))
for (i in 1:dim(portfolio)[1]) {
  if (portfolio[i,]$corr_weight > 0 & portfolio[i,]$tc_weight == 0) {
    singular <- rbind(singular,virtual_returns(portfolio[i,],daily_both,types="corr"))
  } else if (portfolio[i,]$corr_weight == 0 & portfolio[i,]$tc_weight > 0) {
    singular <- rbind(singular,virtual_returns(portfolio[i,],daily_both,types="tc"))
  } else if  (portfolio[i,]$corr_weight > 0 & portfolio[i,]$tc_weight > 0) {
    singular <- rbind(singular,virtual_returns(portfolio[i,],daily_both,types="both"))}}    
rownames(singular) <- c("portfolio","portfolio1_tangency","portfolio2_minvariance",portfolio$name)



# Calculating stakesize for different multipliers
#
portfolio$corr_0.5x <- round(portfolio$corr_weight * 2 * NMR,-1)
portfolio$corr_1x <- round(portfolio$corr_weight * NMR,-1)
portfolio$tc_0.5x <- 2 * portfolio$tc_weight * NMR 
portfolio$tc_1x <- round(1/2 * portfolio$tc_0.5x,-1)
portfolio$tc_1.5x <- round(1/3 * portfolio$tc_0.5x,-1)
portfolio$tc_2x <- round(1/4 * portfolio$tc_0.5x,-1)
portfolio$tc_2.5x <- round(1/5 * portfolio$tc_0.5x,-1)
portfolio$tc_3x <- round(1/6 * portfolio$tc_0.5x,-1)
portfolio$tc_0.5x <- round(portfolio$tc_0.5x,-1)
portfolio$corr_weight <- round(portfolio$corr_weight,3)
portfolio$tc_weight <- round(portfolio$tc_weight,3)



# Printout result of the portfolio optimizer in two tables.
#
kable(portfolio,caption = "Suggested portfolio. For models with both a _corr and a _tc component, either set up two model slots, or find a multiplier that works for both stakes")
kable(singular,caption = "Expected returns based on separated weights")


# From era 339 onwards.
# 
# Table: Suggested portfolio. For models with both a _corr and a _tc component, either set up two model slots, or find a multiplier that works for both stakes
# 
#   |name                | corr_weight| tc_weight| corr_0.5x| corr_1x| tc_0.5x| tc_1x| tc_1.5x| tc_2x| tc_2.5x| tc_3x|
#   |:-------------------|-----------:|---------:|---------:|-------:|-------:|-----:|-------:|-----:|-------:|-----:|
#   |INTEGRATION_TEST    |       0.810|     0.001|      1620|     810|       0|     0|       0|     0|       0|     0|
#   |LG_LGBM_V4_JEROME20 |       0.024|     0.065|        50|      20|     130|    70|      40|    30|      30|    20|
#   |LG_LGBM_V4_VICTOR20 |       0.095|     0.000|       190|      90|       0|     0|       0|     0|       0|     0|
# 
# 
# Table: Expected returns based on separated weights
# 
#   |                       |   mean|    Cov|   CVaR|    VaR| samplesize|
#   |:----------------------|------:|------:|------:|------:|----------:|
#   |portfolio              | 0.0073| 0.0194| 0.0261| 0.0223|        191|
#   |portfolio1_tangency    | 0.0076| 0.0198| 0.0269| 0.0240|        191|
#   |portfolio2_minvariance | 0.0070| 0.0193| 0.0261| 0.0220|        191|
#   |INTEGRATION_TEST       | 0.0059| 0.0161| 0.0212| 0.0176|        191|
#   |LG_LGBM_V4_JEROME20    | 0.0006| 0.0022| 0.0036| 0.0029|        191|
#   |LG_LGBM_V4_VICTOR20    | 0.0009| 0.0023| 0.0042| 0.0039|        191|


# From era 410 onwards. Less data, but closer to the burn that started from week 450.
#
# Table: Suggested portfolio. For models with both a _corr and a _tc component, either set up two model slots, or find a multiplier that works for both stakes
# 
#   |name                | corr_weight| tc_weight| corr_0.5x| corr_1x| tc_0.5x| tc_1x| tc_1.5x| tc_2x| tc_2.5x| tc_3x|
#   |:-------------------|-----------:|---------:|---------:|-------:|-------:|-----:|-------:|-----:|-------:|-----:|
#   |LG_LGBM_V4_JEROME20 |       0.886|         0|      1770|     890|       0|     0|       0|     0|       0|     0|
#   |LG_LGBM_V4_WALDO20  |       0.114|         0|       230|     110|       0|     0|       0|     0|       0|     0|
# 
# 
# Table: Expected returns based on separated weights
# 
#   |                       |  mean|    Cov|   CVaR|    VaR| samplesize|
#   |:----------------------|-----:|------:|------:|------:|----------:|
#   |portfolio              | 8e-04| 0.0212| 0.0376| 0.0340|        122|
#   |portfolio1_tangency    | 9e-04| 0.0212| 0.0378| 0.0342|        122|
#   |portfolio2_minvariance | 7e-04| 0.0213| 0.0375| 0.0342|        122|
#   |LG_LGBM_V4_JEROME20    | 8e-04| 0.0187| 0.0334| 0.0303|        122|
#   |LG_LGBM_V4_WALDO20     | 0e+00| 0.0026| 0.0045| 0.0043|        122|