#!/system/bin/sh
# Runs when the module is removed in Magisk. The restore script in /data/adb/service.d/ does the actual work
# later in the same boot (the modem and Android must be running to put their settings back).
echo "$(date '+%F %T') module removed; the restore script will put back the phone's own settings" >> /data/local/tmp/pixel-5g-enabler.log
