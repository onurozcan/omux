#!/bin/zsh
# Builds the core and runs its tests on Linux, in a container, before a push does it in CI.
# Needs a Docker runtime: `brew install colima docker`. Starts Colima if it isn't running.
#
#   scripts/linux-test.sh            build the core and run its tests
#   scripts/linux-test.sh build      build only
#   scripts/linux-test.sh shell      a shell in the container, in the repository
set -euo pipefail
cd "${0:A:h}/.."

if ! docker info >/dev/null 2>&1; then
  command -v colima >/dev/null || { echo "No Docker runtime. Install one: brew install colima docker" >&2; exit 1; }
  echo "Starting Colima…"
  colima start --cpu 4 --memory 6 --disk 20 --vm-type vz --mount-type virtiofs >/dev/null
fi

# The image CI uses, and a build folder of its own beside the Mac's .build.
run() { docker run --rm ${TTY:+-it} -v "$PWD":/src -w /src swift:6.2 "$@"; }
case "${1:-test}" in
  build) run swift build --target OmuxCore --scratch-path .build-linux ;;
  shell) TTY=1 run bash ;;
  test)  run bash -c 'swift build --target OmuxCore --scratch-path .build-linux && swift test --filter OmuxCoreTests --scratch-path .build-linux' ;;
  *) echo "usage: $0 [test|build|shell]" >&2; exit 2 ;;
esac
