source("relay-r.R")
if (requireNamespace("rlang", quietly = TRUE)) {
  preview_env <- new.env(parent = baseenv())
  preview_env$frame <- data.frame(x = 1:150, y = rep("value", 150))
  delayedAssign("lazy", stop("Preview forced a promise"), assign.env = preview_env)
  makeActiveBinding("active", function() stop("Preview ran an active binding"), preview_env)
  previews <- relay_r_previews(preview_env)
  stopifnot(length(previews) == 1L, previews[[1]]$total_rows == 150L,
            length(previews[[1]]$rows) == 100L)
}
root <- tempfile("relay-r-test-")
dir.create(root, mode = "0700")
e <- new.env(parent = globalenv())
r <- relay_r_evaluate("x <- 42; data.frame(a = 1:150)", "table", root, e)
stopifnot(r$status == "completed", e$x == 42,
          r$table$truncated, length(r$table$data$a) == 100L)
stopifnot(inherits(try(relay_r_evaluate("x <- 0", "table", root, e), silent = TRUE), "try-error"), e$x == 42)
r <- relay_r_evaluate("stop('test failure')", "error", root, e)
stopifnot(r$status == "error", r$error == "test failure")
before <- grDevices::dev.cur()
r <- relay_r_evaluate("plot(1:3); plot(3:1)", "plots", root, e)
stopifnot(r$status == "completed", length(r$plots) == 2L,
          grDevices::dev.cur() == before)
stopifnot(inherits(try(relay_r_evaluate("x <- 0", "../bad", root, e), silent = TRUE), "try-error"))
result <- jsonlite::read_json(file.path(root, "table", "result.json"))
stopifnot(result$status == "completed")
stopifnot(result$session$pid == Sys.getpid(), !is.null(result$finished_at))
table <- read.csv(file.path(root, "table", "table.csv"))
stopifnot(nrow(table) == 100L, table$a[100L] == 100L)
r <- relay_r_evaluate("data.frame(a = character())", "empty-table", root, e)
stopifnot(r$status == "completed", file.exists(file.path(root, "empty-table", "table.csv")))
cat("Relay R companion tests passed; isolated artifacts:", root, "\n")

e$frame <- data.frame(x = 1:250, y = letters[1:10])
e$accesses <- 0L
makeActiveBinding("active", function() { e$accesses <- e$accesses + 1L; 1 }, e)
delayedAssign("lazy", { stop("Promise must not be forced by environment listing") }, assign.env = e)
summary <- relay_r_environment(e)
stopifnot(e$accesses == 0L, summary$total >= 3L)
page <- relay_r_table_page("frame", e, offset = 100L, limit = 20L)
stopifnot(page$returned_rows == 20L, page$columns[[1]][1] == "101")
stopifnot(relay_r_table_page("frame", e, offset = 999L)$returned_rows == 0L)
stopifnot(inherits(try(relay_r_table_page("active", e), silent = TRUE), "try-error"), e$accesses == 0L)
stopifnot(inherits(try(relay_r_table_page("missing", e), silent = TRUE), "try-error"))
cat("Environment listing and bounded table-page tests passed\n")

# Snapshot failure must not turn a completed evaluation into an ambiguous run.
snapshot_function <- relay_r_environment
relay_r_environment <- function(...) stop("snapshot unavailable")
r <- relay_r_evaluate("x <- 99", "snapshot-error", root, e)
stopifnot(r$status == "completed", e$x == 99, r$environment_error == "snapshot unavailable")
relay_r_environment <- snapshot_function

identity <- relay_r_connect(file.path(root, "connected"))
stopifnot(identity$pid == Sys.getpid(), "evaluate" %in% identity$capabilities)
stopifnot(file.exists(file.path(root, "connected", "session.json")))
stopifnot(inherits(try(relay_r_evaluate("x <- 0", "wrong-session", file.path(root,"connected"), e,
                                     expected_session = "wrong"), silent=TRUE), "try-error"), e$x == 99)
