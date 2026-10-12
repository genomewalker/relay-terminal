# Explicitly source this companion into an existing R/radian session.
# It opens no socket, starts no process, and evaluates nothing on load.

# Explicit handshake. This is evidence of a particular loaded R process, not a
# liveness claim: the app labels file-based snapshots and refreshes on demand.
relay_r_console_stop <- function() {
  state <- get0(".relay_r_console", envir = .GlobalEnv, inherits = FALSE)
  if (is.null(state)) return(invisible(FALSE))
  removeTaskCallback(state$callback)
  if (identical(getOption("device"), state$factory)) options(device = state$previous)
  if (!is.null(state$device) && state$device %in% grDevices::dev.list())
    grDevices::dev.off(state$device)
  rm(".relay_r_console", envir = .GlobalEnv)
  invisible(TRUE)
}

# Explicit opt-in: a null PDF display list retains incremental drawing across
# console commands. Only our device is captured; existing user devices survive.
# This is the file-snapshot fallback; httpgd (below) replaces it when started.
relay_r_console_start <- function(artifact_root) {
  relay_r_console_stop()
  relay_r_httpgd_stop()
  root <- normalizePath(artifact_root, mustWork = TRUE)
  state <- new.env(parent = baseenv())
  state$previous <- getOption("device")
  state$device <- NULL
  state$last <- NULL
  state$factory <- function(...) {
    grDevices::pdf(NULL)
    state$device <- grDevices::dev.cur()
    grDevices::dev.control(displaylist = "enable")
  }
  state$capture <- function(...) {
    tryCatch({
      if (is.null(state$device) || grDevices::dev.cur() != state$device) return(TRUE)
      plot <- grDevices::recordPlot()
      if (identical(plot, state$last)) return(TRUE)
      # No plot exists until the first high-level plotting command.
      if (is.null(plot[[1L]])) return(TRUE)
      temp <- tempfile("console-", tmpdir = root, fileext = ".png")
      on.exit(unlink(temp), add = TRUE)
      grDevices::png(temp, width = 1200, height = 800)
      output <- grDevices::dev.cur()
      tryCatch(grDevices::replayPlot(plot), finally = grDevices::dev.off(output))
      if (file.info(temp)$size > 8 * 1024^2) stop("Console plot exceeds 8 MiB")
      if (!file.rename(temp, file.path(root, "console-latest.png"))) stop("Cannot publish console plot")
      state$last <- plot
    }, error = function(e) warning("Relay console capture: ", conditionMessage(e), call. = FALSE))
    TRUE
  }
  state$callback <- addTaskCallback(state$capture)
  options(device = state$factory)
  assign(".relay_r_console", state, envir = .GlobalEnv)
  state$factory()
  invisible(TRUE)
}

# httpgd plotting. Behaviour below was verified against the httpgd 2.1.4 and
# unigd 0.2.0 sources and a live device: hgd(host, port, token, silent, width,
# height) binds a token-guarded HTTP API (X-HTTPGD-TOKEN header); the change
# WebSocket is unauthenticated and merely signals updates; unknown plot IDs
# fall back to the newest plot. Relay therefore reads plots only through
# authenticated HTTP after listing IDs, and never prints the token: silent=TRUE
# suppresses httpgd's welcome URL, which would embed it in the console.
relay_r_httpgd_token <- function() {
  con <- tryCatch(file("/dev/urandom", "rb", raw = TRUE),
                  error = function(e) NULL, warning = function(w) NULL)
  if (is.null(con)) stop("No /dev/urandom on this host; httpgd was not started")
  on.exit(close(con), add = TRUE)
  bytes <- readBin(con, "raw", 32L)
  if (length(bytes) != 32L) stop("Short random read; httpgd was not started")
  paste(sprintf("%02x", as.integer(bytes)), collapse = "")
}

