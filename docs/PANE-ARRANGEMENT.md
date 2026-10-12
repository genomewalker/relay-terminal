# Pane arrangement

Floating terminal and editor panes have a **Minimize** button beside Dock and Close.
Minimize hides the pane in a horizontally scrollable strip at the bottom of its tab.
It does not detach, terminate, or restart the session. Click its strip entry or sidebar
entry to restore it at its previous size and position. Minimized state is saved with
the workspace.

The workspace **More (…)** menu provides explicit actions:

- **Tile floating panes:** arrange visible floating panes in a non-overlapping grid.
  If minimum usable sizes will not fit, Relay asks you to minimize some panes,
  enlarge the window, or use Cascade. Minimized panes stay minimized.
- **Cascade floating panes:** stagger visible floating panes.
- **R workspace:** select a docked R console or its linked editor first.
  Relay reuses or adds the editor beside that console and opens Results in the
  closable context dock. Other tiled and floating panes keep their positions,
  sizes, and minimized state. Hiding Results returns the full canvas without
  changing the R process. This action does not run R code or enable plot capture.
- **Restore previous layout:** restores an explicitly saved tile or cascade
  arrangement. Opening R no longer creates a tab-wide arrangement snapshot.

Nothing automatically rearranges panes during typing, dragging, or window resizing.