r <- relay_r_evaluate("x <- 101", "bound-session", file.path(root,"connected"), e,
                      expected_session = identity$session_id)
stopifnot(r$status == "completed", r$session_id == identity$session_id, e$x == 101)
stopifnot(grepl("Mean", relay_r_help_text("mean"), ignore.case=TRUE))
quota <- file.path(root,"quota"); dir.create(quota)
for (i in 1:128) dir.create(file.path(quota, as.character(i)))
stopifnot(inherits(try(relay_r_evaluate("x <- 0", "over-budget", quota, e),silent=TRUE),"try-error"),e$x==101)
cat("R handshake, stale-session rejection, help and quota tests passed\n")

e$tibble <- structure(data.frame(x = 1:150), class = c("tbl_df", "tbl", "data.frame"))
e$dt <- structure(data.frame(x = 1:150), class = c("data.table", "data.frame"))
e$matrix <- matrix(1:400, ncol = 2)
e$vector <- setNames(1:200, paste0("v", 1:200))
e$list <- list(a = 1, b = list(secret = 2), c = new.env())
stopifnot(nrow(relay_r_inspect("tibble", e)) == 100L,
          relay_r_inspect("dt", e, offset = 100L)$x[1] == "101",
          nrow(relay_r_inspect("matrix", e)) == 100L,
          relay_r_inspect("vector", e, offset = 100L)$name[1] == "v101",
          grepl("inspect separately", relay_r_inspect("list", e)$value[2]))
stopifnot(inherits(try(relay_r_inspect("active", e), silent=TRUE), "try-error"), e$accesses == 0L)
e$custom <- structure(list(x = 1), class = "hostile")
as.character.hostile <- function(...) stop("must not dispatch")
stopifnot(relay_r_inspect("custom", e)$class == "hostile")
cat("Bounded tibble/data.table/matrix/vector/list inspection tests passed\n")

console_root <- file.path(root, "console"); dir.create(console_root)
previous_device <- getOption("device")
relay_r_console_start(console_root)
plot(1:3)
.relay_r_console$capture()
stopifnot(file.info(file.path(console_root, "console-latest.png"))$size > 0)
first_plot <- readBin(file.path(console_root, "console-latest.png"), "raw", n = 8e6)
points(2, 2, col = "red", pch = 19, cex = 3)
.relay_r_console$capture()
stopifnot(!identical(first_plot, readBin(file.path(console_root, "console-latest.png"), "raw", n = 8e6)))
relay_r_console_stop()
stopifnot(identical(getOption("device"), previous_device))
cat("Console plotting and incremental drawing capture passed\n")

# httpgd: run with R_LIBS_USER pointing at a disposable library containing
# httpgd to exercise the real device; otherwise only the refusal path runs.
hgd_root <- file.path(root, "httpgd"); dir.create(hgd_root)
stopifnot(nchar(relay_r_httpgd_token()) == 64L, grepl("^[0-9a-f]{64}$", relay_r_httpgd_token()),
          relay_r_httpgd_token() != relay_r_httpgd_token())
