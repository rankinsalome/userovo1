#!/usr/bin/env bash
set -euo pipefail
target="${1:?target path required}"
git show HEAD:Tweak.xm > "$target"
if grep -q "tryActorLogicCallbackPosition" "$target"; then
  echo "rollback failed: callback marker remains"
  exit 1
fi
echo "rollback restored $target from HEAD:Tweak.xm"
