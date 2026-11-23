#!/usr/bin/env bash
# Everything that can be checked without a second machine or a password.

set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"

omarchy plugin validate "$project_dir"
jq -e '.id == "io.github.faeric.omatail-kvm" and .entryPoints.barWidget == "BarWidget.qml"' manifest.json >/dev/null

for file in README.md LICENSE THIRD_PARTY_NOTICES.md BarWidget.qml Panel.qml; do
  test -f "$file"
done

# The widget and its panel answer to the id the manifest declares.
grep -Fq 'moduleName: "io.github.faeric.omatail-kvm"' BarWidget.qml
grep -Fq 'moduleName: "io.github.faeric.omatail-kvm"' Panel.qml

for script in scripts/*; do
  bash -n "$script"
  [[ $script == scripts/lib.sh || -x $script ]] || {
    printf '%s is not executable\n' "$script" >&2
    exit 1
  }
done

# Every catalog carries the same keys, and every key the panel asks for exists.
for catalog in i18n/*.json; do
  diff <(jq -r 'keys[]' i18n/en.json) <(jq -r 'keys[]' "$catalog") >/dev/null || {
    printf '%s does not have the same keys as i18n/en.json\n' "$catalog" >&2
    exit 1
  }
done

while read -r key; do
  if [[ $key == *. ]]; then
    for edge in left right top bottom; do
      jq -e --arg key "$key$edge" 'has($key)' i18n/en.json >/dev/null || {
        printf 'i18n/en.json has no "%s"\n' "$key$edge" >&2
        exit 1
      }
    done
  else
    jq -e --arg key "$key" 'has($key)' i18n/en.json >/dev/null || {
      printf 'i18n/en.json has no "%s"\n' "$key" >&2
      exit 1
    }
  fi
done < <(grep -ohE 'strings\.t\("[^"]+"' Panel.qml BarWidget.qml | sed -E 's/.*"([^"]+)"/\1/' | sort -u)

# Text that can carry a machine name is never left to QML's rich-text guess.
awk '
  /^[[:space:]]*Text \{/ {
    line = NR
    getline following
    if (following !~ /textFormat: Text.PlainText/) {
      printf "%s:%d: Text without textFormat: Text.PlainText\n", FILENAME, line > "/dev/stderr"
      bad = 1
    }
  }
  END { exit bad }' Panel.qml

tests/clip-relay-test >/dev/null || {
  printf 'tests/clip-relay-test failed; run it on its own to see which check\n' >&2
  exit 1
}

printf 'All Omatail KVM checks passed.\n'
