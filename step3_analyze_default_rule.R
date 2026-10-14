########
# Step 3: assess EW(pos) D60+|W9 for the account and its models.
#
# Built on R 4.5.2. Requires cmdstanr and a configured CmdStan toolchain.
#
# Inputs:
# - parameters.csv, Optimize-Me.xlsx, and Step 1 D60 scores in output/scores/.
# - stan/default-rule-inclusion.stan.
#
# Workflow:
# - Pair the mean of D60(t-64) through D60(t-72) with D60(t).
# - Fit the pooled or unpooled Stan inclusion model.
# - Summarize positive accuracy when included and account EW(pos) versus EW(all).
# - Check the fit and draw the annotated account/inclusion posterior figure.
#
# Outputs:
# - Supporting data, chain files, and diagnostics in output/stan/.
#   Unpooled sensitivity results go in output/stan/unpooled/.
# - output/step3_inclusion-posteriors.png.
#
# Usage:
# Rscript.exe --vanilla step3_analyze_default_rule.R [OUTPUT_DIR] [pooled|unpooled]
#
# This retrospective assessment is advisory; it does not change live weights.
########

# -------------------- Project location and libraries --------------------
script_argument <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
if (length(script_argument) == 1L) {
  script_path <- normalizePath(sub("^--file=", "", script_argument), mustWork = TRUE)
  setwd(dirname(script_path))
}

if (!requireNamespace("cmdstanr", quietly = TRUE)) {
  stop(
    "Step 3 requires cmdstanr and a configured CmdStan toolchain.",
    call. = FALSE
  )
}

if (!requireNamespace("groundhog", quietly = TRUE)) install.packages("groundhog")
suppressPackageStartupMessages(library(groundhog))
groundhog.library("readxl", "2025-06-01")

source(file.path("R", "functions-config.R"))
source(file.path("R", "functions-score-storage.R"))
source(file.path("R", "functions-hyperparam-runtime.R"))
source(file.path("R", "functions-inputs.R"))


# -------------------- Account comparison helpers --------------------
# Exclude leading/trailing inactivity and unavailable initial/final windows.
# Interior gaps remain evaluation rounds with zero non-submission outcomes.
default_rule_active_rows <- function(signal, outcome) {
  span <- function(observed) {
    indices <- which(observed)
    if(!length(indices)) return(rep(FALSE,length(observed)))
    seq_along(observed)>=min(indices) & seq_along(observed)<=max(indices)
  }
  span(rowSums(is.finite(signal))>0L) & span(rowSums(is.finite(outcome))>0L)
}

default_rule_portfolio_score <- function(outcome, selected) {
  if(!any(selected)) return(0)
  values <- outcome[selected]
  values[!is.finite(values)] <- 0
  mean(values)
}

# Eligibility follows the signal, never the availability of a future outcome.
default_rule_rosters <- function(signal) {
  complete <- is.finite(signal)
  list(all=complete, positive=complete & signal>0, negative=complete & signal<0)
}


default_rule_account_comparison <- function(signal, outcome, rounds) {
  stopifnot(identical(dim(signal),dim(outcome)),length(rounds)==nrow(signal))
  active <- default_rule_active_rows(signal,outcome)
  result <- data.frame(eval_round=rounds,positive_models=0L,negative_models=0L,
    all_models=0L,ew_positive=NA_real_,ew_negative=NA_real_,ew_all=NA_real_)
  for(i in seq_len(nrow(signal))) {
    roster <- default_rule_rosters(signal[i,])
    result$positive_models[i] <- sum(roster$positive)
    result$negative_models[i] <- sum(roster$negative)
    result$all_models[i] <- sum(roster$all)
    if(!active[i]) next
    result$ew_positive[i] <- default_rule_portfolio_score(outcome[i,],roster$positive)
    result$ew_negative[i] <- default_rule_portfolio_score(outcome[i,],roster$negative)
    result$ew_all[i] <- default_rule_portfolio_score(outcome[i,],roster$all)
  }
  result$compare_positive <- is.finite(result$ew_positive) & is.finite(result$ew_all)
  result$compare_negative <- is.finite(result$ew_negative) & is.finite(result$ew_all)
  result
}


