#!/bin/sh
# Test of radio_check() in module/pixel-5g-enabler-restore.sh: the function is taken from the module script and run
# against simulated modem and Android states (no phone needed; any POSIX sh, also on a phone).
#   sh tests/radio_check_test.sh [path to pixel-5g-enabler-restore.sh]
SRC=${1:-$(dirname "$0")/../module/pixel-5g-enabler-restore.sh}
eval "$(sed -n '/^radio_check() {/,/^}/p' "$SRC")"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

pick() {  # $1 = name, then the values: the next value at each call (the last one repeats)
    c=$1; shift
    [ $# -eq 0 ] && { echo; return; }
    n=$(cat "$T/$c" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$T/$c"
    [ $n -gt $# ] && n=$#
    eval "echo \${$n}"
}
modem_radio() { pick modem $MODEM; }                       # +CFUN value
android_shows_off() { [ "$(pick aoff $AOFF)" = 1 ]; }      # 1 = Android shows POWER_OFF
wants_radio() { [ "$(pick want $WANT)" = 1 ]; }            # 1 = Android wants the radio on
at() { echo "$1" >> "$T/actions"; }
cmd() { echo "cmd $*" >> "$T/actions"; }
log() { echo "log $*" >> "$T/actions"; }
sleep() { :; }

fails=0
check() {  # $1 = case, $2 = expected actions
    rm -f "$T"/*
    radio_check
    got=$(sed -e 's/^log radio check: the radio.*switching it on$/detected/' -e 's/^log radio check: radio on$/on/' \
              -e 's/^log radio check: Android still.*/airplane/' -e 's/^AT+CFUN=1$/cfun1/' \
              -e 's/^cmd connectivity airplane-mode enable$/apm-on/' -e 's/^cmd connectivity airplane-mode disable$/apm-off/' \
              "$T/actions" 2>/dev/null | paste -sd' ' -)
    if [ "$got" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2], got [$got]"; fails=$((fails + 1)); fi
}

MODEM="1" AOFF="0" WANT="1";                  check "radio on: nothing done" ""
MODEM="0 0 0 1" AOFF="0" WANT="1";            check "off, Android believes on: switched on" "detected cfun1 on"
MODEM="0 0 0 1" AOFF="1 0" WANT="1";          check "off, Android shows off, switching on helps" "detected cfun1 on"
MODEM="0 0 0 1" AOFF="1" WANT="1";            check "Android keeps showing off: airplane mode on/off" "detected cfun1 airplane apm-on apm-off"
MODEM="4 4 4 1" AOFF="0" WANT="1";            check "CFUN 4 counts as off" "detected cfun1 on"
MODEM="0 0 1 0 0 1" AOFF="0" WANT="1";        check "off twice, on, off twice: nothing done" ""
MODEM="0" AOFF="1" WANT="0";                  check "airplane mode on (Android does not want it): nothing done" ""
MODEM="0 0 0 1" AOFF="1" WANT="1 1 1 0";      check "airplane mode switched on meanwhile: no toggle" "detected cfun1"
MODEM="" AOFF="0" WANT="1";                   check "modem does not answer: nothing done" ""
[ $fails = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
