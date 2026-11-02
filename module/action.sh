#!/system/bin/sh
# The module's "Action" button in the Magisk app (Magisk 28+): checks the module's work, shows the result and writes a
# report to the Download folder (to send with a problem report). Read-only: changes nothing on the phone.
# From a computer: adb shell su -c sh /data/adb/modules/pixel-5g-enabler/action.sh
MODDIR=/data/adb/modules/pixel-5g-enabler          # Magisk starts it as ./action.sh in the module folder
. $MODDIR/checks.sh                                # the PLMN list, modem access, the self-check (check)
LOGS=/data/local/tmp/pixel-5g-enabler
CC_DIR=/data/user_de/0/com.android.phone/files
NAME=pixel-5g-enabler-report-$(date +%Y%m%d-%H%M%S).txt

mask() {  # ICCID, IMSI and IMEI (14 or more digits: the first 6 stay) and phone numbers
    sed -E 's/([0-9]{6})[0-9]{8,}/\1********/g; s/\+[0-9]{7,}/+********/g'
}
value() {  # $1 = modem setting: its value, "unknown" (not in this modem) or "no answer"
    for i in 1 2 3; do r=$(at "AT+GOOGGETNV=\"$1\""); [ -n "$r" ] && break; done
    case "$r" in
        *,0,\"*) echo "$r" | sed 's/.*,0,"\(.*\)"/\1/' ;;
        *Invalid*|*ERROR*) echo unknown ;;      # "+GOOGGETNV: Invalid NV id or NV name"
        *) echo "no answer" ;;
    esac
}
section() { echo; echo "== $*"; }
wrap() {  # lines for the Magisk console, which does not wrap them: at most 52 characters, broken at spaces
    awk -v w=52 '{
        s = $0; p = ""
        while (length(p s) > w) {
            n = w - length(p); i = n
            while (i > 0 && substr(s, i, 1) != " ") i--
            if (i == 0) i = n
            print p substr(s, 1, i); s = substr(s, i + 1); p = "  "
        }
        print p s
    }'
}
summary() {
    echo "Pixel 5G Enabler $(sed -n 's/^version=//p' $MODDIR/module.prop), $(date '+%F %T %Z')"
    echo "Phone:  $(getprop ro.product.model) ($(getprop ro.product.device)), Android $(getprop ro.build.version.release) ($(getprop ro.build.id), patch $(getprop ro.build.version.security_patch))"
    echo "Modem:  ${fw:-unknown} (profile ${family:-none})"
    echo "Root:   $(magisk -v 2>/dev/null || echo unknown)"
    echo "Module: $mod, PLMNs $(echo $plmns)"
    echo
    echo "$status"
    printf '%s' "$checks"
}

