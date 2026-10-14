source("R/functions-config.R")
source("R/functions-score-storage.R")
source("R/functions-hyperparam-runtime.R")
source("R/functions-fetch.R")
source("tests/load-step-functions.R", local = TRUE)
load_step_functions("step1_get_data.R", constants = "score_event_columns")
load_step_functions("step3_analyze_default_rule.R")
load_step_functions("step4_generate_portfolio_replay_and_weights.R")
# Isolate standalone from every shared helper: it must work with base R plus
# its own functions. The shared pipeline above is only the comparison oracle.
standalone <- new.env(parent = baseenv())
sys.source("step_standalone.R", standalone)
standalone_config <- standalone$standalone_read_config("parameters.csv")
params <- read_pipeline_parameters("parameters.csv")
config <- read_score_profile_config(params)
contract <- default_rule_runtime_contract(params, config)
rounds <- 100:210
models <- paste0("model_",1:11)
panels <- setNames(lapply(names(maturity_score_artifact_names()),function(name) {
  result <- data.frame(roundNumber=rounds)
  for(model in models) result[[model]] <- -999
  result
}),names(maturity_score_artifact_names()))
# D60+ uses only final cells; intermediate panels deliberately contain sentinels.
# The live signal must use exactly 138:146 for target 210, not newer scores.
panels$d60[-1L] <- lapply(seq_along(models),function(j)sin(rounds/7+j)/10)
for(k in 0:8) panels$d60[match(210-64-k,rounds),models] <-
  c(rep(.1+k/1000,8),-.2,0,.8)
panels$d60[match(210-72,rounds),"model_11"] <- NA_real_
signal <- build_default_rule_signal_panel(panels$d60,contract)
latest <- signal[signal$roundNumber==146L,models]
stopifnot(max(abs(as.numeric(latest[1:8])-.104))<1e-12,
  abs(latest[[9]]+.2)<1e-12,latest[[10]]==0,is.na(latest[[11]]))
weights <- format_default_rule_portfolio(build_live_default_rule_weights(signal,contract,210L),"fixture")
# Bayesian inputs must use precisely that mean, at precisely the same target.
prepared <- prepare_default_rule_analysis(list(signal=signal,outcome=panels$d60,models=models,
  portfolio_included=rep(TRUE,length(models))),contract)
row <- match(210L,prepared$panel_rounds)
stopifnot(isTRUE(all.equal(unname(prepared$raw_x[row,]),as.numeric(latest))),
  is.na(prepared$raw_x[row,11]))
folder <- tempfile("progressive-standalone-");dir.create(folder)
archive_dir <- file.path(folder,"output")
output_dir <- file.path(folder,"output_standalone")
archive_paths <- write_maturity_score_panels(panels,archive_dir)
archive_before <- utils::read.csv(archive_paths[["d60"]], check.names = FALSE)
# API omits exact old maturity cells, which must be recovered from the archive.
api <- panels
for(name in names(api)) api[[name]][-1L] <- NA_real_
roster <- data.frame(name=models,start=100L)
run <- function(round_fn=function()210L,builder=function(...)api$d60)
  standalone$standalone_refresh_portfolio(standalone_config,roster,output_dir,archive_dir,round_fn,builder,
    clock_function=function()as.POSIXct("2026-09-27",tz="UTC"))
result <- run()
stopifnot(identical(result$output_path,file.path(output_dir,"portfolio_210.csv")),
  identical(list.files(output_dir),"portfolio_210.csv"))
expected <- weights
expected$generated_at_utc <- result$weights$generated_at_utc
stopifnot(identical(result$weights, expected))
# Archived cells before an updated start cannot complete an otherwise invalid
# window. The independent pipeline masks the same cells at materialization.
later_roster <- roster
later_roster$start[later_roster$name == "model_1"] <- 145L
later <- standalone$standalone_refresh_portfolio(standalone_config, later_roster,
  file.path(folder, "later_start"), archive_dir, function()210L, function(...)api$d60)
stopifnot(!"model_1" %in% later$weights$model, nrow(later$weights) == 7L,
  all(later$weights$weight == 1/7))
# An unavailable current round cannot relabel or discard saved round history.
saved_portfolio <- utils::read.csv(result$output_path, check.names = FALSE)
err <- tryCatch(run(function()stop("API unavailable")),error=conditionMessage)
stopifnot(grepl("API unavailable",err),
  identical(utils::read.csv(result$output_path, check.names = FALSE), saved_portfolio))
