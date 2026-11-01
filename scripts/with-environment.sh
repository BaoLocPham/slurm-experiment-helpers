#!/usr/bin/env bash
set -euo pipefail
environment=${1:?Expected environment script}; shift
export EXP_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$EXP_PROJECT_ROOT/scripts/common.sh"
export EXP_ENVIRONMENT_SCRIPT="$environment"
# Attach uses the run snapshot; a new interactive allocation uses current settings.
if [[ -r "$(dirname -- "$environment")/settings.sh" ]]; then
    export EXP_RUN_DIR="$(dirname -- "$environment")"
fi
if (( $# == 0 )); then
    exec bash --rcfile "$EXP_PROJECT_ROOT/scripts/interactive.sh" -i
fi
load_session_environment
exec "$@"
