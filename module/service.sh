#!/system/bin/sh
# Runs at every boot (Magisk late_start service), in parallel with Android starting up, and keeps running.
# 1. Android: carrier settings and data-centric usage for SIMs whose PLMN is in plmns.conf (5G SA, VoLTE, VoNR, ...)
# 2. Modem: allows 5G SA in the modem's NR user preference (the original value is saved for the restore script)
# 3. 4G/5G: follows the network type the user picks and helps the phone onto 5G and keep it there
# 4. Status: the module's line in the Magisk app shows the result of the self-check (checks.sh)
# Log: /data/local/tmp/pixel-5g-enabler.log. State (backups, cell memory): /data/adb/pixel-5g-enabler/
MODDIR=${0%/*}
umask 077                          # module state is private to root
. $MODDIR/checks.sh                # STATE, the PLMN list (listed), modem access (at, getnv), the self-check (check)
LOG=/data/local/tmp/pixel-5g-enabler.log
SLOT=0
NR_ONLY=10000000000000000000      # allowed network types, as binary bitmasks for "cmd phone": NR only
LTE_NR=11000001000000000000       # NR, LTE CA and LTE

log() { echo "$(date '+%F %T') $*" >> $LOG; }
setnv() { at "AT+GOOGSETNV=\"$1\",0,\"$2\"" >/dev/null; }

# --- phone state ---------------------------------------------------------------------------------------------
# Read again and again by the main loop. Every external command is a process start (~20 ms CPU on a Pixel 6a), so
# the helpers use shell built-ins where they can, and the registry is read once per check.
types() {  # allowed network types of slot 1, e.g. "NR" or "LTE|LTE_CA" (the last line of the answer)
    t=$(cmd phone get-allowed-network-types-for-users -s $SLOT 2>/dev/null); echo "${t##*
}"
}
set_types() { cmd phone set-allowed-network-types-for-users -s $SLOT $1 >/dev/null 2>&1; }
read_registry() {  # one dump of Android's registry, slot 1: sets reg (data registration, 0 = in service), conn (data
                   # connection, 2 = connected) and chan (channel of the serving cell); ? = not found
    set -- $(dumpsys telephony.registry 2>/dev/null | awk '
        r == "" && match($0, /mDataRegState=-?[0-9]+/) { r = substr($0, RSTART + 14, RLENGTH - 14) }
        d == "" && match($0, /mDataConnectionState=-?[0-9]+/) { d = substr($0, RSTART + 21, RLENGTH - 21) }
        c == "" && match($0, /mChannelNumber=-?[0-9]+/) { c = substr($0, RSTART + 15, RLENGTH - 15) }
        END { print (r == "" ? "?" : r), (d == "" ? "?" : d), (c == "" ? "?" : c) }')
    reg=$1; conn=$2; chan=$3
}
prop1() { p=$(getprop $1); echo "${p%%,*}"; }     # $1 = property: the value for slot 1 (first of the list)
rat() { prop1 gsm.network.type; }
plmn() { prop1 gsm.sim.operator.numeric; }   # the SIM's PLMN: stable while the RAT changes
wifi_up() { case "$(cmd wifi status 2>/dev/null)" in *"Wifi is connected to"*) true ;; *) false ;; esac; }
data_wanted() { [ "$(cmd settings get global mobile_data 2>/dev/null)" != "0" ] && ! wifi_up; }   # cellular data in use
radio_wanted() { [ "$(cmd settings get global airplane_mode_on 2>/dev/null)" != "1" ]; }
sim_ok() { case "$(prop1 gsm.sim.state)" in LOADED|READY) true ;; *) false ;; esac; }
in_service() {  # data registered, and connected when cellular data is in use (data_wanted only when not connected)
    read_registry
    [ "$reg" = 0 ] && { [ "$conn" = 2 ] || ! data_wanted; }
}
on_5g() { case "$(rat)" in NR*) in_service ;; *) false ;; esac; }
save_nr() {  # the serving cell's channel from the last read_registry, for the cell memory; written when it changes
    case "$chan" in
        "$nr") ;;
        "?") nr="" ;;                      # unknown: no cell key, so nothing is remembered for it
        *) nr=$chan; echo "$nr" > $STATE/last_nr ;;
    esac
}

# --- 1. carrier settings for listed SIMs ------------------------------------------------------------------------
# Written as Android's own per-SIM override files, which the phone process reads when it starts. They are written
# here, early in boot, for every listed SIM Android has seen; a SIM first seen later gets them at the next reboot.
# A file that existed before is backed up so it can be restored.
CC_PKG=com.google.android.carrier
CC_DIR=/data/user_de/0/com.android.phone/files
SIM_DB=/data/user_de/0/com.android.providers.telephony/databases/telephony.db
# The override file: 5G NSA and SA allowed, data-centric usage, the VoLTE, VoNR, video calling and Wi-Fi calling
# switches shown (all off by default), supplementary services over IMS, and IMS first for emergency calls.
override() {  # $1 = carrier-config package version (Android ignores an override file with another version)
    echo "<bundle>"
    echo "<string name=\"__carrier_config_package_version__\">$1</string>"
    echo "<int-array name=\"carrier_nr_availabilities_int_array\" num=\"2\"><item value=\"1\" /><item value=\"2\" /></int-array>"
    echo "<int name=\"cellular_usage_setting_int\" value=\"2\" />"
    for kv in carrier_volte_available_bool=true editable_enhanced_4g_lte_bool=true hide_enhanced_4g_lte_bool=false \
              enhanced_4g_lte_on_by_default_bool=false vonr_enabled_bool=true vonr_setting_visibility_bool=true \
              vonr_on_by_default_bool=false carrier_vt_available_bool=true carrier_wfc_ims_available_bool=true \
              editable_wfc_mode_bool=true editable_wfc_roaming_mode_bool=true carrier_default_wfc_ims_enabled_bool=false \
              carrier_supports_ss_over_ut_bool=true carrier_use_ims_first_for_emergency_bool=true; do
        echo "<boolean name=\"${kv%%=*}\" value=\"${kv#*=}\" />"
    done
    echo "</bundle>"
}
write_override() {  # $1 = ICCID, $2 = Android carrier id; succeeds if the file was (re)written
    name=carrierconfig-$CC_PKG-override-$1-$2.xml
    override "$(cat $STATE/cc_version 2>/dev/null)" > $STATE/cc/new.xml
    cmp -s $STATE/cc/new.xml $CC_DIR/$name && return 1
    if [ ! -f $STATE/cc/$name.orig ] && [ ! -f $STATE/cc/$name.created ]; then
        if [ -f $CC_DIR/$name ]; then cp -p $CC_DIR/$name $STATE/cc/$name.orig; else touch $STATE/cc/$name.created; fi
    fi
    cp $STATE/cc/new.xml $CC_DIR/$name
    chown radio:radio $CC_DIR/$name
    chmod 600 $CC_DIR/$name
    chcon u:object_r:radio_data_file:s0 $CC_DIR/$name
}
db_owner() {  # files of Android's SIM table stay owned by the telephony service (radio), also after an interrupted write
    for f in $SIM_DB $SIM_DB-journal; do
        [ -f $f ] && chown radio:radio $f && chcon u:object_r:radio_data_file:s0 $f
    done
}
data_centric() {  # Android takes a SIM's usage setting from its SIM table, not from override files: set it there
    [ -f $SIM_DB ] || return
    $MODDIR/bin/sqlite3 -readonly -separator ' ' $SIM_DB \
        "select icc_id, usage_setting, mcc_string || mnc_string from siminfo where icc_id <> '' and usage_setting <> 2;" \
        2>/dev/null | while read -r iccid usage mccmnc; do
        listed "$mccmnc" || continue
        [ -f $STATE/cc/$iccid.usage ] || echo "$usage" > $STATE/cc/$iccid.usage
        $MODDIR/bin/sqlite3 $SIM_DB ".timeout 3000" "update siminfo set usage_setting = 2 where icc_id = '$iccid';" \
            && log "data-centric usage set for SIM $mccmnc ($iccid)"
        db_owner
    done
}
early_overrides() {  # all SIMs in Android's SIM table (read before the telephony service opens it)
    [ -f $SIM_DB ] && [ -f $STATE/cc_version ] || return
    $MODDIR/bin/sqlite3 -readonly -separator ' ' $SIM_DB \
        "select icc_id, carrier_id, mcc_string || mnc_string from siminfo where icc_id <> '';" 2>/dev/null |
    while read -r iccid cid mccmnc; do
        listed "$mccmnc" && write_override "$iccid" "$cid" && log "carrier settings written for SIM $mccmnc ($iccid)"
    done
    rm -f $STATE/cc/new.xml
}
check_overrides() {  # active SIMs; also follows updates of the carrier-config package
    version=$(dumpsys package $CC_PKG | grep -m1 -oE 'versionCode=[0-9]+' | cut -d= -f2)
    [ -n "$version" ] && [ "$version" != "$(cat $STATE/cc_version 2>/dev/null)" ] && echo "$version" > $STATE/cc_version
    content query --uri content://telephony/siminfo --projection icc_id:carrier_id:mcc_string:mnc_string \
        --where "sim_id>=0" 2>/dev/null | while read -r row; do
        iccid=$(echo "$row" | sed -n 's/.*icc_id=\([0-9A-Fa-f]*\).*/\1/p')
        cid=$(echo "$row" | sed -n 's/.*carrier_id=\(-\{0,1\}[0-9]*\).*/\1/p')
        mccmnc=$(echo "$row" | sed -n 's/.*mcc_string=\([0-9]*\), mnc_string=\([0-9]*\).*/\1\2/p')
        [ -n "$iccid" ] && [ -n "$cid" ] && listed "$mccmnc" || continue
        write_override "$iccid" "$cid" || continue
        log "carrier settings written for SIM $mccmnc ($iccid); active after the next reboot"
        echo "$iccid" >> $STATE/pending        # for the status: this SIM waits for a reboot
    done
    rm -f $STATE/cc/new.xml
}

