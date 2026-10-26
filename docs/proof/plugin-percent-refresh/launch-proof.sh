#!/bin/bash
set -euo pipefail
proof_root=$(cd "$(dirname "$0")" && pwd)
phase=${1:?baseline or fixed}
case "$phase" in
  baseline) proof_bundle="$proof_root/Baseline.app" ;;
  fixed) proof_bundle="$proof_root/Fixed.app" ;;
  *) exit 2 ;;
esac
proof_run="$proof_root/runtime-$phase"
mkdir -p "$proof_run/home"
proof_args=(--plugin-percent-refresh-proof --proof-output "$proof_run" --proof-auto)
if [[ "$phase" == baseline ]]; then proof_args+=(--proof-baseline); fi
env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/open -n \
  --stdout "$proof_run/stdout.log" --stderr "$proof_run/stderr.log" \
  --env "HOME=$proof_run/home" --env "CFFIXED_USER_HOME=$proof_run/home" \
  --env SWIFT_TESTING_ENABLED=1 --env CODEXBAR_DISABLE_KEYCHAIN_ACCESS=1 \
  --env CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS=1 --env CODEXBAR_TEST_CODEX_FILE_ISOLATION=1 \
  --env CODEXBAR_TEST_SESSION_FILE_ISOLATION=1 \
  "$proof_bundle" --args "${proof_args[@]}"
