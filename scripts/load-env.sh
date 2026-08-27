# shellcheck shell=bash
# Sourced helper (not executable): load PHI_DELEGATE_* settings from the
# skill repo's gitignored .env file when they are not already set in the
# environment. Real environment variables always win. Override the file
# location with PHI_DELEGATE_ENV_FILE.
#
# Variables:
#   PHI_DELEGATE_API_KEY        Anthropic API key from the org that holds the
#                               BAA with zero data retention enabled. Kept
#                               under its own name so it can never be
#                               confused with a non-ZDR ANTHROPIC_API_KEY
#                               that happens to be in the environment.
#   PHI_DELEGATE_ZDR_ATTESTED   Must be "1": the operator attests the key
#                               above belongs to a ZDR + BAA organization.
#   PHI_DELEGATE_MODEL          Default claude-opus-5. Fable-class models are
#                               refused: they are not offered under ZDR.
#   PHI_DELEGATE_CONFIG_DIR     Separate CLAUDE_CONFIG_DIR for delegate runs
#                               (default $HOME/.phi-delegate/claude) so the
#                               delegate never sees the subscription login.
#
# The .env lives at the root of the phi-delegate checkout (next to this
# scripts/ directory), NOT in the repo being worked on.

phi_load_env() {
  local script_dir env_file var
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  env_file="${PHI_DELEGATE_ENV_FILE:-${script_dir}/../.env}"
  if [ -f "$env_file" ]; then
    # Snapshot anything already set so the environment wins.
    local -A snapshot=()
    for var in PHI_DELEGATE_API_KEY PHI_DELEGATE_ZDR_ATTESTED PHI_DELEGATE_MODEL PHI_DELEGATE_CONFIG_DIR; do
      if [ -n "${!var:-}" ]; then
        snapshot["$var"]="${!var}"
      fi
    done
    set -a
    # shellcheck source=/dev/null
    . "$env_file"
    set +a
    for var in "${!snapshot[@]}"; do
      printf -v "$var" '%s' "${snapshot[$var]}"
    done
  fi
  PHI_DELEGATE_MODEL="${PHI_DELEGATE_MODEL:-claude-opus-5}"
  PHI_DELEGATE_CONFIG_DIR="${PHI_DELEGATE_CONFIG_DIR:-${HOME}/.phi-delegate/claude}"
  export PHI_DELEGATE_MODEL PHI_DELEGATE_CONFIG_DIR
  return 0
}

phi_load_env