# The device number alone can be reused after dev.off(); bind through the
# per-start token so we never close or draw on an unrelated device.
relay_r_httpgd_device <- function() {
  state <- get0(".relay_r_httpgd", envir = .GlobalEnv, inherits = FALSE)
  if (is.null(state) || !(state$device %in% grDevices::dev.list())) return(NULL)
  open <- tryCatch(identical(httpgd::hgd_details(state$device)$token, state$token),
                   error = function(e) FALSE)
  if (isTRUE(open)) state$device else NULL
}

relay_r_httpgd_publish <- function(state) {
  identity <- get0(".relay_r_identity", envir = .GlobalEnv, inherits = FALSE)
  if (is.null(identity)) stop("Connect the Relay companion before publishing httpgd")
  descriptor <- list(version = 1L, session_id = identity$session_id, pid = Sys.getpid(),
    host = "127.0.0.1", port = state$port, token = state$token, device = state$device,
    artifact_root = state$root, httpgd_version = as.character(utils::packageVersion("httpgd")),
    started_at = state$started_at)
  temp <- tempfile("httpgd-", tmpdir = state$root)
  on.exit(unlink(temp), add = TRUE)
  # The descriptor is a bearer credential: make it private before it has content.
  if (!file.create(temp) || !isTRUE(Sys.chmod(temp, "600")))
    stop("Cannot create a private httpgd descriptor")
  jsonlite::write_json(descriptor, temp, auto_unbox = TRUE)
  if (!file.rename(temp, file.path(state$root, "httpgd.json")))
    stop("Cannot publish httpgd descriptor")
  invisible(TRUE)
}

relay_r_httpgd_stop <- function() {
  state <- get0(".relay_r_httpgd", envir = .GlobalEnv, inherits = FALSE)
  if (is.null(state)) return(invisible(FALSE))
  device <- relay_r_httpgd_device()
  if (!is.null(device)) grDevices::dev.off(device)
  unlink(file.path(state$root, "httpgd.json"))
  rm(".relay_r_httpgd", envir = .GlobalEnv)
  invisible(TRUE)
}

# Explicit, reviewed start. Nothing is installed: a missing package is an
# error with instructions. Replaces the PNG snapshot capture (one plot target).
relay_r_httpgd_start <- function(artifact_root, width = 720, height = 576) {
  stopifnot(is.numeric(width), length(width) == 1L, is.finite(width), width >= 100, width <= 4000,
            is.numeric(height), length(height) == 1L, is.finite(height), height >= 100, height <= 4000)
  identity <- get0(".relay_r_identity", envir = .GlobalEnv, inherits = FALSE)
  if (is.null(identity)) stop("Connect the Relay companion (relay_r_connect) before starting httpgd")
  root <- normalizePath(artifact_root, mustWork = TRUE)
  if (!identical(identity$artifact_root, root)) stop("Artifact root does not match the connected R session")
  if (!suppressWarnings(requireNamespace("httpgd", quietly = TRUE)))
    stop("httpgd is unavailable or cannot load its dependencies in this R library. Repair the R library; Relay never installs packages.")
  relay_r_console_stop()
  relay_r_httpgd_stop()
  token <- relay_r_httpgd_token()
  httpgd::hgd(host = "127.0.0.1", port = 0, cors = FALSE, token = token, silent = TRUE,
              width = width, height = height)
  device <- grDevices::dev.cur()
  details <- tryCatch(httpgd::hgd_details(device), error = function(e) NULL)
  port <- suppressWarnings(as.integer(details$port))
  if (is.null(details) || !identical(details$host, "127.0.0.1") || !identical(details$token, token) ||
      length(port) != 1L || is.na(port) || port < 1L || port > 65535L) {
    grDevices::dev.off(device)
    stop("httpgd did not bind to loopback with Relay's token; the device was closed")
  }
  state <- new.env(parent = baseenv())
  state$device <- device
  state$port <- port
  state$token <- token
  state$root <- root
  state$started_at <- format(Sys.time(), tz = "UTC", usetz = TRUE)
  assign(".relay_r_httpgd", state, envir = .GlobalEnv)
  tryCatch(relay_r_httpgd_publish(state), error = function(e) {
    relay_r_httpgd_stop()
    stop(e)
  })
  # Token deliberately absent: the return value may be printed at the console.
  invisible(list(device = device, port = port))
}

