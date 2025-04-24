# Build on R4.4.3
# Groundhog and conflicted to improve reproducability and reduce configuration errors across systems.
library(groundhog)
pkgs <- c("conflicted", "dplyr", "tidyr", "knitr", "readxl", "tibble", "stringr", "memoise", "httr2", "fPortfolio", "ggplot2", "ggrepel", "PerformanceAnalytics","MASS")
groundhog.library(pkgs, "2024-12-01")

conflicts_prefer(dplyr::select)
conflicts_prefer(dplyr::filter)
conflicts_prefer(dplyr::lag)



## Vlad Input Data
#
daily_data <- read.csv("output/daily_data.csv") %>% select(-X)

# Filter out models with too little data to include in the metamodel.
enough_data <- colSums(!is.na(daily_data)) >= 30
daily_data <- daily_data %>% select(names(enough_data[enough_data == TRUE]))
enough_data <- rowSums(!is.na(daily_data)) > 1 # Need more than 1 cell non-na, as you get 1 cell non-na by roundnumber.
daily_data <- daily_data[enough_data,]

#
# Helper functions sourced in.
#
source("functions-portfolio.R")
options(scipen = 999)

#
# Example amount of NMR to redistribute across your stakeslots. 
# Not relevant if you only use Vlad for deciding how to weight your metamodel.
#
NMR <- 1000


## calculate stats
#
calculate_acf <- function(df) {sapply(df, function(column) acf1_pairwise(column))}
model_stats <- data.frame(name = colnames(daily_data), 
                          first_round = daily_data$roundNumber[apply(daily_data, 2, function(x) which(!is.na(x))[1])],
                          mean = colMeans(daily_data, na.rm = TRUE), 
                          rho = calculate_acf(daily_data),
                          sd = colSds(daily_data, na.rm = TRUE), 
                          drawdown = apply(daily_data, MARGIN = 2, FUN = function(column) {maxDrawdown(column)}),
                          size = colSums(!is.na(daily_data)),
                          row.names = NULL) %>% dplyr::filter(name != "roundNumber")

model_stats <- model_stats %>% mutate(sharpe = mean / sd,
                                      tSSR = ((mean / sd) * sqrt(size - 1)) / sqrt(1 - rho + rho * size))

# plot stats
model_stats$scaled <- 2 * (0.5 + unlist(lapply(unlist((lapply(model_stats$tSSR,max,0.01))),sqrt)))^2

# Set a midpoint for coloring.
midpoint_tssr <- median(model_stats$scaled)

ggplot(model_stats) + 
  geom_point(aes(y=mean,x=sd, size=size, fill = scaled),color="black",shape=21) + 
  scale_fill_gradient2(low="red4",mid="lightblue",high="green2", midpoint = midpoint_tssr) +
  labs(size = "sample size") +
  labs(fill = "tSSR Sharpe") +
  geom_text_repel(aes(y=mean,x=sd,label=name),box.padding = 0.6,max.overlaps = 20, force_pull = 0.7,min.segment.length = 1.5)
ggsave("output/model-performances-05corr-2mmc.png",scale=1,width=15,height=15)




#
# Here you can add an additional filtering step, excluding models that perform less than a mean of +0.005. 
# Doing so can prevent what seems like some numerical instabilities in the Tangency portfolio algorithm.
#
# Would recommend to leave this here.
#
good_models <- dplyr::filter(model_stats,mean >= 0.001)

# Exclude any metamodels you have included.
good_models <- dplyr::filter(good_models,name != "NUMERAI_SWMM")

## When do these models start?
#
starting_points <- sort(unique(good_models %>% pull(first_round)))
table(starting_points)

# 
# Manual step. You can reduce the number of starting points here.
# 
# starting_points <- c(843,900,950)


## Calculate portfolios from each of the starting points onwards.
#

# You can tweak this number: lower threshold lead to more complicated ensembles.
threshold <- 0.1
plot_data <- data.frame()
#
combined <- data.frame()
for (point in starting_points) {
  print(point)
  tryCatch({
    relevant_models <- dplyr::filter(good_models,first_round <= point) %>% pull(name)
    daily <- daily_data %>% dplyr::filter(roundNumber >= point) %>% dplyr::select(all_of(relevant_models)) %>% na.omit()
    portfolio <- build_portfolio(daily,threshold = threshold)
    plot_data <- rbind(plot_data,build_plot(portfolio,point))
    newreturns <- as.data.frame(unlist(virtual_returns(daily_data,portfolio)))
    merged <- cbind(portfolio,newreturns)
    merged$starting_round <- point
    merged[2:nrow(merged),4:9] <- ""
    combined <- rbind(combined,merged,"")
  }, error = function(e) {
    message("An error occurred: ", e$message)
  })
}

# adjusted data shifts the starting offset of later performance time series to that of the previous starting point time series
# 
adjusted_data <- plot_data %>% arrange(starting_round,roundNumber)
offsets <- c()
if (length(starting_points) > 1) {
  for (i in 1:(length(starting_points) - 1)) {
    actual_starting_point <- adjusted_data %>% dplyr::filter(starting_round == starting_points[i + 1]) %>% pull(roundNumber) %>% min()
    offset <- adjusted_data %>% dplyr::filter(roundNumber == actual_starting_point & roundNumber > starting_round) %>% pull(cumulative_portfolio_score) %>% dplyr::last()
    offset <- ifelse(is.na(offset),0,offset)
    offsets <- c(offsets,offset)
    adjusted_data[adjusted_data$starting_round == starting_points[i + 1],]$cumulative_portfolio_score <- adjusted_data[adjusted_data$starting_round == starting_points[i + 1],]$cumulative_portfolio_score + offset
  }
} else {
  adjusted_data$offset <- 0
}

## Printout row-concatenated portfolios for different starting points.
#
kable(combined,digits=3)
tab <- kable(combined, digits=3, format = "simple")   # nice monospace box
writeLines(tab, "output/portfolio_suggestions.csv")   # or cat(tab, file = ...)

## Plot models
#
ggplot(adjusted_data) + 
  geom_line(aes(x=roundNumber,y=cumulative_portfolio_score+0*offset,color=as.factor(starting_round)),linewidth=1,alpha=0.7) +
  labs(color = "starting round") + ylab("cumulative portfolio score") + 
  ggtitle("Cumulative performance of ensembles of models predating the indicated starting round")
ggsave("output/portfolio-performances-05corr-2mmc.png",scale=0.5,width=20,height=15)