# -------------------- Data preparation helpers --------------------
# Offline advisory helpers. No changes to runtime inclusion or live weights.
prepare_default_rule_analysis <- function(panel, contract) {
  source_rows <- match(panel$outcome$roundNumber-contract$source_round_lag,
                       panel$signal$roundNumber)
  raw_x <- as.matrix(panel$signal[panel$models])[source_rows,,drop=FALSE]
  raw_y <- as.matrix(panel$outcome[panel$models])
  paired <- is.finite(raw_x) & is.finite(raw_y)
  eligible <- vapply(seq_along(panel$models),function(j) {
    v <- raw_y[paired[,j],j]
    length(v)>=3L && sd(v)>1e-12
  },logical(1))
  counts <- do.call(rbind,lapply(seq_along(panel$models),function(j) {
    x<-raw_x[paired[,j],j]; y<-raw_y[paired[,j],j]
    pos<-x>0; nonpos<-x<=0
    avg<-function(v) if(length(v)) mean(v) else NA_real_
    data.frame(model=panel$models[j],portfolio_included=panel$portfolio_included[j],
      pairs=length(x),pairs_positive=sum(pos),
      pairs_nonpositive=sum(nonpos),same_sign=sum((x>0&y>0)|(x<0&y<0)),
      opposite_sign=sum(x*y<0),zero_sign_pairs=sum(x==0|y==0),
      observed_positive_outcome_given_positive=avg(y[pos]>0),
      observed_positive_outcome_given_nonpositive=avg(y[nonpos]>0),
      always_positive_accuracy=avg(y>0),
      inclusion_sign_accuracy=avg(pos==(y>0)),
      observed_mean_positive=avg(y[pos]),observed_mean_nonpositive=avg(y[nonpos]),
      status=if(!eligible[j]) "insufficient paired outcome variation" else if(!any(pos)||!any(nonpos))
        "one signal sign only; contrast borrowed from prior/pooling" else "both inclusion states observed")
  }))
  if(!any(eligible)) stop("No model has at least three finite pairs with varying D60 outcomes.",call.=FALSE)
  observed<-paired[,eligible,drop=FALSE]
  rows<-which(rowSums(observed)>0L); observed<-observed[rows,,drop=FALSE]
  starts<-apply(observed,2,function(x)min(which(x)))
  order<-order(starts,colnames(observed)); starts<-starts[order]
  models<-colnames(observed)[order]; observed<-observed[,order,drop=FALSE]
  # Start cohorts retain the efficient exact likelihood. Gaps after each start
  # are integrated via latent residuals, never treated as observed zero scores.
  active<-vapply(starts,function(s)seq_len(nrow(observed))>=s,logical(nrow(observed)))
  missing<-which(active & !observed,arr.ind=TRUE)
  x<-raw_x[rows,models,drop=FALSE]; y<-raw_y[rows,models,drop=FALSE]
  groups<-sort(unique(starts)); M<-length(models); N<-length(rows)
  scale<-data.frame(model=models,start_index=as.integer(starts),y_center=0,y_scale=1,positive_fraction=0)
  include<-matrix(0L,N,M)
  for(j in seq_len(M)) {
    keep<-observed[,j]
    scale$y_center[j]<-mean(y[keep,j]); scale$y_scale[j]<-sd(y[keep,j])
    include[keep,j]<-as.integer(x[keep,j]>0)
    scale$positive_fraction[j]<-mean(include[keep,j])
    y[keep,j]<-(y[keep,j]-scale$y_center[j])/scale$y_scale[j]
  }
  y[!observed]<-0
  rounds<-panel$outcome$roundNumber[rows]
  data<-list(N=N,M=M,G=length(groups),
    group_first=as.integer(match(groups,starts)),
    group_last=as.integer(vapply(groups,function(g)max(which(starts==g)),integer(1))),
    group_start=as.integer(groups),gap=c(0L,as.integer(diff(rounds))),
    include_model=include,positive_fraction=scale$positive_fraction,y=y,
    y_center=scale$y_center,y_scale=scale$y_scale,pooling=1L,
    H=nrow(missing),missing_row=as.integer(missing[,1]),missing_model=as.integer(missing[,2]))
  # Model diagnostics retain the full panel. Account rosters and active rounds
  # use only models permitted by the workbook's Include? column.
  availability<-default_rule_account_comparison(
    raw_x[,panel$portfolio_included,drop=FALSE],
    raw_y[,panel$portfolio_included,drop=FALSE],panel$outcome$roundNumber)
  account<-availability[availability$compare_positive,
    c("eval_round","positive_models","negative_models","all_models","ew_positive","ew_all"),drop=FALSE]
  account$difference<-account$ew_positive-account$ew_all
  list(contract=contract,data=data,scale=scale,counts=counts,rounds=rounds,observed=observed,
    raw_x=raw_x,raw_y=raw_y,portfolio_included=panel$portfolio_included,
    panel_rounds=panel$outcome$roundNumber,account=account,
    account_availability=availability)
}


# -------------------- Account posterior helpers --------------------
# Posterior contributions use the replay denominators. Unobserved outcomes
# contribute zero, including when the entire portfolio did not submit.
default_rule_account_posterior_weights <- function(prepared) {
  coefficients <- matrix(0,nrow(prepared$scale),3L)
  account_rows <- integer()
  indices <- match(prepared$scale$model,colnames(prepared$raw_x))
  for(t in prepared$account$eval_round) {
    row <- match(t,prepared$panel_rounds); x <- prepared$raw_x[row,]
    x[!prepared$portfolio_included] <- NA_real_
    roster <- default_rule_rosters(x)
    positive_n <- sum(roster$positive); all_n <- sum(roster$all)
    observed <- roster$all & is.finite(prepared$raw_y[row,])
    if(!all(colnames(prepared$raw_x)[observed] %in% prepared$scale$model)) next
    inc <- observed[indices] & x[indices]>0
    exc <- observed[indices] & x[indices]<=0
    if(positive_n>0L) coefficients[,1] <- coefficients[,1]+inc/positive_n
    if(all_n>0L) {
      coefficients[,2] <- coefficients[,2]+inc/all_n
      coefficients[,3] <- coefficients[,3]+exc/all_n
    }
    account_rows <- c(account_rows,t)
  }
  if(length(account_rows)) coefficients <- coefficients/length(account_rows)
  list(coefficients=coefficients,rounds=account_rows)
}