relay_r_httpgd_status <- function() {
  state <- get0(".relay_r_httpgd", envir = .GlobalEnv, inherits = FALSE)
  if (is.null(state)) return(list(running = FALSE))
  device <- relay_r_httpgd_device()
  list(running = !is.null(device), device = state$device, port = state$port,
       history = if (is.null(device)) NA_integer_ else unigd::ugd_state(device)$hsize)
}

relay_r_install_help <- function(root, session_id) {
  options(help_type = "text", pager = function(files, header = NULL, title = "R help",
                                              delete.file = FALSE, ...) {
    if (length(files) > 10L) stop("Too many help pages")
    sizes <- file.info(files)$size
    if (anyNA(sizes) || sum(sizes) > 1024 * 1024) stop("Help page exceeds Relay limit")
    text <- paste(vapply(files, function(path) paste(readLines(path, warn = FALSE), collapse = "\n"), ""), collapse = "\n\n")
    text <- gsub(".\b", "", text, perl = TRUE)
    record <- list(session_id = session_id, title = title, text = text,
                   id = basename(tempfile("help-")))
    temporary <- tempfile("help-", tmpdir = root)
    on.exit(unlink(temporary), add = TRUE)
    jsonlite::write_json(record, temporary, auto_unbox = TRUE)
    if (!file.rename(temporary, file.path(root, "help.json"))) stop("Cannot publish R help")
    if (isTRUE(delete.file)) unlink(files)
    invisible(NULL)
  })
}

relay_r_connect <- function(artifact_root) {
  if (!requireNamespace("jsonlite", quietly = TRUE)) stop("Relay R requires jsonlite")
  dir.create(artifact_root, mode = "0700", showWarnings = FALSE, recursive = TRUE)
  root <- normalizePath(artifact_root, mustWork = TRUE)
  if (!dir.exists(root)) stop("Result directory unavailable")
  id <- paste(Sys.getpid(), format(Sys.time(), "%Y%m%d%H%M%OS6"),
              basename(tempfile("session-")), sep = "-")
  session <- list(version = 1L, session_id = id, pid = Sys.getpid(),
    companion_version = 3L,
    rscript = file.path(R.home("bin"), "Rscript"), library_paths = as.list(.libPaths()),
    host = unname(Sys.info()["nodename"]), working_directory = getwd(),
    artifact_root = root, capabilities = c("evaluate", "environment", "table_page", "help", "console_plots", "environment_updates", "httpgd", "companion_updates"),
    # A package directory is not enough: a broken dependency makes httpgd unusable.
    # requireNamespace loads the namespace but does not attach it to the search path.
    httpgd_installed = suppressWarnings(requireNamespace("httpgd", quietly = TRUE)),
    connected_at = format(Sys.time(), tz = "UTC", usetz = TRUE))
  assign(".relay_r_identity", session, envir = .GlobalEnv)
  temp <- tempfile("session-", tmpdir = root)
  on.exit(unlink(temp), add = TRUE)
  jsonlite::write_json(session, temp, auto_unbox = TRUE)
  if (!file.rename(temp, file.path(root, "session.json"))) stop("Cannot publish R handshake")
  # A reconnect changes the session ID; a still-open httpgd device must be
  # re-bound to it or the app rightly rejects the stale descriptor.
  httpgd_state <- get0(".relay_r_httpgd", envir = .GlobalEnv, inherits = FALSE)
  if (!is.null(httpgd_state)) {
    if (!is.null(relay_r_httpgd_device()) && identical(httpgd_state$root, root))
      tryCatch(relay_r_httpgd_publish(httpgd_state),
               error = function(e) warning("Relay httpgd: ", conditionMessage(e), call. = FALSE))
    else relay_r_httpgd_stop()
  }
  # Only enumerate names/binding flags after completed top-level commands.
  # Never get values: an idle UI must not force promises or active bindings.
  previous <- get0(".relay_r_updates", envir = .GlobalEnv, inherits = FALSE)
  if (!is.null(previous)) removeTaskCallback(previous$callback)
  updates <- new.env(parent = baseenv())
  updates$last <- NULL
  updates$search <- NULL
  updates$packages <- list()
  updates$installed <- as.list(head(rownames(utils::installed.packages()), 2000L))
  updates$publish <- function(...) {
    tryCatch({
      update_file <- file.path(root, "companion-update.json")
      if (file.exists(update_file) && file.info(update_file)$size < 16384) {
        update <- jsonlite::read_json(update_file)
        if (identical(update$session_id, id) && is.character(update$path) &&
            length(update$path) == 1L && file.exists(update$path) &&
            identical(dirname(normalizePath(update$path)), dirname(dirname(root))) &&
            identical(unname(tools::md5sum(update$path)), update$md5)) {
          sys.source(update$path, envir = .GlobalEnv)
          relay_r_connect(root)
          return(TRUE)
        }
      }
      snapshot <- relay_r_environment(limit = 500L)
      snapshot$previews <- relay_r_previews()
      attached <- grep("^package:", search(), value = TRUE)
      if (!identical(attached, updates$search)) {
        updates$packages <- lapply(head(attached, 40L), function(package) {
          list(name = sub("^package:", "", package),
               symbols = as.list(head(ls(as.environment(package), all.names = FALSE), 2000L)))
        })
        updates$search <- attached
      }
      snapshot$completion_packages <- updates$packages
      snapshot$installed_packages <- updates$installed
      if (identical(snapshot, updates$last)) return(TRUE)
      snapshot$session_id <- id
      snapshot$updated_at <- format(Sys.time(), tz = "UTC", usetz = TRUE)
      file <- tempfile("environment-", tmpdir = root)
      on.exit(unlink(file), add = TRUE)
      jsonlite::write_json(snapshot, file, auto_unbox = TRUE)
      if (!file.rename(file, file.path(root, "environment.json"))) stop("Cannot publish environment")
      updates$last <- snapshot
      updates$last$session_id <- NULL
      updates$last$updated_at <- NULL
    }, error = function(e) warning("Relay environment: ", conditionMessage(e), call. = FALSE))
    TRUE
  }
  updates$callback <- addTaskCallback(updates$publish)
  assign(".relay_r_updates", updates, envir = .GlobalEnv)
  relay_r_install_help(root, id)
  updates$publish()
  invisible(session)
}