# --- 4. status in the Magisk app ----------------------------------------------------------------------------------
# The self-check runs at boot and after a SIM change; a note is added while the 4G/5G switching uses its fallback.
set_description() {  # $1 = text; written only when it changes, never over the module.prop of an installed update
    [ "$1" != "$shown" ] && [ ! -f $MODDIR/update ] && grep -q '^id=' $MODDIR/module.prop 2>/dev/null || return 0
    { grep -v '^description=' $MODDIR/module.prop; echo "description=$1"; } > $MODDIR/module.prop.new \
        && chmod 644 $MODDIR/module.prop.new && mv -f $MODDIR/module.prop.new $MODDIR/module.prop && shown=$1
}
show() { set_description "$status${note:+ · $note}"; }    # the status, plus the 4G/5G note (go_5g) if there is one
update_status() {  # a failure that may only be early is checked again for up to 20 s
    for i in $(seq 1 10); do check; [ $retry = 0 ] && break; sleep 2; done
    [ "$status" != "$logged" ] && { log "status: $status"; logged=$status; }
    show
}

mkdir -p $STATE/nv $STATE/cc
rmdir $STATE/at.lock 2>/dev/null
rm -f $STATE/pending                # SIMs whose carrier settings wait for a reboot (check_overrides)
status="⏳ Starting…"; show
[ -f $LOG ] && mv -f $LOG $LOG.1    # keep the previous boot's log
echo "$(date '+%F %T') start ($(grep '^version=' $MODDIR/module.prop)), PLMNs: $(echo $plmns)" > $LOG
chmod 644 $LOG $LOG.1 2>/dev/null   # readable without root
early_overrides
data_centric
# Wait for the end of the boot, then up to 2 minutes for the SIM.
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
for i in $(seq 1 60); do case "$(getprop gsm.sim.state)" in *LOADED*) break ;; esac; sleep 2; done
# The modem firmware version, for post-fs-data.sh when it cannot read the firmware partition at a later boot.
b=$(getprop gsm.version.baseband | cut -d, -f1)
[ -n "$b" ] && [ "$b" != "$(cat $STATE/baseband 2>/dev/null)" ] && echo "$b" > $STATE/baseband