default_rule_account_expected_scores <- function(positive, nonpositive, posterior_weights) {
  stopifnot(identical(dim(positive),dim(nonpositive)),
    ncol(positive)==nrow(posterior_weights$coefficients))
  result <- matrix(NA_real_,nrow(positive),3L,
    dimnames=list(NULL,c("ew_positive","ew_all","difference")))
  if(length(posterior_weights$rounds)) {
    w <- posterior_weights$coefficients
    result[,"ew_positive"] <- as.numeric(positive %*% w[,1])
    result[,"ew_all"] <- as.numeric(positive %*% w[,2]+nonpositive %*% w[,3])
    result[,"difference"] <- result[,"ew_positive"]-result[,"ew_all"]
  }
  result
}

summarize_default_rule_account_scores <- function(prepared, posterior_weights, account_scores) {
  common <- prepared$account
  account_rows <- posterior_weights$rounds
  supported_rows <- match(account_rows, common$eval_round)
  stopifnot(!anyNA(supported_rows), !anyDuplicated(account_rows),
    is.matrix(account_scores),
    identical(colnames(account_scores), c("ew_positive", "ew_all", "difference")))
  supported <- common[supported_rows, , drop = FALSE]
  if (nrow(supported)) stopifnot(all(is.finite(account_scores)))
  else stopifnot(all(is.na(account_scores)))
  observed_mean <- function(rows, column) {
    if (nrow(rows)) mean(rows[[column]]) else NA_real_
  }
  delta <- account_scores[, "difference"]
  summary <- data.frame(
    common_rounds = nrow(common), posterior_roster_rounds = nrow(supported),
    observed_ew_positive = observed_mean(common, "ew_positive"),
    observed_ew_all = observed_mean(common, "ew_all"),
    observed_difference = observed_mean(common, "difference"),
    observed_supported_ew_positive = observed_mean(supported, "ew_positive"),
    observed_supported_ew_all = observed_mean(supported, "ew_all"),
    observed_supported_difference = observed_mean(supported, "difference"),
    expected_difference_median = if (nrow(supported)) median(delta) else NA_real_,
    expected_difference_lower90 = if (nrow(supported)) quantile(delta, .05) else NA_real_,
    expected_difference_upper90 = if (nrow(supported)) quantile(delta, .95) else NA_real_,
    evidence = if (nrow(common) >= 25L) "sufficient_history" else "limited_history_under_25_rounds",
    probability_ew_positive_better = if (nrow(supported)) mean(delta > 0) else NA_real_
  )
  scores <- data.frame(
    portfolio = c("EW(pos)", "EW(all)", "EW(pos) - EW(all)"),
    observed = c(summary$observed_ew_positive, summary$observed_ew_all, summary$observed_difference),
    observed_supported = c(summary$observed_supported_ew_positive,
      summary$observed_supported_ew_all, summary$observed_supported_difference),
    expected_mean = NA_real_, expected_lower90 = NA_real_, expected_upper90 = NA_real_,
    observed_rounds = nrow(common), posterior_rounds = nrow(supported)
  )
  if (nrow(supported)) for (j in seq_len(ncol(account_scores))) {
    scores$expected_mean[j] <- mean(account_scores[, j])
    scores$expected_lower90[j] <- quantile(account_scores[, j], .05)
    scores$expected_upper90[j] <- quantile(account_scores[, j], .95)
  }
  list(summary = summary, scores = scores)
}