fw=$(readlink /mnt/vendor/modem_img/images/default 2>/dev/null)
[ -n "$fw" ] || fw=$(getprop gsm.version.baseband | cut -d, -f1)
mod=enabled
[ -f $MODDIR/disable ] && mod=disabled
[ -f $MODDIR/remove ] && mod="removed at the next reboot"
[ -f $MODDIR/update ] && mod="$mod, update installed (used after the next reboot)"
echo "Checking..."
check
summary | mask | wrap
echo
echo "Writing the report..."
out=/sdcard/Download/$NAME
touch $out 2>/dev/null || out=/data/local/tmp/$NAME
{
    summary
    section "Modem settings (AT+GOOGGETNV)"
    for slot in 1 2; do
        [ $slot = 1 ] || [ -n "$(sim_plmn 2)" ] || continue
        echo "SIM slot $slot:"
        for k in OEM_GFEATURE_CARRIER_ID NR.CONFIG.MODE NR.CONFIG.USER.PREF.MODE UECAPA_NR_RF_BAND_FR1_BM \
                 UECAPA_NR_RF_BAND_FR2_BM OEM_GFEATURE_ENABLE_FCC_BANDS !SAEL3.SAE_UE_OPERATION_MODE \
                 !SAEL3.SAE_VOICE_DOMAIN_PREF OEM_GFEATURE_RAT_ORDER_SEARCH_TBL NASU.AP.NET.MODE; do
            echo "  $(nv $slot $k) = $(value "$(nv $slot $k)")"
        done
    done
    echo "radio: $(at 'AT+CFUN?' '^\+CFUN:|ERROR')"

    section "Android"
    echo "SIM state: $(getprop gsm.sim.state); SIM PLMN: $(getprop gsm.sim.operator.numeric); network: $(getprop gsm.operator.numeric) $(getprop gsm.network.type)"
    echo "airplane mode: $(settings get global airplane_mode_on); mobile data: $(settings get global mobile_data); network type of slot 1: $(cmd phone get-allowed-network-types-for-users -s 0 2>/dev/null | tail -1)"
    echo "SIM table (active SIMs):"
    content query --uri content://telephony/siminfo --projection sim_id:mcc_string:mnc_string:carrier_id:usage_setting:icc_id \
        --where "sim_id>=0" 2>/dev/null | sed 's/^/  /'
    echo "carrier settings files:"
    ls -l $CC_DIR 2>/dev/null | grep override | sed 's/^/  /'
    echo "carrier settings overrides in use:"
    dumpsys carrier_config 2>/dev/null | awk '
        /^Phone Id = / { print "  " $0; next }
        /^ *m[A-Za-z]+ *:/ { o = ($1 == "mPersistentOverrideConfigs" || $1 == "mOverrideConfigs"); if (o) print "  " $0; next }
        o { print "  " $0 }'
    echo "registration:"
    dumpsys telephony.registry 2>/dev/null | grep -E '^ *(Phone Id=|mServiceState=|mSignalStrength=|mPhysicalChannelConfigs=)' \
        | sed 's/^ */  /' | cut -c1-2000

    section "Module state"
    echo "overlay: $(cat $MODDIR/overlay.stamp 2>/dev/null || echo "none: $(cat $MODDIR/overlay.none 2>/dev/null)")"
    cmp -s /vendor/firmware/carrierconfig/cfg.db $MODDIR/system/vendor/firmware/carrierconfig/cfg.db 2>/dev/null \
        && echo "overlay mounted: yes" || echo "overlay mounted: no"
    for f in baseband cc_version last_nr fallback suspect pending; do
        [ -f $STATE/$f ] && echo "$f: $(paste -sd' ' $STATE/$f)"
    done
    echo "stock modem values to put back when disabled:$(for f in $STATE/nv/*; do [ -f "$f" ] && printf ' %s=%s' "${f##*/}" "$(cat "$f")"; done)"
    echo "carrier settings backups: $(ls $STATE/cc 2>/dev/null | paste -sd' ' -)"
    echo "plmns.conf:"; sed 's/^/  /' $MODDIR/plmns.conf

    for f in $LOGS-boot.log.1 $LOGS-boot.log $LOGS.log.1 $LOGS.log; do
        section "$f"
        if [ -f $f ]; then cat $f; else echo "(none)"; fi
    done

    section "Radio log: network type, radio power, registration, data calls (the log holds only the last minutes)"
    logcat -b radio -d 2>/dev/null | awk '/> SET_ALLOWED_NETWORK_TYPES_BITMAP|[<>] RADIO_POWER|< DATA_REGISTRATION_STATE|DATA_REGISTRATION_STATE [{]|UNSOL_PHYSICAL_CHANNEL_CONFIG [[][]]|SETUP_DATA_CALL,|DEACTIVATE_DATA_CALL|USAGE_SETTING|N1_MODE|reasonForDenial ?[:=] ?[A-MO-Z]|rejectCause ?[:=] ?[1-9]/' \
        | tail -300 | cut -c1-400
} 2>&1 | mask > $out
echo "Report saved in ${out%/*}:"
echo "  $NAME"
echo "(ICCID, IMSI, IMEI and phone numbers are masked.)" | wrap
