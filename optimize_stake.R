# Disable these options in Rstudio
#
# Code -> Completion -> Show code Completion (set to Never)
# Code -> Diagnostics -> Show Diagnostics
#
# That will stop Rstudio from automatically loading packages, which stops groundhog from 
# being able to function. See # https://github.com/rstudio/rstudio/issues/8072#issuecomment-1187683874
# 
# Clean up your environment
rm(list=ls())
#
# These packages are needed for sanity and reproducibility
# install.packages("groundhog") # version 3.1.0
library(groundhog)
#
# Now load your packages and pin the date. See https://groundhogr.com
pkgs <- c("conflicted","dplyr","tidyr","knitr","readxl","tibble","stringr",
          "memoise","Rnumerai","fPortfolio",
          "ggplot2","ggrepel")
#groundhog.library(pkgs, "2023-04-21") # For R-4.2.x
groundhog.library(pkgs, "2023-07-05") # For R-4.3.0
#
# For a first time, you might have to restart and re-run the above code a few times. Follow the instructions.
#
# SessionInfo documents what package versions you have loaded
sessionInfo()
#
##################

# 
# Docs
#
# Read the README.md
#
# More info on fPortfolio here: https://www.rmetrics.org/downloads/9783906041018-fPortfolio.pmerged_portfolio

source("functions.R")


#
# Data
#
NMR <- 1000 # Amount of NMR you want to stake in total.
input_name <- "Optimize-Me"
model_df <- read_excel(paste0(input_name,".xlsx"))
#
# Ignore model scores prior to the start of the daily rounds
oldest_era <- 339
model_df$`Starting Era` <- ifelse(model_df$`Starting Era` < oldest_era,oldest_era,model_df$`Starting Era`)
#
# If you want to use unresolved rounds, change to onlyresolved = FALSE. 
daily_data <- build_RAW(model_df,onlyresolved = TRUE)
#
# To have more flexibility in creating good portfolios, each model is considered as an
# independent _corr model and _tc model
daily_both <- daily_data
daily_corr <- dplyr::select(daily_both,colnames(daily_both)[grep("_corr$",colnames(daily_both))])
daily_tc <- dplyr::select(daily_both,colnames(daily_both)[grep("_tc$",colnames(daily_both))])

# Plot corr scores
plot_corr <- as.data.frame(colMeans(daily_corr, na.rm = TRUE))
plot_corr$names <- rownames(plot_corr)
plot_corr$sd <- colSds(daily_corr, na.rm = TRUE)
colnames(plot_corr) <- c('mean','name','sd')
g1 <- ggplot(plot_corr) + geom_point(aes(y=mean,x=sd)) + geom_label_repel(aes(y=mean,x=sd,label=name))
ggsave("model-performances-corr.png",g1,scale=1,width=10,height=10)

# Plot tc scores
plot_tc <- as.data.frame(colMeans(daily_tc, na.rm = TRUE))
plot_tc$names <- rownames(plot_tc)
plot_tc$sd <- colSds(daily_tc, na.rm = TRUE)
colnames(plot_tc) <- c('mean','name','sd')
g2 <- ggplot(plot_tc) + geom_point(aes(y=mean,x=sd)) + geom_label_repel(aes(y=mean,x=sd,label=name))
ggsave("model-performances-tc.png",g2,scale=1,width=10,height=10)


# Filter out those above 0
#
# This step helps the stability of the tangency portfolio selection
#
good_models_corr <- plot_corr[plot_corr$mean > 0,]$name
good_models_tc <- plot_tc[plot_tc$mean > 0,]$name

# Build portfolios.
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
# Expanded this bit of code to build in a safety check. Sometimes the tangency portfolio algorithm can pick something really odd,
# like a single negative-return model. Most of that behavior seems to have been stopped by selecting for positive-return models,
# but when you start allowing negative return models to reduce risk by changing the filter step ("Filter out those above 0"), it helps
# to have this safety check build in.
#
if (virtual_returns(portfolio1,daily_both,types="both")[1] > 0) {
  if (virtual_returns(portfolio2,daily_both,types="both")[1] > 0) {
    print("both tangency and minvariance portfolios are positive. Merging them")
    portfolio <- rbind(portfolio1,portfolio2)
    # Joining the two portfolios has some impact on the portfolio performance - as in: adding the same portfolio twice and dividing
    # by 2 doesn't exactly give the same portfolio performance
    portfolio <- portfolio %>% group_by(name) %>% summarise(corr_weight = sum(corr_weight) / 2, tc_weight = sum(tc_weight) / 2)
  } else {
    print("only tangency portfolio is positive. Using tangency portfolio")
    portfolio <- portfolio1
  } 
} else {
  if (virtual_returns(portfolio2,daily_both,types="both")[1] > 0) {
    print("only minvariance portfolio is positive. Using minvariance portfolio")
    portfolio <- portfolio2
  } else {
    print("neither portfolio has a positive return")
  }
}


# Re-weight that anything that is < 5% gets zeroed out.
portfolio <- portfolio[portfolio$corr_weight + portfolio$tc_weight > 0.05,]
portfolio$corr_weight <- portfolio$corr_weight * 1/(sum(portfolio$corr_weight) + sum(portfolio$tc_weight))
portfolio$tc_weight <- portfolio$tc_weight * 1/(sum(portfolio$corr_weight) + sum(portfolio$tc_weight))

# Calculate returns and risks of individual bets. 
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


# By printing out the stake needed for the various multipliers for corr and TC
# you can choose the ratio that closest matches the portfolio ratios. Alternatively 
# you can split the corr and tc stakes over two accounts.
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

kable(portfolio,caption = "Suggested portfolio. For models with both a _corr and a _tc component, either set up two model slots, or find a multiplier that works for both stakes")
kable(singular,caption = "Expected returns based on separated weights")