# -------------------- Posterior predictive checks --------------------
check_default_rule_inclusion <- function(prepared,fit,out) {
  d<-prepared$data; scale<-prepared$scale
  draws<-fit$draws(c("alpha","beta","sigma","phi","persistent","L_Omega"),format="matrix")
  set.seed(57064); chosen<-sample.int(nrow(draws),400)
  lags<-c(1,2,5,10,20)
  rate<-array(NA_real_,c(400,d$M,2)); acf_rep<-acf_obs<-array(NA_real_,c(400,d$M,5))
  innovations<-function(e,gap,phi,p) {
    state<-0; variance<-p; z<-numeric(length(e))
    for(n in seq_along(e)) {
      if(n>1) {a<-phi^gap[n];state<-a*state;variance<-a*a*variance+p*(1-a*a)}
      S<-variance+1-p; v<-e[n]-state;z[n]<-v/sqrt(S)
      gain<-variance/S;state<-state+gain*v;variance<-variance*(1-gain)
    };z
  }
  acf<-function(z,lag)if(length(z)>lag+2)cor(head(z,-lag),tail(z,-lag)) else NA_real_
  for(i in seq_along(chosen)) {
    p<-setNames(as.numeric(draws[chosen[i],]),colnames(draws))
    vec<-function(n)unname(p[paste0(n,"[",seq_len(d$M),"]")])
    alpha<-vec("alpha");beta<-vec("beta");sigma<-vec("sigma")
    L<-matrix(0,d$M,d$M)
    for(j in 1:d$M)for(k in 1:j)L[j,k]<-sigma[j]*p[paste0("L_Omega[",j,",",k,"]")]
    latent<-matrix(0,d$N,d$M);latent[1,]<-sqrt(p["persistent"])*L%*%rnorm(d$M)
    for(n in 2:d$N) {a<-p["phi"]^d$gap[n];latent[n,]<-a*latent[n-1,]+sqrt(p["persistent"]*(1-a*a))*L%*%rnorm(d$M)}
    error<-latent+sqrt(1-p["persistent"])*matrix(rnorm(d$N*d$M),d$N,d$M)%*%t(L)
    mu<-sweep(sweep(d$include_model,2,d$positive_fraction,"-"),2,beta,"*")
    mu<-sweep(mu,2,alpha,"+"); yrep<-sweep(sweep(mu+error,2,d$y_scale,"*"),2,d$y_center,"+")
    for(j in 1:d$M) {
      rows<-which(prepared$observed[,j])
      for(g in 0:1) {
        keep<-rows[d$include_model[rows,j]==g]
        if(length(keep))rate[i,j,g+1]<-mean(yrep[keep,j]>0)
      }
      observed_gaps<-c(0L,diff(prepared$rounds[rows]))
      z<-innovations((d$y[rows,j]-mu[rows,j])/sigma[j],observed_gaps,p["phi"],p["persistent"])
      zr<-innovations(error[rows,j]/sigma[j],observed_gaps,p["phi"],p["persistent"])
      for(k in seq_along(lags)) {acf_obs[i,j,k]<-acf(z,lags[k]);acf_rep[i,j,k]<-acf(zr,lags[k])}
    }
  }
  results<-list()
  for(j in 1:d$M) {
    obs<-prepared$counts[match(scale$model[j],prepared$counts$model),]
    for(g in 0:1) if(any(is.finite(rate[,j,g+1]))) {
      value<-if(g==1)obs$observed_positive_outcome_given_positive else obs$observed_positive_outcome_given_nonpositive
      results[[length(results)+1]]<-data.frame(model=scale$model[j],check=paste0("positive_rate_when_",g),
        observed=value,rep_lower=quantile(rate[,j,g+1],.025),rep_upper=quantile(rate[,j,g+1],.975))
    }
    for(k in seq_along(lags)) if(any(is.finite(acf_obs[,j,k])))
      results[[length(results)+1]]<-data.frame(model=scale$model[j],check=paste0("innovation_acf_",lags[k]),
        observed=median(acf_obs[,j,k],na.rm=TRUE),rep_lower=quantile(acf_rep[,j,k],.025,na.rm=TRUE),rep_upper=quantile(acf_rep[,j,k],.975,na.rm=TRUE))
  }
  checks<-do.call(rbind,results); checks$outside<-with(checks,observed<rep_lower|observed>rep_upper)
  write.csv(checks,file.path(out,"posterior-predictive-checks.csv"),row.names=FALSE)
  rate_check<-grepl("positive_rate",checks$check)
  list(rate_failures=sum(checks$outside[rate_check]),rate_checks=sum(rate_check),
       acf_failures=sum(checks$outside[!rate_check]),acf_checks=sum(!rate_check))
}


# -------------------- Figure helpers --------------------
# The joint outcome model supplies conditional positive probabilities. Do not
# present prior/pooling-only positive accuracy as evidence for never-included models.
default_rule_positive_accuracy_posteriors <- function(accuracy, overall_positive_rate, positive_pairs) {
  accuracy<-as.matrix(accuracy); overall_positive_rate<-as.matrix(overall_positive_rate)
  stopifnot(identical(dim(accuracy),dim(overall_positive_rate)),
    length(positive_pairs)==ncol(accuracy),
    all(is.finite(accuracy)),all(is.finite(overall_positive_rate)),
    all(accuracy>=0&accuracy<=1),all(overall_positive_rate>=0&overall_positive_rate<=1),
    all(is.finite(positive_pairs)),all(positive_pairs>=0&positive_pairs==floor(positive_pairs)))
  accuracy[,positive_pairs==0]<-NA_real_
  list(positive_accuracy=accuracy,overall_positive_rate=overall_positive_rate)
}

