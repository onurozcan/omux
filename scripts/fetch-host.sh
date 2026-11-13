#!/bin/zsh
# Brings down the omux-host builds GitHub made for a commit, into build/host/, where build.sh
# puts them in the app bundle. A release is built from these, not from a local container.
#
#   scripts/fetch-host.sh            the builds for HEAD
#   scripts/fetch-host.sh REF        the builds for another commit, branch or tag
#
# The commit has to be pushed, and the "Host builds" workflow run for it or for the last
# commit before it that touched the host's sources; the script waits for a run in progress.
set -euo pipefail
cd "${0:A:h}/.."

commit=$(git rev-parse "${1:-HEAD}")
# The newest commit at or before this one that changed what the host is built from: later
# commits that don't touch it didn't start a build, and don't need one.
built=$(git log -1 --format=%H "$commit" -- Sources/OmuxCore Sources/OmuxHostKit Sources/omux-host Package.swift .github/workflows/host.yml)
[[ -n "$built" ]] || { echo "No commit here touches the host's sources." >&2; exit 1; }

run=""
for attempt in {1..30}; do
  run=$(gh run list --workflow "Host builds" --commit "$built" --json databaseId,status,conclusion --jq '.[0] | "\(.databaseId) \(.status) \(.conclusion)"' 2>/dev/null || true)
  [[ -n "$run" && "$run" != "null null null" ]] && break
  run=""
  sleep 4
done
[[ -n "$run" ]] || { echo "GitHub has no host build for ${built[1,7]}. Is it pushed? (gh workflow run 'Host builds' starts one.)" >&2; exit 1; }

id=${run%% *}
if [[ "$run" != *" completed "* ]]; then
  echo "Waiting for GitHub to finish building the host for ${built[1,7]}…"
  gh run watch "$id" --exit-status >/dev/null
fi
[[ "$(gh run view "$id" --json conclusion --jq .conclusion)" == "success" ]] || { echo "The host build for ${built[1,7]} failed: gh run view $id" >&2; exit 1; }

rm -rf build/host
mkdir -p build/host
gh run download "$id" --dir build/host-download
mv build/host-download/*/omux-host-linux-* build/host/
rm -rf build/host-download
echo "Host builds for ${built[1,7]}:"
ls -lh build/host | awk 'NR>1 {print "  " $5 "  " $9}'
