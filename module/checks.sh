#!/system/bin/sh
# Sourced by service.sh and action.sh (with MODDIR set): the PLMN list, modem access, and the self-check behind the
# status line in the Magisk app and the report.
STATE=/data/adb/pixel-5g-enabler
CARRIER_ID=1911    # the carrier ID the overlay gives the listed PLMNs (post-fs-data.sh)

# The PLMN list: one MCC+MNC per line; comments (#) and everything but digits removed; 5 or 6 digits kept.
plmns=$(sed 's/#.*//' $MODDIR/plmns.conf 2>/dev/null | tr -cd '0-9\n' | grep -E '^[0-9]{5,6}$' | sort -u)
listed() { echo "$plmns" | grep -qx "$1"; }         # $1 = PLMN: true if it is in the list
dashed() { echo "${1%"${1#???}"}-${1#???}"; }      # 99970 -> 999-70

# --- modem access: AT commands through /dev/umts_router, the AT channel of the Exynos modem ------------------
AT_REPLY='^\+GOOG|^OK|ERROR'
at() {  # $1 = AT command, $2 = pattern of the reply line wanted (default: NV reply, OK or ERROR)
    n=0
    while ! mkdir $STATE/at.lock 2>/dev/null; do     # one command at a time; a lock older than 10 s is stale
        sleep 0.2; n=$((n + 1)); [ $n -ge 50 ] && rmdir $STATE/at.lock 2>/dev/null
    done
    timeout 5 sh -c "printf '%s\r' '$1' > /dev/umts_router & cat /dev/umts_router" 2>/dev/null \
        | tr -d '\r' | grep -E "${2:-$AT_REPLY}" | head -1
    rmdir $STATE/at.lock
}
getnv() {  # $1 = modem setting (NV item): prints its value; nothing when the modem does not answer (3 tries)
    for i in 1 2 3; do
        v=$(at "AT+GOOGGETNV=\"$1\"" | sed -n 's/.*,0,"\(.*\)"/\1/p')
        [ -n "$v" ] && { echo "$v"; return; }
        sleep 1
    done
}
nv() {  # $1 = SIM slot (1, 2), $2 = name of a setting for slot 1: its name for that slot
    [ "$1" = 1 ] && { echo "$2"; return; }
    case "$2" in
        NR.*) echo "DS.$2" ;;
        !*) echo "${2%%.*}_DS.${2#*.}" ;;
        *) echo "${2}_DS" ;;
    esac
}