# Bounded previews of already-materialized plain data only. rlang inspects
# promise state without forcing it; without that capability fail closed.
relay_r_previews <- function(envir = .GlobalEnv) {
  if (!requireNamespace("rlang", quietly = TRUE)) return(list())
  result <- list()
  budget <- 512000L
  for (name in head(ls(envir, all.names = FALSE), 100L)) {
    if (bindingIsActive(name, envir) || rlang::env_binding_are_lazy(envir, name)[[1L]]) next
    value <- get(name, envir, inherits = FALSE)
    if (!identical(class(value), "data.frame") &&
        !identical(class(value), c("tbl_df", "tbl", "data.frame"))) next
    columns <- unclass(value)
    if (!length(columns) || length(columns) > 50L) next
    if (!all(vapply(columns, function(x) is.atomic(x) && !is.object(x) && is.null(dim(x)), logical(1)))) next
    total <- length(columns[[1L]])
    count <- min(total, 100L)
    cells <- lapply(columns, function(x) substr(as.character(x[seq_len(count)]), 1L, 256L))
    rows <- lapply(seq_len(count), function(i) unname(lapply(cells, function(x) if (is.na(x[i])) "NA" else x[i])))
    preview <- list(name = name, total_rows = total, columns = unname(as.list(names(columns))), rows = rows)
    size <- nchar(jsonlite::toJSON(preview, auto_unbox = TRUE), type = "bytes")
    if (size > budget) next
    budget <- budget - size
    result[[length(result) + 1L]] <- preview
  }
  result
}

