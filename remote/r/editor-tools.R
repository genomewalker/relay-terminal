# Isolated editor tooling. Never sources the user's document or project profile.
request <- jsonlite::fromJSON(paste(readLines(file("stdin"), warn = FALSE), collapse = "\n"), simplifyVector = FALSE)
answer <- tryCatch({
  stopifnot(is.character(request$method), length(request$method) == 1L)
  if (length(request$libraries)) .libPaths(unlist(request$libraries))
  code <- request$code
  if (is.null(code)) code <- ""
  stopifnot(is.character(code), length(code) == 1L, nchar(code, type = "bytes") <= 262144L)
  switch(request$method,
    format = {
      if (!requireNamespace("styler", quietly = TRUE)) stop("Install styler in this R environment to format code")
      list(text = paste(styler::style_text(code), collapse = "\n"))
    },
    lint = {
      if (!requireNamespace("lintr", quietly = TRUE)) stop("Install lintr in this R environment to check code")
      # Explicit defaults: never execute a project's .lintr configuration.
      issues <- lintr::lint(text = code, linters = lintr::linters_with_defaults(), cache = FALSE, parse_settings = FALSE)
      list(diagnostics = lapply(head(issues, 200L), function(x) list(
        line = x$line_number, column = x$column_number,
        message = substr(x$message, 1L, 2048L), type = x$type)))
    },
    help = {
      topic <- request$topic
      stopifnot(is.character(topic), length(topic) == 1L, nchar(topic) <= 200L)
      qualified <- strsplit(topic, "::", fixed = TRUE)[[1L]]
      if (length(qualified) == 2L) {
        found <- utils::help(qualified[2L], package = qualified[1L], help_type = "text")
      } else found <- utils::help(topic, help_type = "text")
      if (!length(found)) stop("No installed documentation for this topic")
      list(text = substr(paste(capture.output(tools::Rd2txt(utils:::.getHelpFile(found[1L]), options = list(underline_titles = FALSE))), collapse = "\n"), 1L, 65536L))
    }, stop("Unsupported editor operation"))
}, error = function(e) list(error = conditionMessage(e)))
cat(jsonlite::toJSON(answer, auto_unbox = TRUE, null = "null"))
