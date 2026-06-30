#!/usr/bin/env bash
# Enforce that every pinned module `?ref=` in terraform/ matches VERSIONS.md — the single source of
# truth for fleet-wide platform-module versions (ADR-0011). Module source refs CANNOT be dynamic
# (Terraform forbids a variable in `source`), so this check is how we stop them silently drifting.
# The OPA policy gate, by contrast, derives its version dynamically (see reusable-plan.yml).
set -euo pipefail
cd "$(dirname "$0")/.."

rc=0
while IFS= read -r ref; do
  mod=${ref#modules/}; mod=${mod%%\?*}
  ver=${ref##*ref=}
  exp=$(sed -nE "s/^\| \`$mod\` \| \`(v[0-9.]+)\`.*/\1/p" VERSIONS.md | head -1)
  if [ -z "$exp" ]; then
    echo "::error::module '$mod' (pinned $ver) is not listed in VERSIONS.md"; rc=1
  elif [ "$ver" != "$exp" ]; then
    echo "::error::module '$mod' pinned to $ver but VERSIONS.md says $exp"; rc=1
  fi
done < <(grep -rhoE 'modules/[a-z-]+\?ref=v[0-9.]+' terraform --include='*.tf' --exclude-dir=.terraform | sort -u)

if [ "$rc" -eq 0 ]; then
  echo "versions OK — all module refs match VERSIONS.md"
fi
exit "$rc"