relay_r_check_session <- function(expected_session, artifact_root) {
  if (is.null(expected_session)) return(invisible(NULL)) # legacy explicit R API
  identity <- get0(".relay_r_identity", envir = .GlobalEnv, inherits = FALSE)
  if (is.null(identity) || !identical(identity$session_id, expected_session) ||
      identity$pid != Sys.getpid() ||
      !identical(identity$artifact_root, normalizePath(artifact_root, mustWork = TRUE)))
    stop("R session changed or is not connected; no code evaluated")
}

relay_r_help_text <- function(topic, package = NULL) {
  stopifnot(is.character(topic), length(topic) == 1L, nchar(topic) <= 200L)
  found <- do.call(utils::help, list(topic = topic, package = package, help_type = "text"))
  if (!length(found)) stop("No installed help found")
  lines <- capture.output(tools::Rd2txt(utils:::.getHelpFile(found[1L])))
  # Plain text only; no browser, JavaScript or external URLs are opened.
  substr(paste(head(lines, 1000L), collapse = "\n"), 1L, 65536L)
}

# Listing names deliberately avoids get(), object.size(), or class(): those can
# force promises or run active bindings merely because a UI refreshed.
relay_r_environment <- function(envir = .GlobalEnv, offset = 0L, limit = 100L) {
  stopifnot(is.environment(envir), length(offset) == 1L, is.finite(offset),
            offset >= 0, offset == floor(offset), length(limit) == 1L,
            is.finite(limit), limit >= 1, limit <= 500, limit == floor(limit))
  names <- ls(envir = envir, all.names = FALSE, sorted = TRUE)
  selected <- head(names[seq_along(names) > offset], limit)
  list(total = length(names), offset = offset,
       objects = lapply(selected, function(name) list(
         name = name, active_binding = bindingIsActive(name, envir),
         inspected = FALSE)))
}

# Explicit inspection may force a lazy binding, so this is an evaluation action,
# not an automatically polled environment summary. Active bindings are refused.
relay_r_table_page <- function(name, envir = .GlobalEnv, offset = 0L, limit = 100L) {
  stopifnot(is.character(name), length(name) == 1L, !is.na(name),
            is.environment(envir), length(offset) == 1L, is.finite(offset),
            offset >= 0, offset == floor(offset), length(limit) == 1L,
            is.finite(limit), limit >= 1, limit <= 100, limit == floor(limit))
  if (!exists(name, envir = envir, inherits = FALSE)) stop("Object no longer exists")
  if (bindingIsActive(name, envir)) stop("Active bindings cannot be previewed")
  value <- get(name, envir = envir, inherits = FALSE)
  # Strip known container classes before indexing: never dispatch user-defined
  # tibble/data.table/S3 indexing or conversion methods during inspection.
  allowed <- c("data.frame", "tbl_df", "tbl", "data.table")
  if (!is.list(value) || !"data.frame" %in% class(value) ||
      any(!class(value) %in% allowed)) stop("Preview requires a supported data frame")
  count <- .row_names_info(value, 2L)
  value <- unclass(value)
  rows <- if (offset >= count) integer() else seq.int(offset + 1L, min(count, offset + limit))
  columns <- seq_len(min(length(value), 30L))
  data <- lapply(columns, function(j) {
    column <- value[[j]]
    if (is.object(column) || !is.atomic(column))
      return(rep("<unsupported column type>", length(rows)))
    vapply(rows, function(i) {
      cell <- column[i]
      if (length(cell) != 1L || is.na(cell)) return(NA_character_)
      substr(as.character(cell), 1L, 512L)
    }, character(1))
  })
  # Positional names preserve duplicates; consumers must not key by column name.
  list(name = name, total_rows = count, total_columns = length(value),
       offset = offset, returned_rows = length(rows),
       column_names = names(value)[columns], columns = data,
       truncated_columns = length(value) > 30L)
}

