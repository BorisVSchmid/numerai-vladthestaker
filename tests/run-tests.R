files <- c("test-pipeline-inputs.R", "test-selected-runtime.R", "test-equal-weight-history.R",
  "test-step4-operator-contract.R", "test-default-rule-analysis.R",
  "test-standalone-live-refresh.R")
for(file in files) {
  message("Running ",file)
  withCallingHandlers(
    sys.source(file.path("tests",file),new.env(parent=globalenv())),
    message = function(message) invokeRestart("muffleMessage")
  )
}
cat("All focused offline tests passed.\n")