summarize_default_rule_positive_accuracy <- function(prepared, posteriors) {
  result <- prepared$counts
  result$overall_positive_rate <- result$always_positive_accuracy
  columns <- c("positive_accuracy_median", "positive_accuracy_lower90", "positive_accuracy_upper90",
    "probability_positive_accuracy_above_half", "probability_beats_overall_positive_rate")
  for (column in columns) result[[column]] <- NA_real_
  result$positive_accuracy_status <- ifelse(result$pairs_positive == 0,
    "no included paired rounds", "insufficient paired outcome variation")
  stopifnot(ncol(posteriors$positive_accuracy) == nrow(prepared$scale))
  for (j in seq_len(nrow(prepared$scale))) {
    i <- match(prepared$scale$model[j], result$model)
    if (result$pairs_positive[i] == 0) next
    accuracy <- posteriors$positive_accuracy[,j]
    baseline <- posteriors$overall_positive_rate[,j]
    stopifnot(all(is.finite(accuracy)), all(is.finite(baseline)))
    result[i,columns] <- list(median(accuracy), quantile(accuracy,.05), quantile(accuracy,.95),
      mean(accuracy > .5), mean(accuracy > baseline))
    result$positive_accuracy_status[i] <- "estimated"
  }
  result
}

# Main Step3 figure: expected EW(pos) score, account contrast, and model accuracy.
# Print observed accuracy, pair count, and positive-signal inclusion frequency.
plot_default_account_and_models <- function(prepared,result,accuracy,account_scores,account_summary,out,mode) {
  stopifnot(is.matrix(account_scores),
    identical(colnames(account_scores),c("ew_positive","ew_all","difference")))
  account_delta<-account_scores[,"difference"]
  model_labels <- ifelse(result$portfolio_included, result$model,
    paste0(result$model, " [excluded]"))
  account_caption <- paste0(mode, " Stan fit; ", account_summary$posterior_roster_rounds,
    " posterior-supported / ", account_summary$common_rounds, " common replay rounds.",
    if (account_summary$common_rounds < 25L) " Limited history (<25 common rounds)." else "",
    if (account_summary$posterior_roster_rounds < 25L && account_summary$common_rounds >= 25L)
      " Limited posterior support (<25 rounds)." else "")
  included_labels<-ifelse(result$pairs>0,
    sprintf("%d/%d (%.0f%%)",result$pairs_positive,result$pairs,100*result$pairs_positive/result$pairs),
    "0/0 (--)")
  index<-match(prepared$scale$model,result$model)
  supported<-which(result$pairs_positive[index]>0)
  order<-supported[order(result$observed_positive_outcome_given_positive[index[supported]],decreasing=TRUE)]
  missing<-which(!seq_len(nrow(result)) %in% index[order])
  n<-length(order)+length(missing)
  panel_height<-max(950,290+64*n)
  png(file.path(out,"inclusion-posteriors.png"),width=2600,height=940+panel_height,res=160)
  on.exit(dev.off(),add=TRUE)
  layout(matrix(1:3,nrow=3),heights=c(420,480,panel_height))
  par(cex=1,mex=1)
  split_density<-function(d,cutoff,base=0,height=1) {
    y<-height*d$y/max(d$y)
    for(above in c(FALSE,TRUE)) {
      keep<-if(above)d$x>=cutoff else d$x<=cutoff
      x<-d$x[keep];v<-y[keep]
      if(!length(x))next
      at_cut<-approx(d$x,y,xout=cutoff)$y
      if(is.finite(at_cut)) {
        if(above){x<-c(cutoff,x);v<-c(at_cut,v)}else{x<-c(x,cutoff);v<-c(v,at_cut)}
      }
      polygon(c(x,rev(x)),c(base+v,rep(base,length(x))),border=NA,
        col=adjustcolor(if(above)"#2171B5" else "#D95F02",alpha.f=.65))
    }
    lines(d$x,base+y,col="#444444",lwd=1.1)
  }
  positive_scores<-account_scores[,"ew_positive"]
  positive_scores<-positive_scores[is.finite(positive_scores)]
  positive_density<-if(length(unique(positive_scores))>1)
    density(positive_scores,n=1024) else NULL
  observed_positive<-account_summary$observed_supported_ew_positive
  positive_limits<-range(c(0,positive_scores,
    observed_positive[is.finite(observed_positive)],
    if(!is.null(positive_density))positive_density$x))
  padding<-max(.005,diff(positive_limits)*.05)
  positive_limits<-positive_limits+c(-padding,padding)
  par(mar=c(4.4,14,4.8,17),las=1,xaxs="i")
  plot(NA,xlim=positive_limits,ylim=c(-.12,1.4),yaxt="n",xlab="",ylab="",bty="n")
  segments(positive_limits[1],0,positive_limits[2],0,col="#DDDDDD")
  if(!is.null(positive_density)) {
    split_density(positive_density,0)
  } else if(length(positive_scores)) {
    segments(positive_scores[1],0,positive_scores[1],1,col="#2171B5",lwd=2)
  } else text(mean(positive_limits),.45,"Insufficient data for account posterior",col="#777777")
  abline(v=0,lty=2,col="#777777")
  if(is.finite(observed_positive))points(observed_positive,.035,pch=19,cex=.9,xpd=NA)
  tab<-positive_limits[2]+c(.14,1.18)*diff(par("usr")[1:2])/par("pin")[1]
  text(tab,1.15,c("Expected","90% interval"),adj=0,xpd=NA,font=2,cex=.86)
  text(tab,.77,if(length(positive_scores))
    c(sprintf("%+.4f",mean(positive_scores)),
      sprintf("%+.4f to %+.4f",quantile(positive_scores,.05),quantile(positive_scores,.95))) else
    c("--","--"),adj=0,xpd=NA,cex=.9)
  title("ACCOUNT  |  Expected performance of EW(pos)",line=2.7,cex.main=1.1,adj=0)
  mtext(account_caption,
    side=3,line=1.2,cex=.8,adj=0)
  mtext("Expected historical mean D60 score (3 x CORR + 15 x MMC)",side=1,line=2.5,cex=.85)

  par(mar=c(4.4,14,4.8,17),las=1,xaxs="i")
  plot(NA,xlim=c(-.05,.05),ylim=c(-.12,1.4),xaxt="n",yaxt="n",xlab="",ylab="",bty="n")
  tab<-.05+c(.14,1.18)*diff(par("usr")[1:2])/par("pin")[1]
  segments(-.05,0,.05,0,col="#DDDDDD")
  if(length(account_delta)>1 && all(is.finite(account_delta))) {
    split_density(density(account_delta,from=-.05,to=.05,n=1024),0)
  } else text(0,.45,"Insufficient data for account posterior",col="#777777")
  abline(v=0,lty=2,col="#777777")
  if(is.finite(account_summary$observed_supported_difference)) {
    observed<-account_summary$observed_supported_difference
    if(observed>=-.05 && observed<=.05) {
      segments(observed,0,observed,1.02,lty=3,col="#333333")
      points(observed,.035,pch=19,cex=.9)
    } else arrows(sign(observed)*.046,.035,sign(observed)*.05,.035,length=.09,lwd=1.5)
  }
  axis(1,at=seq(-.05,.05,.01),labels=sprintf("%+.2f",seq(-.05,.05,.01)))
  text(tab,1.15,c("Observed*","Rounds*"),adj=0,xpd=NA,font=2,cex=.86)
  text(tab,.77,c(if(is.finite(account_summary$observed_supported_difference))sprintf("%+.4f",account_summary$observed_supported_difference)else"--",
                 account_summary$posterior_roster_rounds),adj=0,xpd=NA,cex=1)
  title("ACCOUNT  |  Does EW(positive D60+|W9 signal) beat EW(all)?",line=2.7,cex.main=1.1,adj=0)
  mtext(account_caption,
    side=3,line=1.2,cex=.8,adj=0)
  mtext("Expected D60 score difference: EW(pos) minus EW(all)",side=1,line=2.5,cex=.85)
  mtext("* Observed markers and counts use the posterior-supported rounds.",
    side=1,line=3.5,cex=.7)

  par(mar=c(6.8,14,4.6,17),las=1,xaxs="i")
  plot(NA,xlim=c(0,1),ylim=c(.45,n+1),xaxt="n",yaxt="n",xlab="",ylab="",bty="n")
  tab<-1+c(.14,1.18,1.98)*diff(par("usr")[1:2])/par("pin")[1]
  segments(.5,length(missing)+.7,.5,n+.7,lty=2,col="#777777",lwd=1.3)
  for(i in seq_along(order)) {
    j<-order[i];r<-result[index[j],];row<-n-i+1
    segments(0,row,1,row,col="#DDDDDD")
    split_density(density(accuracy[,j],from=0,to=1,n=1024),.5,row,.68)
    points(r$observed_positive_outcome_given_positive,row+.04,pch=19,cex=.8,xpd=NA)
    points(r$overall_positive_rate,row+.04,pch=2,cex=.85,col="black",xpd=NA)
    text(-.013,row+.22,model_labels[index[j]],adj=1,xpd=NA,cex=.84)
    text(tab[1],row+.22,sprintf("%.1f%%",100*r$observed_positive_outcome_given_positive),adj=0,xpd=NA,cex=.9,
      col=if(r$observed_positive_outcome_given_positive<.5)"#B84F00" else "#222222")
    text(tab[2],row+.22,r$pairs,adj=0,xpd=NA,cex=.9)
    text(tab[3],row+.22,included_labels[index[j]],adj=0,xpd=NA,cex=.9)
  }
  for(i in seq_along(missing)) {
    r<-result[missing[i],];row<-length(missing)-i+1
    segments(0,row,1,row,col="#EEEEEE")
    text(-.013,row+.22,model_labels[missing[i]],adj=1,xpd=NA,cex=.84,col="#888888")
    text(.5,row+.22,if(r$pairs==0)"No valid pairs" else if(r$pairs_positive==0)"No included paired rounds" else "Insufficient outcome variation",cex=.83,col="#888888")
    text(tab[1],row+.22,if(is.finite(r$observed_positive_outcome_given_positive))sprintf("%.1f%%",100*r$observed_positive_outcome_given_positive)else"--",adj=0,xpd=NA,cex=.9,col="#888888")
    text(tab[2],row+.22,r$pairs,adj=0,xpd=NA,cex=.9,col="#888888")
    text(tab[3],row+.22,included_labels[missing[i]],adj=0,xpd=NA,cex=.9,col="#888888")
  }
  axis(1,at=seq(0,1,.1),labels=paste0(seq(0,100,10),"%"))
  text(tab,n+.8,c("Observed","Pairs","rounds included?"),adj=0,xpd=NA,font=2,cex=.86)
  title("MODELS  |  When included, does D60 finish positive?",line=2.7,cex.main=1.1,adj=0)
  mtext("Positive D60 outcomes / included paired rounds",side=1,line=2.1,cex=.9)
  mtext("Dot: observed. Curve: posterior. Triangle: overall D60-positive rate.",side=1,line=3.7,cex=.73)
  mtext("[excluded]: Include? = No; omitted from both account portfolios.",side=1,line=5,cex=.73)
}

