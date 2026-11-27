#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
for dependency in IDeviceKitten Zsign; do
    patch="$root/tools/dependency-patches/$dependency.patch"
    path="$root/$dependency"
    if git -C "$path" apply --reverse --check "$patch" >/dev/null 2>&1; then
        continue
    fi
    git -C "$path" apply --check "$patch"
    git -C "$path" apply "$patch"
done
