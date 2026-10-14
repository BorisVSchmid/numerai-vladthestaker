# Load a step's helper definitions without running its download, fit, or publication.
# Constants must be explicitly named; no top-level workflow expressions are run.
load_step_functions <- function(path, envir = parent.frame(), constants = character()) {
  for (expression in parse(path)) {
    if (!is.call(expression) || !identical(expression[[1L]], as.name("<-")) ||
        !is.symbol(expression[[2L]])) next
    value <- expression[[3L]]
    is_function <- is.call(value) && identical(value[[1L]], as.name("function"))
    if (is_function || as.character(expression[[2L]]) %in% constants)
      eval(expression, envir = envir)
  }
  invisible(envir)
}