# --- 2. NR user preference: 11 = SA and NSA allowed (some builds default to NSA only) -------------------------
changed=""
for key in NR.CONFIG.USER.PREF.MODE DS.NR.CONFIG.USER.PREF.MODE; do
    value=$(getnv $key)
    [ -n "$value" ] && [ "$value" != "11" ] || continue
    [ -f $STATE/nv/$key ] || echo "$value" > $STATE/nv/$key
    setnv $key 11
    changed="$changed $key"
done
# The modem uses the new value at its next network selection (the first network type change below).
[ -n "$changed" ] && log "NR user preference set to SA+NSA:$changed"

# The profile switches the regional band tables off and no stock profile switches them on again: the restore script
# writes back the factory value (01 on every phone seen) when the module is disabled or removed.
if [ -f $MODDIR/overlay.stamp ]; then
    for key in OEM_GFEATURE_ENABLE_FCC_BANDS OEM_GFEATURE_ENABLE_FCC_BANDS_DS; do
        [ -f $STATE/nv/$key ] || echo 01 > $STATE/nv/$key
    done
fi

check_overrides
sim_seen=$(getprop gsm.sim.operator.numeric); sim_last=$sim_seen
update_status

# --- 3. 4G/5G ---------------------------------------------------------------------------------------------------
# "NR only" is first tried as it is. Some modems send an incomplete radio capability in NR-only mode, and some gNBs
# then drop them every few seconds. The fallback is "NR first, LTE allowed": network type LTE+NR and a new
# registration (radio off and on), so the network asks the modem for its full capability.
# Cells that needed the fallback are remembered ($STATE/fallback) and get it at once next time. A cell is remembered
# only when "NR only" found its NR cell but 5G did not hold, in two different switches (one failure can be a passing
# radio problem); not when no NR cell was found at all (no coverage, network down).
user_changed() {  # the user picked a type without NR while the module was switching
    case "|$(types)|" in *"|NR|"*) false ;; *) true ;; esac
}
interrupted() { ! radio_wanted || ! sim_ok || user_changed; }   # stop switching: airplane mode, no SIM, user type
now() { date '+%m-%d %H:%M:%S.000'; }   # logcat time
churn() {  # $1 = logcat time: the connection was dropped at least twice since then (a rejected UE retries every ~5 s;
           # the radio reports an empty channel list at each drop, also when Android never shows the registration)
    [ "$(logcat -b radio -d -T "$1" 2>/dev/null | grep -c "UNSOL_PHYSICAL_CHANNEL_CONFIG \[\] \[PHONE$SLOT\]")" -ge 2 ]
}
find_nr() {  # $1 = max seconds (a modem that does not know the cell yet, e.g. after a flash, scans up to ~40 s),
             # $2 = logcat time; returns 0 = on NR, 1 = not found or interrupted, 2 = rejected by the cell (churn)
    end=$(( $(date +%s) + $1 )); i=0
    while [ $(date +%s) -lt $end ]; do
        case "$(rat)" in NR*) return 0 ;; esac
        interrupted && return 1
        i=$((i + 1)); [ $((i % 4)) -eq 0 ] && churn "$2" && return 2
        sleep 0.5
    done
    return 1
}
wait_5g() {  # $1 = max seconds; stops early when interrupted
    end=$(( $(date +%s) + $1 ))
    while [ $(date +%s) -lt $end ]; do on_5g && return 0; interrupted && return 1; sleep 0.5; done
    return 1
}
reregister() {  # radio off and on: the phone registers again from scratch, so the network asks for the modem's
                # current radio capability (some modems do not report a changed one, TS 24.501 5.5.1.3.2), and a
                # running registration back-off is reset. "On" is repeated until the modem confirms it; the radio
                # stays off only when airplane mode was switched on meanwhile (then Android owns the radio state).
    radio_wanted || return 1
    at "AT+CFUN=4" >/dev/null; sleep 2
    for i in $(seq 1 10); do
        radio_wanted || { log "airplane mode switched on: radio left off"; return 1; }
        at "AT+CFUN=1" >/dev/null
        case "$(at 'AT+CFUN?' '^\+CFUN:|ERROR')" in *"CFUN: 1"*) return 0 ;; esac
        sleep 2
    done
    log "warning: the modem did not confirm that its radio is on"
}
stable_5g() {  # on 5G for 12 s without churn (Android keeps showing 5G during churn; a normal idle release is one drop)
    since=$(now)
    for i in $(seq 1 12); do on_5g || return 1; sleep 1; done
    ! churn "$since"
}
fallback() {
    # 1. LTE+NR ("NR only" chosen; another type the user picked stays as it is) and register again.
    fb_types=""
    interrupted && return 1
    [ "$choice" = "$NR_ONLY" ] && { set_types $LTE_NR; fb_types=$(types); }
    reregister || return 1
    wait_5g 45 && return 0
    # 2. Still on LTE ("NR only" chosen): NR only until the modem finds the NR cell, then LTE+NR and register again.
    [ "$choice" = "$NR_ONLY" ] || return 1
    interrupted && return 1
    set_types $NR_ONLY; find_nr 45 "$(now)"
    interrupted && return 1
    set_types $LTE_NR; reregister || return 1
    wait_5g 30
}
types_after_switch() {  # $1 = types before go_5g; keep a type the user picked meanwhile for the next loop
    cur=$(types)
    case "$cur" in "$1"|"$fb_types") echo "$cur" ;; *) echo "$1" ;; esac
}
remembered() {  # $1 = "PLMN:NR channel"; a key with an empty or unknown part is never looked up or stored
    case "$1" in :*|*:|*:-1) return 1 ;; esac
    grep -qx "$1" $STATE/fallback 2>/dev/null
}
remember() {  # NR only failed on this cell; a single failure can be a passing radio problem, so the cell goes to the
              # fallback list only when it fails again in a later switch ($STATE/suspect holds the first failures)
    case "$1" in :*|*:|*:-1) return ;; esac
    remembered "$1" && return
    if grep -qx "$1" $STATE/suspect 2>/dev/null; then
        echo "$1" >> $STATE/fallback; not_suspect "$1"
        log "cell $1: NR only failed twice, NR first with LTE allowed from now on"
    else
        echo "$1" >> $STATE/suspect
    fi
}
not_suspect() {  # NR only worked on this cell (or it is in the fallback list now)
    [ -f $STATE/suspect ] || return 0
    grep -vx "$1" $STATE/suspect > $STATE/suspect.tmp; mv -f $STATE/suspect.tmp $STATE/suspect
}
go_5g() {  # get onto 5G with the chosen network type: "NR only" as it is (not on a remembered cell), then the
           # fallback; logs the result and sets the status note when the module changed the network type
    t0=$(date +%s); fb_types=""; unstable=0
    if interrupted; then log "airplane mode, no SIM or no NR in the network type: nothing done"; return 1; fi
    cell="$(plmn):$nr"
    if [ "$choice" = "$NR_ONLY" ] && ! remembered "$cell"; then
        since=$(now); find_nr 45 "$since"; found=$?
        if [ $found = 0 ] && wait_5g 15 && stable_5g; then
            save_nr
            not_suspect "$(plmn):$nr"
            log "5G (NR only) after $(( $(date +%s) - t0 ))s"
            return 0
        fi
        if interrupted; then log "stopped: airplane mode, no SIM or network type changed by the user"; return 1; fi
        if [ $found = 1 ]; then
            log "no NR cell found in NR-only mode after $(( $(date +%s) - t0 ))s: NR first, LTE allowed"
        else
            unstable=1
            log "no stable 5G in NR-only mode after $(( $(date +%s) - t0 ))s: NR first, LTE allowed"
        fi
    fi
    if fallback; then
        save_nr
        cell="$(plmn):$nr"
        [ $unstable = 1 ] && remember "$cell"
        log "5G (NR first, LTE allowed) after $(( $(date +%s) - t0 ))s on cell $cell"
    elif interrupted; then
        log "stopped: airplane mode, no SIM or network type changed by the user"
    else
        log "5G not reached after $(( $(date +%s) - t0 ))s (rat=$(rat))"
    fi
    [ -n "$fb_types" ] && note="NR only did not work here: NR first, LTE allowed"    # the module changed the type
}
# Watchdog ("NR only" chosen): on another RAT for 20 s, or without service/data for 45 s -> back to 5G (at most 5
# times in a row; the count starts again after 10 minutes on 5G). Paused while the radio is off (airplane mode) or
# there is no usable SIM. Checked every 2 s; every 10 s after a minute on 5G and while paused (battery): then a drop
# is noticed up to 8 s later, and the 20/45 s count only from the first check that sees it.
watchdog() {  # one check: updates good (seconds on 5G), wrong, down and every (seconds until the next check)
    if on_5g; then
        wrong=0; down=0; good=$((good + wd)); save_nr
        [ $good -ge 600 ] && retries=0
        if [ $good -ge 60 ]; then every=10; else every=2; fi
    elif ! radio_wanted || ! sim_ok; then wrong=0; down=0; every=10
    elif in_service; then wrong=$((wrong + 2)); good=0; every=2
    else down=$((down + 2)); good=0; every=2
    fi
    wd=0
}
watch_tick() {  # every 2 s while "NR only" is chosen: a check when one is due; true = time to go back to 5G
    wd=$((wd + 2)); [ $wd -ge $every ] && watchdog
    { [ $wrong -ge 20 ] || [ $down -ge 45 ]; } && [ $retries -lt 5 ]
}