stopifnot(inherits(try(relay_r_httpgd_start(hgd_root), silent = TRUE), "try-error")) # before connect
identity <- relay_r_connect(hgd_root)
stopifnot("httpgd" %in% identity$capabilities, is.logical(identity$httpgd_installed))
stopifnot(inherits(try(relay_r_httpgd_start(hgd_root, width = 10), silent = TRUE), "try-error"))
stopifnot(inherits(try(relay_r_httpgd_start(file.path(root, "console")), silent = TRUE), "try-error"))
stopifnot(identical(relay_r_httpgd_status(), list(running = FALSE)), relay_r_httpgd_stop() == FALSE)
if (!suppressWarnings(requireNamespace("httpgd", quietly = TRUE))) {
  devices_before <- grDevices::dev.list()
  failure <- try(relay_r_httpgd_start(hgd_root), silent = TRUE)
  stopifnot(inherits(failure, "try-error"), grepl("unavailable or cannot load", failure),
            is.null(get0(".relay_r_httpgd", envir = .GlobalEnv)),
            !file.exists(file.path(hgd_root, "httpgd.json")),
            identical(grDevices::dev.list(), devices_before), !"httpgd" %in% loadedNamespaces())
  r <- relay_r_evaluate("plot(1:3)", "png-fallback", hgd_root, e, expected_session = identity$session_id)
  stopifnot(r$status == "completed", length(r$plots) == 1L, is.null(r$plot_target))
  cat("httpgd refusal path passed (httpgd not installed here; real-device tests SKIPPED)\n")
} else {
  relay_r_console_start(file.path(root, "console"))
  printed <- capture.output(started <- relay_r_httpgd_start(hgd_root))
  stopifnot(length(printed) == 0L, is.null(started$token), is.null(get0(".relay_r_console", envir = .GlobalEnv)))
  descriptor_path <- file.path(hgd_root, "httpgd.json")
  stopifnot(file.exists(descriptor_path), as.integer(file.info(descriptor_path)$mode) == strtoi("600", 8L))
  descriptor <- jsonlite::read_json(descriptor_path)
  stopifnot(descriptor$version == 1L, descriptor$session_id == identity$session_id,
            descriptor$pid == Sys.getpid(), descriptor$host == "127.0.0.1",
            descriptor$port == started$port, grepl("^[0-9a-f]{64}$", descriptor$token),
            descriptor$device == started$device, descriptor$artifact_root == normalizePath(hgd_root))
  stopifnot(!any(grepl(descriptor$token, printed, fixed = TRUE)))
  status <- relay_r_httpgd_status()
  stopifnot(isTRUE(status$running), status$history == 0L)
  # The HTTP API must require the token; /state is served without the R thread.
  http <- function(path, token = NULL) system(sprintf(
    "curl -s -o /dev/null -w '%%{http_code}' --max-time 5 %s 'http://127.0.0.1:%d%s'",
    if (is.null(token)) "" else sprintf("-H 'X-HTTPGD-TOKEN: %s'", token), descriptor$port, path), intern = TRUE)
  if (nzchar(Sys.which("curl"))) {
    stopifnot(http("/state") == "401", http("/state", "0000") == "401", http("/state", descriptor$token) == "200")
  }
  # Editor evaluations draw into httpgd history instead of private PNG files.
  other <- grDevices::pdf(NULL); other_device <- grDevices::dev.cur()
  r <- relay_r_evaluate("plot(1:3)", "httpgd-plot", hgd_root, e, expected_session = identity$session_id)
  stopifnot(r$status == "completed", identical(r$plot_target, "httpgd"), length(r$plots) == 0L,
            relay_r_httpgd_status()$history == 1L, grDevices::dev.cur() == other_device)
  grDevices::dev.off(other_device)
  # Reconnecting re-binds the descriptor to the new session identity.
  identity2 <- relay_r_connect(hgd_root)
  stopifnot(jsonlite::read_json(descriptor_path)$session_id == identity2$session_id,
            jsonlite::read_json(descriptor_path)$token == descriptor$token)
  # A user dev.off() must be detected, never followed by drawing elsewhere.
  grDevices::dev.off(started$device)
  stopifnot(!isTRUE(relay_r_httpgd_status()$running))
  r <- relay_r_evaluate("plot(1:3)", "httpgd-closed", hgd_root, e, expected_session = identity2$session_id)
  stopifnot(r$status == "completed", length(r$plots) == 1L, is.null(r$plot_target))
  restarted <- relay_r_httpgd_start(hgd_root)
  stopifnot(jsonlite::read_json(descriptor_path)$token != descriptor$token,
            isTRUE(relay_r_httpgd_status()$running))
  stopifnot(relay_r_httpgd_stop(), !file.exists(descriptor_path),
            !(restarted$device %in% grDevices::dev.list()),
            is.null(get0(".relay_r_httpgd", envir = .GlobalEnv)))
  cat("httpgd start/evaluate/reconnect/dev.off/stop tests passed\n")
}
