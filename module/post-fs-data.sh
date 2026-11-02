#!/system/bin/sh
# Runs at every boot, before Magisk mounts the module.
# Builds the modem profile overlay. The Pixel radio software picks the modem's carrier profile by the SIM's PLMN from
# /vendor/firmware/carrierconfig/cfg.db. The overlay is a copy of this phone's own cfg.db in which the PLMNs of
# plmns.conf point to the module's profile for this phone's modem family; Magisk mounts it over the original.
# Log: /data/local/tmp/pixel-5g-enabler-boot.log
MODDIR=${0%/*}
umask 022
LOG=/data/local/tmp/pixel-5g-enabler-boot.log
SQL=$MODDIR/bin/sqlite3
VENDOR=/vendor/firmware/carrierconfig
OUT=$MODDIR/system/vendor/firmware/carrierconfig
STAMP=$MODDIR/overlay.stamp
CARRIER_ID=1911    # stock "Test Network" carrier ID: the modem only accepts carrier IDs it knows

log() { echo "$(date '+%F %T') $*" >> $LOG; }

# No overlay: the modem keeps its stock profile; the rest of the module still works.
no_overlay() {
    log "no modem overlay: $*"
    rm -rf "$MODDIR/system" "$STAMP"
    echo "$*" > $MODDIR/overlay.none    # the reason, for the status in the Magisk app (checks.sh)
    exit 0
}

[ -f $LOG ] && mv -f $LOG $LOG.1    # keep the previous boot's log
echo "$(date '+%F %T') boot ($(grep '^version=' $MODDIR/module.prop))" > $LOG
rm -f $MODDIR/overlay.none

# Modem family, from the modem firmware itself, so new phones with a known modem need no module update:
# g5123 = Exynos 5123 (Pixel 6/6 Pro/6a), g5300 = Exynos 5300 (Pixel 7/8 series, 9a), g5400 = Exynos 5400 (Pixel 9 and
# 10 series). The firmware partition is mounted before this script runs: images/default -> e.g. g5400i-260604-...
# Fallback: the baseband version Android reported at the previous boot (saved by service.sh and at install).
family_of() {  # $1 = modem firmware version; prints the profile family, nothing for an unknown modem
    case "$1" in
        g5123*) echo g5123 ;;
        g5300*) echo g5300 ;;
        g5400*) echo g5400 ;;
    esac
}
fw=$(readlink /mnt/vendor/modem_img/images/default 2>/dev/null)
[ -n "$(family_of "$fw")" ] || fw=$(cat /data/adb/pixel-5g-enabler/baseband 2>/dev/null)
family=$(family_of "$fw")
PROFILE=$MODDIR/profiles/$family
[ -n "$family" ] && [ -d "$PROFILE" ] || no_overlay "no modem profile for modem '${fw:-unknown}'"

plmns=$(sed 's/#.*//' $MODDIR/plmns.conf 2>/dev/null | tr -cd '0-9\n' | grep -E '^[0-9]{5,6}$' | sort -u)
[ -n "$plmns" ] || no_overlay "plmns.conf has no PLMN"
[ -f $VENDOR/cfg.db ] || no_overlay "$VENDOR/cfg.db not found"
[ -x $SQL ] || no_overlay "bin/sqlite3 missing"

# Profile files are named after their own sha256: check them all.
manifest=$(ls $PROFILE/manifests)
for f in $PROFILE/manifests/* $PROFILE/confseqs/*; do
    [ "$(sha256sum "$f" | cut -c1-40)" = "${f##*/}" ] || no_overlay "corrupt profile file $f"
done

# Rebuild only when something changed (stock database, module version, profile or PLMN list).
state="$(sha256sum $VENDOR/cfg.db | cut -c1-64) $(grep '^versionCode=' $MODDIR/module.prop) $family $manifest $(echo $plmns)"
if [ -f $OUT/cfg.db ] && [ "$(cat $STAMP 2>/dev/null)" = "$state" ]; then
    log "overlay unchanged: $family profile (modem $fw) for PLMNs $(echo $plmns)"
    exit 0
fi

rm -rf "$MODDIR/system"
mkdir -p $OUT/manifests $OUT/confseqs
cp $PROFILE/manifests/* $OUT/manifests/
cp $PROFILE/confseqs/* $OUT/confseqs/
cp $VENDOR/cfg.db $OUT/cfg.db || no_overlay "cannot copy cfg.db"

[ "$($SQL $OUT/cfg.db "select count(*) from confmap where carrier_id='$CARRIER_ID';")" = "1" ] \
    || no_overlay "stock cfg.db has no carrier ID $CARRIER_ID"
sql="update confmap set confman='$manifest' where carrier_id='$CARRIER_ID';"
for p in $plmns; do
    sql="$sql delete from carrier_info where mccmnc='$p';"
    sql="$sql insert into carrier_info values ($CARRIER_ID,'$p','%','%',NULL,'%','%',NULL,NULL,NULL);"
done
$SQL $OUT/cfg.db "begin; $sql commit;" || no_overlay "cannot update cfg.db"

# Verify the result before letting the modem use it.
check=$($SQL $OUT/cfg.db "pragma integrity_check;")
rows=$($SQL $OUT/cfg.db "select count(*) from carrier_info where carrier_id=$CARRIER_ID;")
mapped=$($SQL $OUT/cfg.db "select confman from confmap where carrier_id='$CARRIER_ID';")
[ "$check" = "ok" ] && [ "$rows" -ge "$(echo "$plmns" | wc -l)" ] && [ "$mapped" = "$manifest" ] \
    || no_overlay "verification failed (integrity=$check rows=$rows profile=$mapped)"

chmod 755 $OUT $OUT/manifests $OUT/confseqs
chmod 644 $OUT/cfg.db $OUT/manifests/* $OUT/confseqs/*
chcon -R u:object_r:vendor_fw_file:s0 $OUT
echo "$state" > $STAMP
log "overlay built: $family profile $manifest (modem $fw) for PLMNs $(echo $plmns)"