# -------------------- Output publication helpers --------------------
publish_step3_figure <- function(diagnostic_dir, output_dir) {
  source_path <- file.path(diagnostic_dir,"inclusion-posteriors.png")
  if(!file.exists(source_path) || file.info(source_path)$size<=0)
    stop("Step3 must finish the inclusion figure before publishing it.",call.=FALSE)
  dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
  stage <- tempfile(".step3-figure-",tmpdir=output_dir)
  dir.create(stage)
  on.exit(unlink(stage,recursive=TRUE),add=TRUE)
  staged <- file.path(stage,"inclusion-posteriors.png")
  if(!file.copy(source_path,staged)) stop("Could not stage the Step3 figure.",call.=FALSE)
  destination <- file.path(output_dir,"step3_inclusion-posteriors.png")
  publish_staged_files(staged,destination)
  invisible(destination)
}


# -------------------- Step 3 settings and output paths --------------------
args <- commandArgs(trailingOnly = TRUE)
if (length(args) > 2L) {
  stop(
    "Usage: Rscript step3_analyze_default_rule.R [OUTPUT_DIR] [pooled|unpooled]",
    call. = FALSE
  )
}
output_dir <- if (length(args)) args[[1L]] else "output"
mode <- if (length(args) > 1L) args[[2L]] else "pooled"
if (!mode %in% c("pooled", "unpooled")) {
  stop("Step 3 mode must be pooled or unpooled.", call. = FALSE)
}
stan_output_dir <- if (mode == "pooled") file.path(output_dir, "stan") else
  file.path(output_dir, "stan", "unpooled")

