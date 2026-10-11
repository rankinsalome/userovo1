#!/usr/bin/env bash
set -euo pipefail
target="${1:?target path required}"
git show HEAD:Tweak.xm > "$target"
if grep -q "g_logicCallbackLiveEnabled" "$target"; then
  echo "rollback failed: temporary live-path gate remains"
  exit 1
fi
if ! grep -q "tryActorLogicCallbackPosition(currentActor" "$target"; then
  echo "rollback failed: expected HEAD callback call site missing"
  exit 1
fi
echo "rollback restored $target from HEAD:Tweak.xm; live callback path matches HEAD"
