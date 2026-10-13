# Shared AWS profile helpers for setup.sh / wake.sh / destroy.sh
# shellcheck shell=bash

aws_profile_export() {
  local name="${1:-}"
  [[ -n "$name" ]] || return 0
  export AWS_PROFILE="$name"
  export AWS_SDK_LOAD_CONFIG="${AWS_SDK_LOAD_CONFIG:-1}"
}

# Print identity or die with SSO hint when a profile was requested.
aws_profile_require() {
  local requested="${1:-}" # empty = optional (warn only)
  if ! command -v aws >/dev/null 2>&1; then
    if [[ -n "$requested" ]]; then
      echo "error: aws CLI not found but --aws-profile was set" >&2
      exit 1
    fi
    return 0
  fi
  if aws sts get-caller-identity >/dev/null 2>&1; then
    echo "  AWS_PROFILE:  ${AWS_PROFILE:-"(default chain)"}"
    echo "  AWS identity: $(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"
    echo "  Account:      $(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
    return 0
  fi
  if [[ -n "$requested" ]]; then
    echo "error: AWS profile '${AWS_PROFILE}' failed sts get-caller-identity." >&2
    echo "  If this is SSO, run:  aws sso login --profile ${AWS_PROFILE}" >&2
    echo "  Then retry." >&2
    exit 1
  fi
  echo "warning: aws sts get-caller-identity failed — check credentials before apply." >&2
}