# Once the round is known, failed refreshes invalidate only that round's CSV.
err <- tryCatch(run(builder=function(...)stop("Download failed")),error=conditionMessage)
stopifnot(grepl("Download failed",err),!file.exists(result$output_path),
  file.exists(paste0(result$output_path,".last-successful")),
  identical(list.files(output_dir),"portfolio_210.csv.last-successful"))
# A newer API value overrides an archived value at the same exact cell.
api$d60[match(146L,rounds),"model_1"] <- -100
seven <- run()
stopifnot(nrow(seven$weights)==7L,all(seven$weights$weight==1/7),
  !"model_1" %in% seven$weights$model)
api$d60[match(146L,rounds),"model_1"] <- NA_real_
# One positive is sufficient even when the other models are negative or missing.
api$d60[api$d60$roundNumber %in% 138:146,models] <- -1
api$d60[api$d60$roundNumber %in% 138:146,"model_1"] <- .1
one <- run()
stopifnot(nrow(one$weights)==1L,one$weights$model=="model_1",one$weights$weight==1)
# A successful zero-positive decision replaces stale weights with a header-only CSV.
api$d60[api$d60$roundNumber %in% 138:146,models] <- -1
empty <- run()
empty_csv <- utils::read.csv(empty$output_path, check.names = FALSE)
stopifnot(nrow(empty_csv) == 0L,
  identical(names(empty_csv), names(empty$weights)))
api$d60[-1L] <- NA_real_
# New rounds get separate files without changing previous rounds.
restored <- run()
saved_portfolio <- utils::read.csv(restored$output_path, check.names = FALSE)
next_round <- run(function()211L)
stopifnot(identical(basename(next_round$output_path),"portfolio_211.csv"),
  nrow(next_round$weights)>0L, all(next_round$weights$intended_round==211L),
  file.exists(next_round$output_path),
  identical(utils::read.csv(restored$output_path, check.names = FALSE), saved_portfolio))
next_portfolio <- utils::read.csv(next_round$output_path, check.names = FALSE)
# Crossing a round boundary must refuse the portfolio rather than relabel it.
n <- 0L
err <- tryCatch(run(function(){n<<-n+1L;if(n==1L)210L else 211L}),error=conditionMessage)
stopifnot(grepl("stale weights",err),!file.exists(result$output_path),
  identical(utils::read.csv(next_round$output_path, check.names = FALSE), next_portfolio))

# The complete download-to-CSV path needs no R/ files or Step 1 archive.
# Exercise real record parsing with a deterministic public-API fixture.
record <- function(round, metric, value, day=60L, submission=paste0("s",round),
                   date="2026-09-27T00:00:00Z", version="0") {
  list(roundNumber=round,day=day,submissionId=submission,date=date,
       displayName=metric,version=version,value=value)
}
records <- function(metric,value) lapply(138:146,record,metric=metric,value=value)
corr <- records("canon_corr60",.01)
mmc <- records("canon_mmc60",.002)
combine <- function(c=corr,m=mmc)
  standalone$standalone_combine_d60(c,m,standalone_config,138:146)
stopifnot(all(abs(combine()-.06)<1e-12),all(is.na(combine(list(),list()))))
bad <- mmc;bad[[1]]$submissionId <- "different"
stopifnot(is.na(combine(m=bad)[1]))
bad <- mmc;bad[[1]]$date <- "2026-09-28T00:00:00Z"
stopifnot(is.na(combine(m=bad)[1]))
bad <- mmc;bad[[1]]$day <- 59L
stopifnot(is.na(combine(m=bad)[1]))
bad <- mmc;bad[[1]]$value <- NULL
stopifnot(is.na(combine(m=bad)[1]))
expect_error <- function(expression,pattern) {
  error <- tryCatch({force(expression);NA_character_},error=conditionMessage)
  stopifnot(!is.na(error),grepl(pattern,error))
}
# Named rows must fail clearly before exclusions; blank workbook rows are valid.
for (invalid_start in list("oops", NA_real_, Inf, 0, -1, 100.5, 2^31)) {
  bad_roster <- data.frame(name = c("valid", "bad"), start = c(100, invalid_start))
  expect_error(standalone$standalone_prepare_model_df(bad_roster, "bad"),
    "positive integer starting round")
}
expect_error(standalone$standalone_prepare_model_df(
  data.frame(name = c("valid", " VALID "), start = 100), character()), "Duplicate")
clean_roster <- standalone$standalone_prepare_model_df(
  data.frame(name = c(" Valid ", "", NA, "excluded"), start = c(100, NA, NA, 101),
    `Include?` = c(" Yes ", NA, NA, "yes"), check.names = FALSE),
  "excluded")
stopifnot(identical(clean_roster, data.frame(name = "valid", start = 100L)))
expect_error(standalone$standalone_prepare_model_df(
  data.frame(name = "valid", start = 100), character()), "Include\\?")
