#!/bin/sh
# agent-exec.sh -- a reference EXEC for tick.sh: compile the task's window, hand it to the
# agent, keep the window with the result.
#
#   EXEC=/path/to/agent-exec.sh AGENT_CMD='your-model-cli --flags' tick.sh
#
# AGENT_CMD reads the window (markdown) on stdin, runs with the out directory as its working
# directory, and writes its results there. The window is saved as window.md beside them, and
# the tick records its blob hash as a Window: trailer on the done commit, so "what did the agent
# know when it acted?" is answered by the commit itself.
set -eu
task=$1 out=$2
here=$(cd "$(dirname "$0")" && pwd)
python3 "$here/window.py" "$task" --agent "${AGENT_ID:-}" --out "$out/window.md"
cd "$out" && sh -c "${AGENT_CMD:?set AGENT_CMD to the command that runs the agent}" < window.md
