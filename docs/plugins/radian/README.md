# Radian for Relay

Experimental R workspace plugin for [Relay](https://github.com/genomewalker/relay-terminal).
Development version 0.2.0 adds local and remote tab-scoped editor layouts and an R-results browser.
This is not a complete RStudio replacement.

## Install

Requires a Relay build with the `rWorkspace` plugin operation and R editor
execution support. Older releases cannot load this package.

1. Open Relay Settings → Plugins.
2. During development, choose **Review local manifest…** and select this
   directory's `relay-plugin.json`. The GitHub release remains a draft; it is
   not yet available through public release installation.
3. Review the project-read permission, install and enable the package.
4. Select your existing docked local or Relay SSH R/radian console. Open Plugin tools and
   choose **Activate R workspace in this tab**, then **Activate in this tab**.

No R process is started, no packages are installed, and other tabs are untouched.

## Available

- Activate an editor above the selected docked local or Relay SSH console in its existing tab.
  Other panes stay in place; repeated activation reuses the linked editor.
  A local console must first report its working directory through shell integration.
- In `.R` files, use Command-Enter or the editor context menu to request running
  the selection (or current line). A native confirmation shows the exact code
  and original console. Check it is an idle R prompt with empty input. This does
  not save the file or launch R. First use **R setup…**, approve loading the
  bundled companion in the existing R console, then **R session** to read its
  saved handshake. Requests are bound to that R process identity. R Markdown and
  diff views do not execute. Selected analysis code is limited to 4 KiB.
- Browse files within the project belonging to the selected pane.
- Preview PNG plots and CSV table previews without opening a new R process.
- Open **Results** in the R editor to browse saved plots, tables and environment
  names in a docked panel. Refresh is explicit; these are not live objects.
- Zoom saved plots and export the selected artifact through **Save copy…**.
  Preview images are downsampled; export preserves the original bytes.
- Use the opt-in companion in `relay-r.R` to evaluate code in the
  current R environment and write request-tagged results.
- Retain existing objects. Errors and interrupts are recorded separately.
- Reject duplicate request IDs instead of silently executing code again.
- **Latest receipt** distinguishes running/completed/error/interrupted R results
  from merely submitted input. A saved handshake is explicitly not liveness.
- Table-page requests inspect up to 100 rows/30 columns with per-request approval.
- In **Environment**, click an object name to select it in **Table**, then use
  **Inspect page…** and approve the request. Data frames, tibbles, data.tables,
  plain matrices, vectors and list summaries are supported. Read the completed
  request's `table.csv` from Results; inspection does not continuously poll R.
  Active bindings are disabled. Nested objects and custom classes are summarized
  without calling their print methods; unsupported column types are labelled.
  Explicit inspection can evaluate a lazy binding.
- Installed R help is rendered as bounded plain text, never remote HTML.
- New capture requests are refused above 128 runs or 512 MiB of saved artifacts.
  Existing results are never deleted automatically; arbitrary R code is not
  sandboxed, so a single approved run can exceed that soft admission budget.

For console plots, load the updated companion with **R setup…**, refresh the
session, then choose **Plots → Enable console plots…** and approve the request.
Subsequent `plot()` commands and incremental drawing such as `points()` are
captured after each console command. While Plots is visible and Relay is active,
the viewer checks file metadata every five seconds and loads changed images.
**Latest console plot** also refreshes manually. Capture retains only the latest
image. Hiding the dock cancels its update task; inactive apps skip remote checks.
**Stop capture…** closes only the capture device and restores the previous default
device setting. Explicitly opening another device directs plots there instead.
Existing PDF plots are not imported. Live Environment updates remain unimplemented.

The package requests project read access only. It cannot execute code, submit
terminal input, install R packages, or message agents. It reuses Relay's file
size limits and integrity-checked download path. Browsing does not poll R.

## Companion use

Copy the reviewed companion to the remote project, then explicitly source it
in the existing radian session. It requires `jsonlite` and PNG graphics support.
Create a private results directory within the project first:

```r
source("relay-r.R")
dir.create("relay-results", mode = "0700")
relay_r_evaluate(
  "plot(cars); head(cars)",
  request_id = "cars-example-001",
  artifact_root = "relay-results"
)
```

Open **R plots and tables**, browse `relay-results/cars-example-001`, and select
the PNG or `table.csv`. The CSV is a bounded preview, not a full export.
`result.json` records completion/error and whether the table was truncated.
Evaluation has your R process's full permissions; this is not a sandbox.

## Limitations

The companion is opt-in. Editor execution is a Relay host feature with per-send
confirmation, not executable plugin code. Native installed acceptance and
multi-client verification are deferred. There is no automatic readiness sensing
or continuous environment polling: refresh saved receipts after approval.