# Explicit user-approved inspection only. Returns a bounded plain data.frame so
# the normal result capture and CSV viewer need no object-specific serializers.
relay_r_inspect <- function(name, envir = .GlobalEnv, offset = 0L, limit = 100L) {
  stopifnot(is.character(name), length(name) == 1L, !is.na(name),
            is.environment(envir), length(offset) == 1L, is.finite(offset),
            offset >= 0, offset == floor(offset), length(limit) == 1L,
            is.finite(limit), limit >= 1, limit <= 100, limit == floor(limit))
  if (!exists(name, envir, inherits = FALSE)) stop("Object no longer exists")
  if (bindingIsActive(name, envir)) stop("Active bindings cannot be inspected")
  value <- get(name, envir, inherits = FALSE)
  if (inherits(value, "data.frame")) {
    p <- relay_r_table_page(name, envir, offset, limit)
    d <- as.data.frame(p$columns, optional = TRUE, stringsAsFactors = FALSE)
    names(d) <- p$column_names
    return(d)
  }
  # Unknown classes are described, never printed or coerced via their methods.
  if (is.object(value)) return(data.frame(type = typeof(value),
    class = substr(paste(class(value), collapse = ", "), 1L, 512L),
    note = "Custom object: automatic conversion disabled"))
  if (is.matrix(value) && is.atomic(value)) {
    rows <- if (offset >= nrow(value)) integer() else seq.int(offset + 1L, min(nrow(value), offset + limit))
    cols <- seq_len(min(ncol(value), 30L))
    values <- lapply(cols, function(j) substr(as.character(value[rows, j]), 1L, 512L))
    d <- as.data.frame(values, optional = TRUE, stringsAsFactors = FALSE)
    names(d) <- if (is.null(colnames(value))) paste0("V", cols) else colnames(value)[cols]
    return(d)
  }
  if (is.atomic(value) || is.list(value)) {
    indices <- if (offset >= length(value)) integer() else seq.int(offset + 1L, min(length(value), offset + limit))
    labels <- if (is.null(names(value))) as.character(indices) else substr(names(value)[indices], 1L, 512L)
    cells <- vapply(indices, function(i) {
      x <- value[[i]]
      if (is.object(x) || !is.atomic(x) || length(x) != 1L)
        return(paste0("<", typeof(x), "; inspect separately>"))
      if (is.na(x)) return(NA_character_)
      substr(as.character(x), 1L, 512L)
    }, character(1))
    return(data.frame(index = indices, name = labels, value = cells, check.names = FALSE))
  }
  data.frame(type = typeof(value), note = "No automatic evaluation or traversal for this type")
}