stan_seed <- 20260927
stan_chains <- 4
stan_parallel_chains <- 4
stan_warmup <- 1000
stan_samples <- 1000
stan_adapt_delta <- 0.97
stan_max_treedepth <- 12


# -------------------- Read scores and prepare the analysis --------------------
message("Step3: preparing D60+|W9 signals and subsequent D60 outcomes...")
params <- read_pipeline_parameters("parameters.csv")
inputs <- check_pipeline_inputs(3L, params, output_dir)
contract <- inputs$contract
panel <- inputs$panel
prepared <- prepare_default_rule_analysis(panel, contract)
prepared$data$pooling <- as.integer(mode == "pooled")

dir.create(stan_output_dir, recursive = TRUE, showWarnings = FALSE)
saveRDS(prepared, file.path(stan_output_dir, "prepared.rds"))
write.csv(
  prepared$counts,
  file.path(stan_output_dir, "observed-models.csv"),
  row.names = FALSE
)
write.csv(
  prepared$account,
  file.path(stan_output_dir, "account-paired-rounds.csv"),
  row.names = FALSE
)


# -------------------- Compile and fit the Stan model --------------------
cpp_options <- list()
rtools <- "C:/rtools45/x86_64-w64-mingw32.static.posix/bin"
if (.Platform$OS.type == "windows" && file.exists(file.path(rtools, "g++.exe"))) {
  cpp_options <- list(
    CXX = paste(file.path(rtools, "g++.exe"), paste0("-B", rtools, "/")),
    SHELL = "C:/rtools45/usr/bin/sh.exe",
    IS_UCRT = "true"
  )
}

message("Step3: fitting the ", mode, " Stan inclusion model...")
model <- cmdstanr::cmdstan_model(
  "stan/default-rule-inclusion.stan",
  cpp_options = cpp_options
)
fit <- model$sample(
  data = prepared$data,
  # seed = stan_seed,
  chains = stan_chains,
  parallel_chains = stan_parallel_chains,
  iter_warmup = stan_warmup,
  iter_sampling = stan_samples,
  adapt_delta = stan_adapt_delta,
  max_treedepth = stan_max_treedepth,
  init = 0.1,
  refresh = 100,
  output_dir = stan_output_dir
)
writeLines(fit$output_files(), file.path(stan_output_dir, "chain-files.txt"))


