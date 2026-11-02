# Runs once when the module zip is installed in Magisk ($MODPATH = the new module folder). Checks the phone, keeps
# the user's plmns.conf and installs the restore script.
ui_print "- Pixel 5G Enabler"
[ -c /dev/umts_router ] || abort "! No Exynos modem found: this module supports Pixels with a Samsung (Exynos) modem only."
[ -f /vendor/firmware/carrierconfig/cfg.db ] || abort "! /vendor/firmware/carrierconfig/cfg.db not found."

set_perm_recursive $MODPATH 0 0 0755 0644
for f in bin/sqlite3 post-fs-data.sh service.sh action.sh uninstall.sh pixel-5g-enabler-restore.sh; do set_perm $MODPATH/$f 0 0 0755; done
$MODPATH/bin/sqlite3 -version >/dev/null 2>&1 || abort "! The bundled sqlite3 does not run on this phone."

# The modem profile is chosen by the modem firmware (see post-fs-data.sh), not by the phone model.
fw=$(readlink /mnt/vendor/modem_img/images/default 2>/dev/null)
[ -n "$fw" ] || fw=$(getprop gsm.version.baseband | cut -d, -f1)
case "$fw" in
    g5123*) ui_print "- Modem $fw: profile g5123 (Exynos 5123: Pixel 6 / 6 Pro / 6a)" ;;
    g5300*) ui_print "- Modem $fw: profile g5300 (Exynos 5300: Pixel 7 / 8 series, 9a)" ;;
    g5400*) ui_print "- Modem $fw: profile g5400 (Exynos 5400: Pixel 9 / 10 series)" ;;
    *) ui_print "! Modem '${fw:-unknown}': no modem profile for it; only carrier settings and 4G/5G switching are active." ;;
esac
n=$($MODPATH/bin/sqlite3 /vendor/firmware/carrierconfig/cfg.db "select count(*) from confmap where carrier_id='1911';" 2>/dev/null)
[ "$n" = "1" ] || ui_print "! This phone's carrier database has no carrier 1911: the modem profile will not be used."

# Keep the PLMN list of a previous installation.
if [ -f /data/adb/modules/pixel-5g-enabler/plmns.conf ]; then
    cp /data/adb/modules/pixel-5g-enabler/plmns.conf $MODPATH/plmns.conf
    ui_print "- Kept your plmns.conf"
fi

# Restores the phone's own settings while the module is disabled or after it is removed, and checks the radio at
# every boot (see the script). Both files are put in place by a rename: a copy that is running keeps its own file.
mkdir -p /data/adb/service.d /data/adb/pixel-5g-enabler
b=$(getprop gsm.version.baseband | cut -d, -f1)    # fallback for the modem detection at boot
[ -n "$b" ] && echo "$b" > /data/adb/pixel-5g-enabler/baseband
cp $MODPATH/pixel-5g-enabler-restore.sh /data/adb/pixel-5g-enabler/restore.new
chmod 755 /data/adb/pixel-5g-enabler/restore.new
mv -f /data/adb/pixel-5g-enabler/restore.new /data/adb/service.d/pixel-5g-enabler-restore.sh
cp $MODPATH/bin/sqlite3 /data/adb/pixel-5g-enabler/sqlite3.new    # the restore also runs after the module folder is removed
chmod 700 /data/adb/pixel-5g-enabler/sqlite3.new
mv -f /data/adb/pixel-5g-enabler/sqlite3.new /data/adb/pixel-5g-enabler/sqlite3

# Version of Android's carrier-config package: the carrier settings are then written early at the next boot.
umask 077
dumpsys package com.google.android.carrier 2>/dev/null | grep -m1 -oE 'versionCode=[0-9]+' | cut -d= -f2     > /data/adb/pixel-5g-enabler/cc_version
[ -s /data/adb/pixel-5g-enabler/cc_version ] || rm -f /data/adb/pixel-5g-enabler/cc_version

ui_print "- PLMN list: /data/adb/modules/pixel-5g-enabler/plmns.conf (edit, then reboot)"
ui_print "- After the reboot: status here in the module list; Action button: check + report in Download"
ui_print "- Logs: /data/local/tmp/pixel-5g-enabler-boot.log and /data/local/tmp/pixel-5g-enabler.log"
