#!/bin/sh
# Test of the self-check in module/checks.sh (the status line in the Magisk app) and of the report's masking in
# module/action.sh: the functions are taken from the module scripts and run against simulated SIM, modem and Android
# states (no phone needed; any POSIX sh, also on a phone).
#   sh tests/status_test.sh [module folder]
SRC=${1:-$(dirname "$0")/../module}
eval "$(sed -n -e '/^listed() {/p; /^dashed() {/p; /^nv() {/,/^}/p; /^modem_values() {/,/^}/p' \
              -e '/^finding() {/,/^}/p; /^worse() {/,/^}/p; /^check() {/,/^}/p' "$SRC/checks.sh")"
eval "$(sed -n '/^mask() {/,/^}/p; /^wrap() {/,/^}/p' "$SRC/action.sh")"
MODDIR=$(mktemp -d); STATE=$MODDIR/state; mkdir -p "$STATE"; trap 'rm -rf "$MODDIR"' EXIT
CARRIER_ID=1911
plmns=$(printf '00101\n315010\n99970\n')

fails=0
same() {  # $1 = case, $2 = expected, $3 = result
    if [ "$3" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2], got [$3]"; fails=$((fails + 1)); fi
}

# --- names, modem values, masking
same "PLMN with a 2-digit MNC" "999-70" "$(dashed 99970)"
same "PLMN with a 3-digit MNC" "315-010" "$(dashed 315010)"
same "setting of slot 1" "NR.CONFIG.MODE" "$(nv 1 NR.CONFIG.MODE)"
same "slot 2: NR. settings" "DS.NR.CONFIG.MODE" "$(nv 2 NR.CONFIG.MODE)"
same "slot 2: ! settings" '!SAEL3_DS.SAE_UE_OPERATION_MODE' "$(nv 2 '!SAEL3.SAE_UE_OPERATION_MODE')"
same "slot 2: other settings" "OEM_GFEATURE_CARRIER_ID_DS" "$(nv 2 OEM_GFEATURE_CARRIER_ID)"
getnv() {  # simulated modem
    case "$1" in
        OEM_GFEATURE_CARRIER_ID) echo "77,07,00,00" ;;  OEM_GFEATURE_CARRIER_ID_DS) echo "FF,FF,FF,FF" ;;
        NR.CONFIG.MODE) echo 11 ;;  DS.NR.CONFIG.MODE) echo 01 ;;  OEM_GFEATURE_ENABLE_FCC_BANDS) echo 00 ;;
    esac
}
same "modem values: the module's profile" "1911 11 00" "$(modem_values 1)"
same "modem values: no carrier, a value missing" "none 01 ?" "$(modem_values 2)"
getnv() { case "$1" in *CARRIER_ID) echo "zz,07,00,00" ;; esac; }
same "modem values: no valid reply" "? ? ?" "$(modem_values 1)"
same "masking: ICCID, IMSI, phone number; times stay" \
    "SIM 99970 (890000********), IMSI 999700********, +******** at 1761990000000, 2026-11-01 13:52:00" \
    "$(echo "SIM 99970 (89000000000000000011), IMSI 999700000000011, +12025550111 at 1761990000000, 2026-11-01 13:52:00" | mask)"
same "console lines: broken at spaces, continuation indented" \
    "Phone:  Pixel 9a (tegu), Android 17 |  (CP3A.261005.005, patch 2026-10-05)|short" \
    "$(printf '%s\n' "Phone:  Pixel 9a (tegu), Android 17 (CP3A.261005.005, patch 2026-10-05)" short | wrap | paste -sd'|' -)"

# --- the self-check: simulated SIMs ($SIMn = PLMN), modem ($MODEMn) and Android ($ANDROIDn) per slot
sim_plmn() { eval "echo \$SIM$1"; }
modem_values() { eval "echo \$MODEM$1"; }
android_values() { eval "echo \$ANDROID$1"; }
stamp() { echo "0123 versionCode=6 $1 1afa464c 00101 315010 99970" > "$MODDIR/overlay.stamp"; rm -f "$MODDIR/overlay.none"; }
none() { rm -f "$MODDIR/overlay.stamp"; if [ -n "$1" ]; then echo "$1" > "$MODDIR/overlay.none"; else rm -f "$MODDIR/overlay.none"; fi; }
t() {  # $1 = case, $2 = expected status, $3 = expected retry (default 0)
    check
    same "$1" "$2 | retry ${3:-0}" "$status | retry $retry"
}
OK="1911 11 00"; A1="89000000000000000011 2 yes"; A2="89000000000000000022 2 yes"
WAIT1="89000000000000000011 -1 no"; WAIT2="89000000000000000022 -1 no"