# Main loop, every 2 s: follow the network type the user picks (go_5g when it allows NR), and with "NR only" the
# watchdog. Every 10 s: a SIM change runs the carrier settings and the self-check again.
for i in $(seq 1 45); do in_service && break; sleep 1; done      # let the boot registration settle
nr=$(cat $STATE/last_nr 2>/dev/null)
last=""; choice=""; wrong=0; down=0; retries=0; good=0; wd=0; every=2; tick=0
while true; do
    current=$(types)
    if [ -n "$current" ] && [ "$current" != "$last" ]; then
        note=""; good=0; wd=0; every=2
        case "|$current|" in
            "|NR|") choice=$NR_ONLY; retries=0; log "network type: NR only"; go_5g ;;
            *"|NR|"*) choice=""; retries=0; log "network type: $current"; on_5g || go_5g ;;
            *) choice=""; log "network type: $current (4G)" ;;
        esac
        last=$(types_after_switch "$current"); wrong=0; down=0
    elif [ "$choice" = "$NR_ONLY" ] && [ -n "$current" ] && watch_tick; then
        retries=$((retries + 1))
        log "watchdog: not on 5G (rat=$(rat)), retry $retries/5"
        go_5g; wrong=0; down=$((-30 * retries)); good=0; every=2; last=$(types_after_switch "$last")
    fi
    tick=$((tick + 1))
    if [ $((tick % 5)) -eq 0 ]; then    # every 10 s: SIM change (status, carrier settings)
        sim_now=$(getprop gsm.sim.operator.numeric)
        if [ "$sim_now" != "$sim_seen" ] && [ "$sim_now" = "$sim_last" ]; then    # changed, and the same 10 s later
            sim_seen=$sim_now; check_overrides; update_status
        fi
        sim_last=$sim_now
    fi
    show
    # every 10 minutes: carrier-config package updates, and a SIM swap that kept the PLMN
    [ $((tick % 300)) -eq 0 ] && check_overrides
    sleep 2
done