# -------------------- Check sampler convergence --------------------
diagnostics <- fit$diagnostic_summary()
parameters <- as.data.frame(fit$summary())
write.csv(
  diagnostics,
  file.path(stan_output_dir, "sampler-diagnostics.csv"),
  row.names = FALSE
)
write.csv(
  parameters,
  file.path(stan_output_dir, "parameter-summary.csv"),
  row.names = FALSE
)
stopifnot(
  all(diagnostics$num_divergent == 0),
  all(diagnostics$num_max_treedepth == 0),
  all(diagnostics$ebfmi > 0.3),
  max(parameters$rhat, na.rm = TRUE) < 1.01
)


# -------------------- Model inclusion and sign posteriors --------------------
message("Step3: summarizing posteriors and drawing the account/model figure...")
variables<-c("mean_d60_positive","mean_d60_nonpositive","mean_difference",
  "positive_accuracy","overall_positive_rate","prob_d60_positive_given_nonpositive")
draws<-fit$draws(variables,format="matrix")
extract<-function(name) as.matrix(draws[,paste0(name,"[",seq_len(prepared$data$M),"]"),drop=FALSE])
delta<-extract("mean_difference"); positive<-extract("mean_d60_positive")
nonpositive<-extract("mean_d60_nonpositive")
ppos<-extract("positive_accuracy"); pnon<-extract("prob_d60_positive_given_nonpositive")
positive_pairs<-prepared$counts$pairs_positive[match(prepared$scale$model,prepared$counts$model)]
sign_posteriors<-default_rule_positive_accuracy_posteriors(ppos,extract("overall_positive_rate"),positive_pairs)
accuracy<-sign_posteriors$positive_accuracy
result<-summarize_default_rule_positive_accuracy(prepared,sign_posteriors)
columns<-c("mean_d60_positive","mean_d60_nonpositive","difference_median","difference_lower90",
  "difference_upper90","probability_positive_filter_better","probability_d60_positive_if_included",
  "probability_d60_positive_if_excluded","positive_outcome_probability_difference")
for(column in columns) result[[column]]<-NA_real_
accuracy_columns<-c("positive_accuracy_median","positive_accuracy_lower90","positive_accuracy_upper90",
  "probability_positive_accuracy_above_half","probability_beats_overall_positive_rate")
for(j in seq_len(prepared$data$M)) {
  i<-match(prepared$scale$model[j],result$model)
  result[i,columns]<-list(mean(positive[,j]),mean(nonpositive[,j]),median(delta[,j]),
    quantile(delta[,j],.05),quantile(delta[,j],.95),mean(delta[,j]>0),mean(ppos[,j]),mean(pnon[,j]),mean(ppos[,j]-pnon[,j]))
  if(result$pairs_positive[i]==0) result$probability_d60_positive_if_included[i]<-NA_real_
}
write.csv(result,file.path(stan_output_dir,"model-inclusion-summary.csv"),row.names=FALSE,na="")
write.csv(result[c("model","portfolio_included","pairs","pairs_positive","observed_positive_outcome_given_positive",
  "overall_positive_rate",accuracy_columns,"positive_accuracy_status")],
  file.path(stan_output_dir,"model-sign-accuracy.csv"),row.names=FALSE,na="")
saveRDS(sign_posteriors,file.path(stan_output_dir,"sign-accuracy-draws.rds"))

# -------------------- Account score posteriors --------------------
# Expected account contrast over exactly the observed common rosters. This is
# not an equal average of model slopes, and not a prediction of a new roster.
posterior_weights<-default_rule_account_posterior_weights(prepared)
account_scores<-default_rule_account_expected_scores(positive,nonpositive,posterior_weights)
account_delta<-account_scores[,"difference"]
account_summaries <- summarize_default_rule_account_scores(prepared, posterior_weights, account_scores)
summary <- account_summaries$summary
score_summary <- account_summaries$scores
write.csv(score_summary,file.path(stan_output_dir,"account-scores.csv"),row.names=FALSE,na="")
saveRDS(account_scores,file.path(stan_output_dir,"account-score-draws.rds"))
write.csv(summary,file.path(stan_output_dir,"account-inclusion-summary.csv"),row.names=FALSE,na="")
write.csv(prepared$account_availability,file.path(stan_output_dir,"account-round-availability.csv"),row.names=FALSE)
saveRDS(list(model_difference=delta,account_difference=account_delta),file.path(stan_output_dir,"contrast-draws.rds"))

# -------------------- Predictive checks and figure --------------------
checks<-check_default_rule_inclusion(prepared,fit,stan_output_dir)
write.csv(as.data.frame(checks),file.path(stan_output_dir,"predictive-check-summary.csv"),row.names=FALSE)
plot_default_account_and_models(prepared,result,accuracy,account_scores,summary,stan_output_dir,mode)

# -------------------- Publish summary figure --------------------
figure <- publish_step3_figure(stan_output_dir, output_dir)
message(
  "Step3 complete. Figure: ", figure,
  ". Supporting files: ", stan_output_dir
)