stamp g5300; SIM1=99970; SIM2=""; MODEM1=$OK; ANDROID1=$A1
t "listed SIM, everything in place" "✅ Working: g5300 modem profile in use, SIM 999-70 ready"
same "report lines: three checks passed" 3 "$(printf '%s' "$checks" | grep -c '^✓')"
stamp g5400; SIM1=315010; SIM2=99970; MODEM2=$OK; ANDROID2=$A2
t "two listed SIMs" "✅ Working: g5400 modem profile in use, SIM 315-010, SIM 999-70 (slot 2) ready"
stamp g5300; SIM1=26201
t "listed SIM in slot 2 only" "✅ Working: g5300 modem profile in use, SIM 999-70 (slot 2) ready"
SIM1=""; SIM2=""
t "no SIM" "ℹ️ No SIM ready"
SIM1=26201; SIM2=310260
t "SIMs not listed" "ℹ️ No SIM from plmns.conf (SIM 1: 262-01, SIM 2: 310-260)"
SIM1=99970; SIM2=""; MODEM1="0 00 01"
t "modem uses the stock profile" "❌ Modem profile not in use for SIM 999-70 (modem's carrier profile: 0): reboot once; if it stays, tap Action for a report" 1
MODEM1="none 00 01"
t "modem has no profile" "❌ Modem profile not in use for SIM 999-70 (modem's carrier profile: none): reboot once; if it stays, tap Action for a report" 1
SIM1=00101; MODEM1="1911 11 01"
t "001-01 with Google's test profile" "❌ Modem profile incomplete for SIM 001-01 (5G mode 11, regional band tables 01): reboot once; if it stays, tap Action for a report" 1
SIM1=99970; MODEM1="? ? ?"
t "modem does not answer" "⚠️ Modem did not answer the check: g5300 modem profile not confirmed"
MODEM1=$OK; ANDROID1=$WAIT1; echo 89000000000000000011 > "$STATE/pending"
t "new SIM: settings written after boot" "⚠️ Reboot once to apply the settings of SIM 999-70"
rm -f "$STATE/pending"
t "Android did not load the settings" "❌ Android does not use the carrier settings of SIM 999-70: reboot once; if it stays, tap Action for a report" 1
ANDROID1="89000000000000000011 1 yes"
t "Android loaded them but the SIM is voice-centric" "❌ Android does not use the carrier settings of SIM 999-70: reboot once; if it stays, tap Action for a report" 1
ANDROID1=$WAIT1; SIM2=315010; MODEM2=$OK; ANDROID2=$WAIT2; echo 89000000000000000022 > "$STATE/pending"
t "error on SIM 1 beats warning on SIM 2" "❌ Android does not use the carrier settings of SIM 999-70: reboot once; if it stays, tap Action for a report" 1
echo 89000000000000000011 >> "$STATE/pending"
t "two warnings: the first one is shown" "⚠️ Reboot once to apply the settings of SIM 999-70"
rm -f "$STATE/pending"; SIM2=""; ANDROID1=$A1
none "no modem profile for modem 'g5500x-1'"
t "unknown modem" "⚠️ No modem profile for modem 'g5500x-1': carrier settings and 4G/5G switching only"
ANDROID1=$WAIT1
t "unknown modem and Android settings missing" "❌ Android does not use the carrier settings of SIM 999-70: reboot once; if it stays, tap Action for a report" 1
SIM1=""; none "plmns.conf has no PLMN"
t "no modem profile: other reason" "❌ No modem profile: plmns.conf has no PLMN"
none
t "no modem profile: no reason saved" "❌ No modem profile: see the boot log"

echo "$fails failed"
[ $fails -eq 0 ]
