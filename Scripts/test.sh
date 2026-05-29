#!/bin/bash
# Run the test suite with Swift Testing under Command Line Tools.
#
# Why this wrapper: this machine has Command Line Tools only (no full Xcode),
# so XCTest is unavailable. Swift Testing's framework ships with the CLT but
# isn't on SPM's default search path, so we add it explicitly here. Use this
# instead of a bare `swift test`. Extra args are forwarded (e.g. --filter Name).
set -euo pipefail
FWPATH="$(xcode-select -p)/Library/Developer/Frameworks"
exec swift test \
  -Xswiftc -F -Xswiftc "$FWPATH" \
  -Xlinker -F -Xlinker "$FWPATH" \
  -Xlinker -rpath -Xlinker "$FWPATH" \
  "$@"
