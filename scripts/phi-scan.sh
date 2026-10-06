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
#                   trailers), so author emails are not counted. Only lines
#                   outside a hunk are dropped: from an @@ line to the next
#                   diff --git or commit header every line is content and
#                   scans, even when it looks like metadata.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATTERNS="$SCRIPT_DIR/phi-patterns.tsv"
[ -f "$PATTERNS" ] || { echo "error: pattern file missing: $PATTERNS" >&2; exit 2; }

# Parallel arrays (bash 3.2 has no associative arrays), filled from the
# pattern file shared with the mod. Empty fields are written "-".
class_names=() class_flags=() class_regex=() mask_regex=() mask_repl=()
drop_flags=() drop_regex=()
hunk_start="" hunk_end=""
CLASSES=" " PROSE_SKIP=""
while IFS=$'\t' read -r kind name flags tags regex repl; do
  case "$kind" in
    class)
      class_names+=("$name"); class_flags+=("$flags"); class_regex+=("$regex")
      CLASSES+="$name "
      case ",$tags," in *,prose-skip,*) PROSE_SKIP+=",$name" ;; esac
      ;;
    mask) mask_regex+=("$regex"); mask_repl+=("$repl") ;;
    drop) drop_flags+=("$flags"); drop_regex+=("$regex") ;;
    hunk) case "$name" in start) hunk_start="$regex" ;; end) hunk_end="$regex" ;; esac ;;
  esac
done <"$PATTERNS"

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
  prose) skip="$skip$PROSE_SKIP" ;;
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
i=0
while [ "$i" -lt "${#mask_regex[@]}" ]; do
  sed -E "s#${mask_regex[$i]}#${mask_repl[$i]}#g" "$tmp" >"$masked"
  mv "$masked" "$tmp"
  i=$((i + 1))
done

if [ "$profile" = diff ]; then
  if [ -z "$hunk_start" ] || [ -z "$hunk_end" ]; then
    echo "error: pattern file has no hunk rows" >&2
    exit 2
  fi
  # Tag each line H (inside a hunk) or O (outside), so the drop rules below
  # reach only metadata positions. Author/trailer lines are dropped only at
  # column 0 (git log -p commit headers) or at exactly four spaces (git log
  # -p message trailers, which come before the first diff --git). Inside a
  # hunk a line is content even when it looks like metadata: a dropped line
  # is an unscanned line.
  HUNK_START="$hunk_start" HUNK_END="$hunk_end" awk '
    $0 ~ ENVIRON["HUNK_END"] { inhunk = 0 }
    $0 ~ ENVIRON["HUNK_START"] { inhunk = 1; print "O\t" $0; next }
    { print (inhunk ? "H" : "O") "\t" $0 }' "$tmp" >"$masked"
  mv "$masked" "$tmp"
  tab="$(printf '\t')"
  i=0
  while [ "$i" -lt "${#drop_regex[@]}" ]; do
    case "${drop_regex[$i]}" in ^*) ;; *) echo "error: drop rule must start with ^" >&2; exit 2 ;; esac
    case "${drop_flags[$i]}" in i) dflag=-i ;; *) dflag=-E ;; esac
    grep -v -E "$dflag" -e "^O${tab}${drop_regex[$i]#^}" "$tmp" >"$masked" || true
    mv "$masked" "$tmp"
    i=$((i + 1))
  done
  cut -f2- "$tmp" >"$masked"
  mv "$masked" "$tmp"
fi

allow_re="$(mktemp "${TMPDIR:-/tmp}/phi-scan.XXXXXX")"
trap 'rm -f "$tmp" "$masked" "$allow_re"' EXIT
if [ -n "$allow" ]; then
  grep -v -E '^[[:space:]]*(#|$)' "$allow" >"$allow_re" || true
fi

total=0
report() {
  local label="$1" pattern="$2" flags="$3" n
  if [ -n "$only" ] && [[ ",$only," != *",$label,"* ]]; then return 0; fi
  if [[ ",$skip," == *",$label,"* ]]; then return 0; fi
  # Matched lines stay inside this pipeline and are only counted.
  if [ -s "$allow_re" ]; then
    n="$({ grep "$flags" -E -- "$pattern" "$tmp" || true; } | { grep -c -v -E -f "$allow_re" || true; })"
  else
    n="$(grep -c "$flags" -E -- "$pattern" "$tmp" || true)"
  fi
  n="${n:-0}"
  if [ "$n" -gt 0 ]; then
    printf '  %-28s %s line(s)\n' "$label" "$n"
    total=$((total + n))
  fi
}

i=0
while [ "$i" -lt "${#class_names[@]}" ]; do
  case "${class_flags[$i]}" in i) cflag=-i ;; *) cflag=-E ;; esac
  report "${class_names[$i]}" "${class_regex[$i]}" "$cflag"
  i=$((i + 1))
done

if [ "$total" -gt 0 ]; then
  echo "phi-scan: $total potential PHI line(s) flagged (text withheld)"
  exit 1
fi
echo "phi-scan: clean"
