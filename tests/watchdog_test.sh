#!/bin/sh
# Test of the "NR only" watchdog in module/service.sh (watch_tick, watchdog): the functions are taken from the module
# script and run tick by tick (2 s) against a simulated phone (no phone needed; any POSIX sh, also on a phone).
#   sh tests/watchdog_test.sh [path to service.sh]
SRC=${1:-$(dirname "$0")/../module/service.sh}
eval "$(sed -n -e '/^watchdog() {/,/^}/p' -e '/^watch_tick() {/,/^}/p' "$SRC")"

# Simulated phone: $PLAN = "second:state ..." (state from that second on): 5g, lte (in service, not 5G), down (no
# service), airplane. The main loop's reaction to a retry is copied from service.sh.
state() { s=5g; for p in $PLAN; do [ $T -ge ${p%%:*} ] && s=${p#*:}; done; }    # sets s (no subshells: fast)
on_5g() { checks=$((checks + 1)); state; [ $s = 5g ]; }
radio_wanted() { state; [ $s != airplane ]; }
sim_ok() { true; }
in_service() { state; [ $s = lte ]; }
save_nr() { :; }
run() {  # $1 = seconds: prints the retry times (from the start), sets checks
    T=0; checks=0; wrong=0; down=0; retries=0; good=0; wd=0; every=2; out=""
    while [ $T -lt $1 ]; do
        T=$((T + 2))
        if watch_tick; then
            retries=$((retries + 1)); out="$out $T"
            wrong=0; down=$((-30 * retries)); good=0; every=2
        fi
    done
    echo $out
}

fails=0
same() {  # $1 = case, $2 = expected, $3 = result
    if [ "$3" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2], got [$3]"; fails=$((fails + 1)); fi
}
within() {  # $1 = case, $2 = min, $3 = max, $4 = value
    if [ -n "$4" ] && [ "$4" -ge "$2" ] && [ "$4" -le "$3" ]; then echo "ok   $1 ($4)"
    else echo "FAIL $1: expected $2..$3, got [$4]"; fails=$((fails + 1)); fi
}

PLAN="0:5g"; r=$(run 300); run 300 >/dev/null
same "5 minutes on 5G: no retry" "" "$r"
within "5 minutes on 5G: checks (every 2 s for a minute, then every 10 s)" 50 60 $checks
PLAN="0:5g 301:lte"; r=$(run 400)
within "on LTE after 5 minutes on 5G: first retry, seconds after the drop" 18 28 $((${r%% *} - 301))
PLAN="0:5g 61:lte"; r=$(run 200)
within "on LTE right after the first minute on 5G" 18 28 $((${r%% *} - 61))
PLAN="0:lte"; r=$(run 30)
within "on LTE from the start (2 s checks)" 18 20 ${r%% *}
PLAN="0:down"; r=$(run 60)
within "no service from the start: first retry after 45 s" 44 48 ${r%% *}
PLAN="0:airplane"; r=$(run 600); run 600 >/dev/null
same "airplane mode: no retry" "" "$r"
within "airplane mode, 10 minutes: checks every 10 s" 55 65 $checks
PLAN="0:airplane 300:lte"; r=$(run 400)
within "LTE after airplane mode: first retry, seconds after it" 18 30 $((${r%% *} - 300))
PLAN="0:lte"; r=$(run 400)
same "LTE for good: 5 retries, then the watchdog gives up" 5 "$(echo $r | wc -w | tr -d ' ')"
PLAN="0:lte 110:5g 800:lte"; r=$(run 830)
same "after 5 retries and 10 minutes on 5G the count starts again: a 6th retry" 6 "$(echo $r | wc -w | tr -d ' ')"
within "the 6th retry, seconds after the new drop" 18 28 $((${r##* } - 800))

echo "$fails failed"
[ $fails -eq 0 ]
