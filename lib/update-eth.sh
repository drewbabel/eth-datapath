#!/bin/bash
set -euo pipefail

repo="https://github.com/alexforencich/verilog-ethernet.git"
remote="eth"
branch="master"
subdir="lib/eth"

cd "$(git rev-parse --show-toplevel)"

git remote get-url "$remote" >/dev/null 2>&1 || git remote add "$remote" "$repo"
git fetch "$remote"
git subtree pull -P "$subdir" --squash "$remote" "$branch" -m "[rtl] Refresh vendored verilog-ethernet"
