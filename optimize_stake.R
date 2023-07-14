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
NMR <- 5000                                                    # Set the amount of NMR you want to stake
model_df <- read_excel("Optimize-Me.xlsx")                     # Read in the list of model names and their start (and possibly end) round.
model_df$`Starting Era` <- pmax(model_df$`Starting Era`,339)   # Ignore starting eras that pre-date the start of daily staking (round 339)
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

