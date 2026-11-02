#!/bin/sh
# Test of the cell memory in module/service.sh (remembered / remember / not_suspect): the functions are taken from
# the module script (no phone needed; any POSIX sh, also on a phone).
#   sh tests/fallback_memory_test.sh [path to service.sh]
SRC=${1:-$(dirname "$0")/../module/service.sh}
eval "$(sed -n '/^remembered() {/,/^}/p; /^remember() {/,/^}/p; /^not_suspect() {/,/^}/p' "$SRC")"
STATE=$(mktemp -d); trap 'rm -rf "$STATE"' EXIT
log() { :; }

fails=0
check() {  # $1 = case, $2 = key, $3 = expected "fallback|suspect|remembered"
    got="$(paste -sd, "$STATE/fallback" 2>/dev/null)|$(paste -sd, "$STATE/suspect" 2>/dev/null)|$(remembered "$2" && echo yes || echo no)"
    if [ "$got" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$3], got [$got]"; fails=$((fails + 1)); fi
}

A=99970:637056; B=99970:637152
not_suspect X;                       check "not_suspect without a file" X "||no"
remember $A;                         check "first failure on A: suspect" $A "|$A|no"
remember $A;                         check "second failure on A: fallback" $A "$A||yes"
remember $A;                         check "third failure on A: no change" $A "$A||yes"
remember $B;                         check "first failure on B" $B "$A|$B|no"
not_suspect $B;                      check "NR only worked on B: cleared" $B "$A||no"
remember $B;                         check "failure on B again counts as first" $B "$A|$B|no"
remember 99970:-1; remember :637152; remember 99970:
                                     check "invalid keys ignored" 99970:-1 "$A|$B|no"
remember 315010:637152; not_suspect $B
                                     check "other cells kept" 315010:637152 "$A|315010:637152|no"
[ $fails = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
