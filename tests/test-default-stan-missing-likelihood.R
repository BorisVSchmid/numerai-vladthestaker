# Requires the compiled Stan executable. Compare its augmented missing-data
# likelihood with the exact joint Gaussian density on a small cohort fixture.
source("tests/test-default-rule-analysis.R")
cmdstan <- cmdstanr::cmdstan_path()
Sys.setenv(PATH=paste(file.path(cmdstan,"stan/lib/stan_math/lib/tbb"),
  "C:/rtools45/x86_64-w64-mingw32.static.posix/bin",Sys.getenv("PATH"),sep=.Platform$path.sep))
d <- with_gap$data
d$missing_row <- array(d$missing_row)
d$missing_model <- array(d$missing_model)
Omega <- matrix(.25,d$M,d$M);diag(Omega)<-1
params <- list(alpha=rep(0,d$M),beta_mean=0,beta_sd=.3,beta_raw=rep(0,d$M),
  sigma=rep(1,d$M),L_Omega=t(chol(Omega)),phi=.7,persistent=.6)
folder <- tempfile("d57-likelihood-")
dir.create(folder)
cmdstanr::write_stan_json(d,file.path(folder,"data.json"))
values <- numeric(2)
for(i in 1:2) {
  params$missing_residual <- array(c(.2,1.2)[i])
  cmdstanr::write_stan_json(params,file.path(folder,"params.json"))
  status <- system2("stan/default-rule-inclusion.exe",c("log_prob",
    paste0("constrained_params=",shQuote(file.path(folder,"params.json"))),"jacobian=0",
    "data",paste0("file=",shQuote(file.path(folder,"data.json"))),
    "output",paste0("file=",shQuote(file.path(folder,"logprob.csv"))),"sig_figs=16"),
    stdout=file.path(folder,"run.log"),stderr=file.path(folder,"error.log"))
  if(status!=0)stop(paste(readLines(file.path(folder,"error.log")),collapse="\n"))
  values[i] <- read.csv(file.path(folder,"logprob.csv"),comment.char="#")$lp__[1]
}
temporal <- .6*.7^abs(outer(with_gap$rounds,with_gap$rounds,"-"))+.4*diag(d$N)
covariance <- kronecker(temporal,Omega)
active <- vapply(with_gap$scale$start_index,function(s)seq_len(d$N)>=s,logical(d$N))
keep <- as.vector(t(active))
Ch <- t(chol(covariance[keep,keep]))
r1 <- d$y;r2 <- d$y
r1[d$missing_row,d$missing_model] <- .2
r2[d$missing_row,d$missing_model] <- 1.2
v1 <- as.vector(t(r1))[keep];v2 <- as.vector(t(r2))[keep]
expected <- -.5*(sum(forwardsolve(Ch,v2)^2)-sum(forwardsolve(Ch,v1)^2))
stopifnot(abs(diff(values)-expected)<1e-8)
cat("Stan missing-residual likelihood matches exact correlated Gaussian density.\n")
