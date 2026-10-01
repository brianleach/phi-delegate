#!/usr/bin/env bash
# Heuristic PHI scanner. Reads a file (or stdin) and reports COUNTS of
# matches per pattern class; it never prints the matching text, so its
# output is safe to show in the orchestrator session. Exit 0 when clean,
# 1 when anything matched. This is a tripwire, not a guarantee: the
# orchestrator-side rules in SKILL.md are the primary control.
#
# usage: phi-scan.sh [--profile default|diff|prose] [--only CLASS[,CLASS]]
#                    [--skip CLASS[,CLASS]] [--allow FILE] [file]
#   (reads stdin when no file is given)
#
#   --profile diff  drop git diff and log metadata (diff --git, index,
#                   ---/+++ file headers, @@ hunk headers) before matching,
#                   plus Author:, Signed-off-by:, Co-Authored-By: lines where
#                   git puts them (column 0 headers, 4-space indented message
#                   trailers), so author emails are not counted. Diff content
#                   lines (+, -, or one-space context) always scan, even when
#                   their content looks like metadata.
#   --profile prose for a human scanning documentation that talks about PHI:
#                   skips dob-keyword, identifier-keyword, clinical-keyword.
#                   Every other class still scans. Not used by delegate.sh or
#                   collect.sh, whose handoff scans stay on the default.
#   --only / --skip limit the classes checked; repeatable. Unknown class: exit 2.
#   --allow FILE    allowlist, one extended regex per line (conventionally
#                   .phi-allow); a matched line that also matches an allowlist
#                   entry is not counted. Blank and # lines are ignored. Never
#                   loaded implicitly, so a tree cannot allowlist itself.
set -euo pipefail

CLASSES=" ssn-shaped phone-shaped email-address date-shaped iso-date dob-keyword"
CLASSES+=" identifier-keyword patient-name-keyword clinical-keyword street-address"
CLASSES+=" long-digit-run "

die() { echo "error: $*" >&2; exit 2; }
check_classes() {
  local c
  [ -n "${1//[, ]/}" ] || die "empty class list"
  for c in ${1//,/ }; do
    case "$CLASSES" in *" $c "*) ;; *) die "unknown class: $c" ;; esac
  done
}

profile=default only="" skip="" allow="" input=/dev/stdin
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) [ $# -ge 2 ] || die "--profile needs a value"; profile="$2"; shift 2 ;;
    --only) [ $# -ge 2 ] || die "--only needs a class"; check_classes "$2"; only="$only,$2"; shift 2 ;;
    --skip) [ $# -ge 2 ] || die "--skip needs a class"; check_classes "$2"; skip="$skip,$2"; shift 2 ;;
    --allow) [ $# -ge 2 ] || die "--allow needs a file"; allow="$2"; shift 2 ;;
    -*) die "unknown option: $1" ;;
    *) input="$1"; shift ;;
  esac
done
case "$profile" in
  default|diff) ;;
  prose) skip="$skip,dob-keyword,identifier-keyword,clinical-keyword" ;;
  *) die "unknown profile: $profile" ;;
esac
[ -z "$allow" ] || [ -f "$allow" ] || die "no such allowlist: $allow"

if [ "$input" != "/dev/stdin" ] && [ ! -f "$input" ]; then
  die "no such file: $input"
fi

tmp="$(mktemp "${TMPDIR:-/tmp}/phi-scan.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cat "$input" >"$tmp"

# Infrastructure identifiers are not PHI but carry long digit runs that the
# long-digit-run rule would otherwise flag: an AWS account id inside an ARN
# or an ECR image URI. Mask those token shapes before scanning so an ops
# handoff that names an ECS task or an image can still be shown. A bare
# 9+ digit number outside those shapes is still flagged.
masked="$(mktemp "${TMPDIR:-/tmp}/phi-scan.XXXXXX")"
trap 'rm -f "$tmp" "$masked"' EXIT
sed -E \
  -e 's#arn:aws:[A-Za-z0-9:/_.-]+#[ARN]#g' \
  -e 's#(^|[^0-9])[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com#\1[ECR]#g' \
  "$tmp" >"$masked"
mv "$masked" "$tmp"

if [ "$profile" = diff ]; then
  # Author/trailer lines are dropped only at column 0 (git log -p commit
  # headers) or at exactly four spaces (git log -p message trailers). A diff
  # content line starts with +, -, or one space and is kept even when its
  # content looks like metadata: a dropped line is an unscanned line.
  grep -v -E -i -e '^(diff --git |index [0-9a-f]+\.\.[0-9a-f]+|--- (a/|/dev/null)|\+\+\+ (b/|/dev/null)|@@ )' \
    -e '^( {4})?(Author|Signed-off-by|Co-Authored-By):' "$tmp" >"$masked" || true
  mv "$masked" "$tmp"
fi

allow_re="$(mktemp "${TMPDIR:-/tmp}/phi-scan.XXXXXX")"
trap 'rm -f "$tmp" "$masked" "$allow_re"' EXIT
if [ -n "$allow" ]; then
  grep -v -E '^[[:space:]]*(#|$)' "$allow" >"$allow_re" || true
fi

total=0
report() {
  local label="$1" pattern="$2" flags="${3:-}" n
  if [ -n "$only" ] && [[ ",$only," != *",$label,"* ]]; then return 0; fi
  if [[ ",$skip," == *",$label,"* ]]; then return 0; fi
  # Matched lines stay inside this pipeline and are only counted.
  # shellcheck disable=SC2086
  if [ -s "$allow_re" ]; then
    n="$({ grep $flags -E -- "$pattern" "$tmp" || true; } | { grep -c -v -E -f "$allow_re" || true; })"
  else
    n="$(grep -c $flags -E -- "$pattern" "$tmp" || true)"
  fi
  n="${n:-0}"
  if [ "$n" -gt 0 ]; then
    printf '  %-28s %s line(s)\n' "$label" "$n"
    total=$((total + n))
  fi
}

report "ssn-shaped"        '\b[0-9]{3}-[0-9]{2}-[0-9]{4}\b'
report "phone-shaped"      '(\(|\b)[0-9]{3}(\) ?|[-. ])[0-9]{3}[-. ][0-9]{4}\b'
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