# --- self-check ---------------------------------------------------------------------------------------------------
# For every SIM whose PLMN is listed: does the modem use the module's profile (it reports carrier ID 1911, 5G mode SA+NSA
# and the regional band tables off), and does Android use the module's carrier settings (override file loaded,
# data-centric usage)? The stock database also gives 001-01 SIMs carrier ID 1911 with SA+NSA, but not the tables off.
sim_plmn() { getprop gsm.sim.operator.numeric | awk -F, -v i=$1 '{ print $i }'; }  # $1 = slot: its SIM's PLMN, empty = none
modem_values() {  # $1 = slot: "<carrier ID> <5G mode> <regional band tables>" the modem applied, ? = no answer
    m=$(getnv "$(nv $1 NR.CONFIG.MODE)"); f=$(getnv "$(nv $1 OEM_GFEATURE_ENABLE_FCC_BANDS)")
    set -- $(getnv "$(nv $1 OEM_GFEATURE_CARRIER_ID)" | tr ',' ' ')    # 4 bytes, lowest first: 77,07,00,00 = 1911
    c="?"
    [ $# = 4 ] && case "$4$3$2$1" in *[!0-9A-Fa-f]*) ;; *) c=$((0x$4$3$2$1)) ;; esac
    case "$c" in -1|4294967295) c=none ;; esac
    echo "$c ${m:-?} ${f:-?}"
}
android_values() {  # $1 = slot: "<ICCID> <usage setting> <yes|no: Android loaded the module's carrier settings>"
    r=$(content query --uri content://telephony/siminfo --projection icc_id:usage_setting --where "sim_id=$(($1 - 1))" \
        2>/dev/null | sed -n 's/.*icc_id=\([0-9A-Fa-f]*\), usage_setting=\(-\{0,1\}[0-9]*\).*/\1 \2/p' | head -1)
    l=no    # the override file is loaded when its usage value shows in the phone's persistent overrides
    dumpsys carrier_config 2>/dev/null | awk -v id=$(($1 - 1)) '
        /^Phone Id = / { s = ($4 == id) }
        s && $1 == "mPersistentOverrideConfigs" { o = 1; next }
        s && $1 == "mOverrideConfigs" { o = 0 }
        s && o && $1 == "cellular_usage_setting_int" && $3 == "2" { f = 1 }
        END { exit !f }' && l=yes
    echo "${r:-? ?} $l"
}
finding() {  # $* = one line of the report
    checks="$checks$*
"
}
worse() {  # $1 = 2 (warning) or 3 (error), $2 = status text: kept when it is the worst so far (the first one on a tie)
    [ $1 -gt $worst ] && { worst=$1; status=$2; }
}
check() {  # sets $status (the line in the Magisk app), $checks (one line per finding) and $retry (1 = a failure that
           # may only be early: the modem or Android not done with the SIM yet)
    status=""; checks=""; retry=0; worst=0; ready=""; others=""
    family=$(cut -d' ' -f3 $MODDIR/overlay.stamp 2>/dev/null)
    if [ -n "$family" ]; then
        finding "✓ modem profile $family in place for PLMNs $(echo $plmns)"
    else
        why=$(cat $MODDIR/overlay.none 2>/dev/null); why=${why:-see the boot log}
        case "$why" in
            "no modem profile for modem "*)
                finding "! no modem profile: $why"
                worse 2 "⚠️ No modem profile for modem ${why#no modem profile for modem }: carrier settings and 4G/5G switching only" ;;
            *)
                finding "✗ no modem profile: $why"
                worse 3 "❌ No modem profile: $why" ;;
        esac
    fi
    for slot in 1 2; do
        plmn=$(sim_plmn $slot); [ -n "$plmn" ] || continue
        sim="SIM $(dashed $plmn)"; [ $slot = 2 ] && sim="$sim (slot 2)"
        if ! listed "$plmn"; then
            finding "· SIM $slot $(dashed $plmn): not in plmns.conf"; others="$others, SIM $slot: $(dashed $plmn)"
            continue
        fi
        ok=1
        if [ -n "$family" ]; then
            set -- $(modem_values $slot)
            if [ "$1" = "?" ] || [ "$2" = "?" ] || [ "$3" = "?" ]; then
                finding "! SIM $slot $(dashed $plmn): the modem did not answer (carrier $1, 5G mode $2, regional band tables $3)"
                worse 2 "⚠️ Modem did not answer the check: $family modem profile not confirmed"; ok=0
            elif [ "$1" != $CARRIER_ID ] || [ "$2" != 11 ] || [ "$3" != 00 ]; then
                finding "✗ SIM $slot $(dashed $plmn): modem carrier $1, 5G mode $2, regional band tables $3 (module's profile: $CARRIER_ID, 11, 00)"
                if [ "$1" != $CARRIER_ID ]; then
                    worse 3 "❌ Modem profile not in use for $sim (modem's carrier profile: $1): reboot once; if it stays, tap Action for a report"
                else
                    worse 3 "❌ Modem profile incomplete for $sim (5G mode $2, regional band tables $3): reboot once; if it stays, tap Action for a report"
                fi
                retry=1; ok=0
            else
                finding "✓ SIM $slot $(dashed $plmn): the modem uses the module's profile (carrier $1, 5G SA+NSA, regional band tables off)"
            fi
        fi
        set -- $(android_values $slot)
        if [ "$3" = yes ] && [ "$2" = 2 ]; then
            finding "✓ SIM $slot $(dashed $plmn): Android uses the module's carrier settings, data-centric"
        elif grep -qx "$1" $STATE/pending 2>/dev/null; then
            finding "! SIM $slot $(dashed $plmn): carrier settings written after boot: active after the next reboot"
            worse 2 "⚠️ Reboot once to apply the settings of $sim"; ok=0
        else
            finding "✗ SIM $slot $(dashed $plmn): Android carrier settings loaded: $3, usage setting: $2 (module's: yes, 2)"
            worse 3 "❌ Android does not use the carrier settings of $sim: reboot once; if it stays, tap Action for a report"
            retry=1; ok=0
        fi
        [ $ok = 1 ] && ready="$ready, $sim"
    done
    [ -n "$ready$others" ] || finding "· no SIM ready"
    [ $worst = 0 ] || return 0
    if [ -n "$ready" ]; then status="✅ Working: $family modem profile in use, ${ready#, } ready"
    elif [ -n "$others" ]; then status="ℹ️ No SIM from plmns.conf (${others#, })"
    else status="ℹ️ No SIM ready"
    fi
}
