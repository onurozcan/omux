#!/bin/zsh
# Builds omux-host for Linux, in containers, into build/host/ where build.sh picks it up for
# the app bundle. One self-contained file per architecture: nothing to install beside it.
#
#   scripts/build-host.sh            the architecture of this Mac's containers
#   scripts/build-host.sh all        aarch64 and x86_64 (the other one emulated: slow)
set -euo pipefail
cd "${0:A:h}/.."

if ! docker info >/dev/null 2>&1; then
  command -v colima >/dev/null || { echo "No Docker runtime. Install one: brew install colima docker" >&2; exit 1; }
  colima start --cpu 4 --memory 6 --disk 20 --vm-type vz --mount-type virtiofs >/dev/null
fi
trap 'git checkout -q -- Package.resolved 2>/dev/null || true' EXIT
mkdir -p build/host

build() {  # docker platform, name suffix
  echo "Building omux-host for linux/$2…"
  docker run --rm --platform "linux/$1" -v "$PWD":/src -w /src swift:6.2 bash -c "
    swift build -c release --product omux-host --static-swift-stdlib --scratch-path .build-linux-$2 2>&1 | tail -1 &&
    strip -o build/host/omux-host-linux-$2 .build-linux-$2/release/omux-host"
  pack "build/host/omux-host-linux-$2"
}

# What the app carries: the program packed small, and the hash it compares with the copy on
# a machine to tell whether that copy is this build.
pack() {
  shasum -a 256 "$1" | cut -d' ' -f1 > "$1.sha256"
  /usr/bin/tar -cJf "$1.tar.xz" --options 'xz:compression-level=9' -C "${1:h}" "${1:t}"
  rm "$1"
  ls -lh "$1.tar.xz" | awk '{print "  " $5 "  " $9}'
}

native=$(docker info --format '{{.Architecture}}')
case "${1:-native}" in
  all) build arm64 aarch64; build amd64 x86_64 ;;
  native) [[ "$native" == "aarch64" || "$native" == "arm64" ]] && build arm64 aarch64 || build amd64 x86_64 ;;
  *) echo "usage: $0 [all]" >&2; exit 2 ;;
esac
