#!/usr/bin/env bash
# Heuristic PHI scanner. Reads a file (or stdin) and reports COUNTS of
# matches per pattern class; it never prints the matching text, so its
# output is safe to show in the orchestrator session. Exit 0 when clean,
# 1 when anything matched. This is a tripwire, not a guarantee: the
# orchestrator-side rules in SKILL.md are the primary control.
#
# usage: phi-scan.sh [file]        (reads stdin when no file is given)
set -euo pipefail

input="${1:-/dev/stdin}"
if [ "$input" != "/dev/stdin" ] && [ ! -f "$input" ]; then
  echo "error: no such file: $input" >&2
  exit 2
fi

tmp="$(mktemp "${TMPDIR:-/tmp}/phi-scan.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cat "$input" >"$tmp"

total=0
report() {
  local label="$1" pattern="$2" flags="${3:-}" n
  # shellcheck disable=SC2086
  n="$(grep -c $flags -E -- "$pattern" "$tmp" || true)"
  n="${n:-0}"
  if [ "$n" -gt 0 ]; then
    printf '  %-28s %s line(s)\n' "$label" "$n"
    total=$((total + n))
  fi
}

report "ssn-shaped"        '\b[0-9]{3}-[0-9]{2}-[0-9]{4}\b'
report "phone-shaped"      '(\(|\b)[0-9]{3}[)-. ][0-9]{3}[-. ][0-9]{4}\b'
report "email-address"     '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
report "date-shaped"       '\b(0?[1-9]|1[0-2])[/-](0?[1-9]|[12][0-9]|3[01])[/-]([0-9]{2}|[0-9]{4})\b'
report "iso-date"          '\b(19|20)[0-9]{2}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])\b'
report "dob-keyword"       '\b(dob|date of birth|birth ?date)\b' -i
report "identifier-keyword" '\b(mrn|medical record|patient id|member id|policy number|ssn|social security)\b' -i
report "patient-name-keyword" '\b(patient name|first_name|last_name|full_name)\s*[:=]' -i
report "clinical-keyword"  '\b(diagnos(is|es)|icd-?10|rx|prescription|dosage)\b' -i
report "street-address"    '\b[0-9]{1,6} [A-Za-z0-9 .]+ (street|st|avenue|ave|road|rd|blvd|lane|ln|drive|dr)\b\.?' -i
report "long-digit-run"    '\b[0-9]{9,}\b'

if [ "$total" -gt 0 ]; then
  echo "phi-scan: $total potential PHI line(s) flagged (text withheld)"
  exit 1
fi
echo "phi-scan: clean"
