# Git review

Review changes in the project belonging to the selected terminal. In Plugin
tools, choose Git review and refresh. Select a changed file for its diff, or
choose **Open working file in editor** to open the original host's working copy.
Switching tabs cannot silently retarget the captured project.

Review is read-only: it does not stage, commit, reset or submit code to an agent.
Git external diff/text-conversion helpers are disabled; hostile inherited Git
environment settings cannot redirect the operation. Output is bounded and
truncation is shown. Local and Relay SSH editor handoffs are supported in source.

Install/enable through Settings → Plugins. Manual changed-file navigation and
editor handoff remain deferred acceptance checks, not completed release claims.
