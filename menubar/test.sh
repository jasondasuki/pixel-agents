#!/bin/sh
# swift test with Swift Testing from the Command Line Tools (no full Xcode needed).
cd "$(dirname "$0")" || exit 1
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
exec swift test \
  -Xswiftc -F -Xswiftc "$F" \
  -Xlinker -F -Xlinker "$F" \
  -Xlinker -rpath -Xlinker "$F" \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib "$@"