expect_error(standalone$standalone_prepare_model_df(
  data.frame(name = "valid", start = 100, `Include?` = "maybe", check.names = FALSE),
  character()), "Yes or No")
bad <- mmc;bad[[1]]$version <- "1"
expect_error(combine(m=bad),"metric or version")
expect_error(combine(c=c(corr,corr[1])),"Duplicate")
extra_c <- corr[[1]];extra_m <- mmc[[1]]
extra_c$submissionId <- extra_m$submissionId <- "another-complete-pair"
expect_error(combine(c(corr,list(extra_c)),c(mmc,list(extra_m))),"Multiple complete")

fake_query <- function(query,variables) {
  if(grepl("CurrentRound",query,fixed=TRUE)) return(list(rounds=list(list(number=210L))))
  if (identical(variables$modelName, "blocked") || identical(variables$modelId, "blocked"))
    stop("An excluded model must not be downloaded.")
  if(grepl("ModelId",query,fixed=TRUE)) return(list(v3UserProfile=list(id=variables$modelName)))
  stopifnot(grepl("distinctOnRound: false",query,fixed=TRUE),
            variables$lastNRounds==standalone_config$last_n_rounds,
            variables$tournament==standalone_config$tournament_id)
  sign <- if(variables$modelId=="positive")1 else -1
  list(corr=records("canon_corr60",sign*.01),mmc=records("canon_mmc60",sign*.002))
}
minimal_roster <- standalone$standalone_prepare_model_df(
  data.frame(name=c(" Positive ","negative","numerai_swmm","blocked"),start=100L,
    `Include?`=c("Yes","yes","Yes"," No "),check.names=FALSE),
  standalone_config$model_names_to_exclude)
standalone_config$request_pause_seconds <- 0
download <- function(model_df,current_round,config)
  standalone$standalone_download_d60(model_df,current_round,config,fake_query)
from_api <- standalone$standalone_refresh_portfolio(standalone_config,minimal_roster,
  file.path(folder,"api_only"),archive_dir=file.path(folder,"no_archive"),
  current_round_function=function()standalone$standalone_current_round(standalone_config,fake_query),
  panel_builder=download)
stopifnot(nrow(from_api$weights)==1L,
  from_api$weights$model=="positive",from_api$weights$weight==1,
  abs(from_api$weights$signal_combined_score-.06)<1e-12,
  file.exists(from_api$output_path))
# A new roster member with no archived column is filled from its API cells.
added <- standalone$standalone_refresh_portfolio(standalone_config,minimal_roster,
  file.path(folder,"new_roster"),archive_dir=archive_dir,
  current_round_function=function()210L,panel_builder=download)
stopifnot(identical(added$weights$model,"positive"),
  identical(utils::read.csv(archive_paths[["d60"]], check.names = FALSE), archive_before))
# No models cannot re-enter through the archive, even with a positive signal.
permissions <- data.frame(name = models, start = 100L, `Include?` = "Yes", check.names = FALSE)
permissions[["Include?"]][1L] <- "No"
allowed <- standalone$standalone_prepare_model_df(permissions, character())
restricted <- standalone$standalone_refresh_portfolio(standalone_config, allowed,
  file.path(folder, "permissions"), archive_dir, function()210L, function(...)api$d60)
expected_restricted <- format_default_rule_portfolio(build_live_default_rule_weights(
  signal[c("roundNumber", allowed$name)], contract, 210L),
  restricted$weights$generated_at_utc[1L])
stopifnot(identical(restricted$weights, expected_restricted))
# All No is a valid no-submission decision that invalidates stale current weights.
# No score downloads or archive access are needed to make that decision.
permissions[["Include?"]] <- "No"
none <- standalone$standalone_prepare_model_df(permissions, character())
all_excluded <- standalone$standalone_refresh_portfolio(standalone_config, none,
  file.path(folder, "permissions"), archive_dir = file.path(folder, "no_archive"),
  current_round_function = function()210L,
  panel_builder = function(...)stop("No score downloads expected."))
excluded_csv <- utils::read.csv(all_excluded$output_path, check.names = FALSE)
stopifnot(nrow(excluded_csv) == 0L,
  identical(names(excluded_csv), names(restricted$weights)),
  file.exists(paste0(all_excluded$output_path, ".last-successful")))
# An account with only one model still has a proper 9-by-1 window.
single_cells <- standalone$standalone_exact_cells(
  data.frame(roundNumber=138:146,positive=.06),"positive",146:138)
stopifnot(nrow(standalone$standalone_weights(single_cells,210L,"fixture"))==1L)
