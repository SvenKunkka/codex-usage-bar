#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
"$project_dir/scripts/build-app.sh" >/dev/null
"$project_dir/dist/Codex Usage Bar.app/Contents/MacOS/CodexUsageBar" --self-test
