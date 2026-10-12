#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
task_compiler="$(xcrun --find swiftc)"
task_plugin="${task_compiler%/bin/swiftc}/lib/swift/host/plugins/testing/libTestingMacros.dylib"
task_flags=()
# Swift 6.4 CLT does not discover its Testing macro plugin on incremental builds.
if [ -f "$task_plugin" ]; then
    task_flags=(-Xswiftc -load-plugin-library -Xswiftc "$task_plugin")
fi
swift test "${task_flags[@]}" "$@"
