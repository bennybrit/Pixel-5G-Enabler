#!/system/bin/sh
# Installed by the Pixel 5G Enabler module into /data/adb/service.d/ (Magisk runs it at every boot, even when the
# module is disabled).
# 1. Module disabled or removed: puts back the phone's own settings (carrier-settings files, usage setting, modem NR
#    preference); after a removal it also deletes the module's state and itself. While the module is disabled, its
#    description in the Magisk app says so.
# 2. Every boot: makes sure the radio of SIM slot 1 came up (radio_check).
MOD=/data/adb/modules/pixel-5g-enabler
umask 077
STATE=/data/adb/pixel-5g-enabler
LOG=/data/local/tmp/pixel-5g-enabler.log
CC_DIR=/data/user_de/0/com.android.phone/files

log() { echo "$(date '+%F %T') $*" >> $LOG; }

AT_REPLY='^\+GOOG|^OK|ERROR'
at() {  # $1 = AT command, $2 = pattern of the reply line wanted; one command at a time (lock shared with service.sh)
    n=0; locked=1
    until mkdir $STATE/at.lock 2>/dev/null; do      # a lock older than 10 s is stale
        sleep 0.2; n=$((n + 1))
        [ $n -eq 50 ] && rmdir $STATE/at.lock 2>/dev/null
        [ $n -ge 75 ] && { locked=0; break; }
    done
    timeout 5 sh -c "printf '%s\r' '$1' > /dev/umts_router & cat /dev/umts_router" 2>/dev/null \
        | tr -d '\r' | grep -E "${2:-$AT_REPLY}" | head -1
    [ $locked = 1 ] && rmdir $STATE/at.lock
}

# --- radio check ------------------------------------------------------------------------------------------------
# On some boots the radio of SIM slot 1 stays off although Android wants it on, mostly when the modem's carrier
# profile changed with the boot (module enabled, disabled or removed): Android's first "radio on" fails, or a late
# "radio on" event makes Android believe it is on. Android does not retry, so the phone has no service until
# airplane mode is toggled. Within the first two minutes after boot: if the modem keeps its radio off for 10 s
# while Android wants it on, switch it on; if Android still shows it off, toggle airplane mode once.
wants_radio() {  # Android wants the slot 1 radio on: no airplane mode, desired power on, no power-off reason
    [ "$(settings get global airplane_mode_on 2>/dev/null)" = "1" ] && return 1
    [ "$(dumpsys activity service com.android.phone 2>/dev/null | awk '
        /^ *mPhoneId=/ { p = $1 }
        p == "mPhoneId=0" && /^ *mDesiredPowerState=/ && d == "" { d = $1 }
        p == "mPhoneId=0" && /^ *mRadioPowerOffReasons=/ && r == "" { r = $1 }
        END { print d, r }')" = "mDesiredPowerState=true mRadioPowerOffReasons=[]" ]
}
modem_radio() { at 'AT+CFUN?' '^\+CFUN:|ERROR' | sed -n 's/.*CFUN: *\([0-9]*\).*/\1/p'; }   # 1 = on, 0/4 = off
android_shows_off() { dumpsys telephony.registry 2>/dev/null | grep -m1 "mServiceState=" | grep -q "mDataRegState=3"; }
radio_check() {
    sleep 20; off=0
    for i in $(seq 1 24); do
        cfun=$(modem_radio)
        case "$cfun" in 0|4) if wants_radio; then off=$((off + 1)); else off=0; fi ;; *) off=0 ;; esac
        if [ $off -ge 3 ]; then
            log "radio check: the radio of SIM slot 1 stayed off after boot (modem +CFUN: $cfun, Android shows it $(android_shows_off && echo off || echo on)): switching it on"
            at "AT+CFUN=1" >/dev/null
            for j in $(seq 1 10); do
                sleep 2
                [ "$(modem_radio)" = "1" ] && ! android_shows_off && { log "radio check: radio on"; return 0; }
            done
            wants_radio || return 0          # airplane mode was switched on meanwhile
            log "radio check: Android still shows the radio off: airplane mode on and off"
            cmd connectivity airplane-mode enable; sleep 4; cmd connectivity airplane-mode disable
            return 0
        fi
        sleep 5
    done
}

if [ -d $MOD ] && [ ! -f $MOD/disable ] && [ ! -f $MOD/remove ]; then    # module enabled: only the radio check
    until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
    radio_check
    exit 0
fi

# --- module disabled or removed: put back the phone's own settings ---------------------------------------------
# Carrier-settings files: put back the backed-up originals, delete the ones the module created.
# Done right away, before Android's phone process starts and reads them.
for f in $STATE/cc/*.orig $STATE/cc/*.created; do
    [ -f "$f" ] || continue
    name=$(basename "$f"); name=${name%.orig}; name=${name%.created}
    case "$f" in
        *.orig) cp -p "$f" $CC_DIR/$name; chcon u:object_r:radio_data_file:s0 $CC_DIR/$name; log "restore: restored $name" ;;
        *) rm -f $CC_DIR/$name; log "restore: removed $name" ;;
    esac
    rm -f "$f"
done
# Usage setting (data-centric) in Android's SIM table: put back the original values.
SIM_DB=/data/user_de/0/com.android.providers.telephony/databases/telephony.db
for f in $STATE/cc/*.usage; do
    [ -f "$f" ] && [ -f $SIM_DB ] && [ -x $STATE/sqlite3 ] || continue
    iccid=$(basename "$f" .usage); usage=$(cat "$f"); [ -n "$usage" ] || usage=-1   # -1 = Android's "not set"
    $STATE/sqlite3 $SIM_DB ".timeout 3000" "update siminfo set usage_setting = $usage where icc_id = '$iccid';" \
        && log "restore: usage setting of SIM $iccid back to $usage"
    for d in $SIM_DB $SIM_DB-journal; do      # keep the files owned by the telephony service
        [ -f $d ] && chown radio:radio $d && chcon u:object_r:radio_data_file:s0 $d
    done
    rm -f "$f"
done

# Modem NR preference: write back the original values (the modem answers once Android has started).
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
for f in $STATE/nv/*; do
    [ -f "$f" ] || continue
    key=$(basename "$f"); value=$(cat "$f")
    for i in $(seq 1 30); do
        at "AT+GOOGSETNV=\"$key\",0,\"$value\"" | grep -q OK && break
        sleep 2
    done
    log "restore: $key back to $value"; rm -f "$f"
done

# Module disabled: its description in the Magisk app says so (written like service.sh writes the status).
if [ -f $MOD/disable ] && [ ! -f $MOD/remove ] && [ ! -f $MOD/update ] && grep -q '^id=' $MOD/module.prop 2>/dev/null; then
    { grep -v '^description=' $MOD/module.prop; echo "description=⏸️ Disabled: phone's own settings restored"; } \
        > $MOD/module.prop.new && chmod 644 $MOD/module.prop.new && mv -f $MOD/module.prop.new $MOD/module.prop
fi

radio_check

# Module removed (and not being installed again): also remove the module's state and this script.
if [ ! -d $MOD ] && [ ! -d /data/adb/modules_update/pixel-5g-enabler ]; then
    rm -rf $STATE
    log "restore: module removed: state and restore script deleted"
    rm -f "$0"
fi