relay_r_evaluate <- function(code, request_id, artifact_root,
                             envir = .GlobalEnv, max_rows = 100L,
                             max_columns = 30L, expected_session = NULL) {
  stopifnot(is.character(code), length(code) == 1L, !is.na(code),
            nchar(code, type = "bytes") <= 65536L,
            is.character(request_id), length(request_id) == 1L,
            !is.na(request_id), grepl("^[A-Za-z0-9_-]{1,80}$", request_id),
            is.environment(envir), length(max_rows) == 1L,
            max_rows >= 1L, max_rows <= 100L, length(max_columns) == 1L,
            max_columns >= 1L, max_columns <= 30L)
  if (!requireNamespace("jsonlite", quietly = TRUE))
    stop("Relay R requires jsonlite; no code was evaluated")
  root <- normalizePath(artifact_root, mustWork = TRUE)
  if (!dir.exists(root)) stop("Artifact root must be a directory")
  relay_r_check_session(expected_session, root)
  # Refuse further capture once the workspace budget is consumed. Never delete
  # analysis artifacts automatically. Arbitrary user code is not sandboxed.
  prior <- list.files(root, recursive = TRUE, full.names = TRUE)
  if (length(prior) > 4096L || length(list.dirs(root, recursive = FALSE)) >= 128L ||
      sum(file.info(prior)$size, na.rm = TRUE) > 512 * 1024^2)
    stop("Relay result quota reached (128 runs / 512 MiB); archive results before running")
  run <- file.path(root, request_id)
  # Existing IDs are never re-executed, even after an incomplete prior run.
  if (!dir.create(run, mode = "0700", showWarnings = FALSE))
    stop("Request directory exists or cannot be created; execution refused")
  result <- list(version = 1L, request_id = request_id, status = "running",
                 session_id = expected_session,
                 session = list(pid = Sys.getpid(), host = unname(Sys.info()["nodename"]),
                                working_directory = getwd(), r_version = as.character(getRversion())),
                 started_at = format(Sys.time(), tz = "UTC", usetz = TRUE))
  write_result <- function() {
    temp <- file.path(run, "result.tmp")
    jsonlite::write_json(result, temp, auto_unbox = TRUE, null = "null", na = "null")
    if (!file.rename(temp, file.path(run, "result.json"))) stop("Cannot publish R result")
  }
  write_result()
  device <- NULL
  on.exit({
    if (!is.null(device) && device %in% grDevices::dev.list())
      grDevices::dev.off(device)
  }, add = TRUE)
  # With httpgd running, editor plots must join its history rather than a
  # private PNG file; the previously current device is restored afterwards.
  httpgd_device <- relay_r_httpgd_device()
  tryCatch({
    if (is.null(httpgd_device)) {
      # A dedicated file device avoids redirecting or closing a user's plot device.
      grDevices::png(file.path(run, "plot-%03d.png"), width = 1200, height = 800)
      device <- grDevices::dev.cur()
    } else {
      previous <- grDevices::dev.cur()
      if (previous != httpgd_device) {
        grDevices::dev.set(httpgd_device)
        on.exit(if (previous > 1L && previous %in% grDevices::dev.list()) grDevices::dev.set(previous), add = TRUE)
      }
      result$plot_target <- "httpgd"
    }
    value <- withVisible(eval(parse(text = code, keep.source = FALSE), envir = envir))
    result$status <- "completed"
    result$visible <- value$visible
    result$value_class <- class(value$value)
    if (is.character(value$value) && !is.object(value$value) && length(value$value) == 1L)
      result$text <- substr(value$value, 1L, 65536L)
    if (identical(class(value$value), "data.frame")) {
      d <- value$value
      columns <- seq_len(min(ncol(d), max_columns))
      rows <- seq_len(min(nrow(d), max_rows))
      # Convert cells individually: unsupported/list columns cannot produce an
      # unbounded JSON structure. Display strings are not executable R code.
      preview <- lapply(columns, function(j) {
        column <- d[[j]]
        if (is.object(column) || !is.atomic(column))
          return(rep("<unsupported column type>", length(rows)))
        vapply(rows, function(i) {
          cell <- column[i]
          if (!is.atomic(cell)) return("<complex value>")
          if (length(cell) != 1L || is.na(cell)) return(NA_character_)
          substr(as.character(cell), 1L, 512L)
        }, character(1))
      })
      names(preview) <- names(d)[columns]
      result$table <- list(rows = nrow(d), columns = ncol(d),
                           truncated = nrow(d) > max_rows || ncol(d) > max_columns,
                           data = preview)
      # Export the same bounded preview for Relay's native CSV table viewer.
      # Preserve duplicate/empty column names without silently changing data.
      table <- as.data.frame(preview, optional = TRUE, check.names = FALSE,
                             stringsAsFactors = FALSE)
      names(table) <- names(d)[columns]
      utils::write.csv(table, file.path(run, "table.csv"), row.names = FALSE,
                       na = "", fileEncoding = "UTF-8")
      result$table$artifact <- "table.csv"
    }
  }, error = function(e) {
    result$status <<- "error"
    result$error <<- substr(conditionMessage(e), 1L, 4096L)
  }, interrupt = function(e) {
    result$status <<- "interrupted"
  })
  if (!is.null(device) && device %in% grDevices::dev.list())
    grDevices::dev.off(device)
  device <- NULL
  result$plots <- basename(list.files(run, pattern = "^plot-[0-9]+\\.png$"))
  # Names only: never force promises or invoke active bindings for a UI refresh.
  tryCatch(
    jsonlite::write_json(relay_r_environment(envir), file.path(run, "environment.json"),
                         auto_unbox = TRUE, pretty = TRUE),
    error = function(e) {
      result$environment_error <<- substr(conditionMessage(e), 1L, 4096L)
    })
  result$finished_at <- format(Sys.time(), tz = "UTC", usetz = TRUE)
  write_result()
  invisible(result)
}
