# Modem profiles

There is one file per modem family: `g5123.txt`, `g5300.txt` and `g5400.txt`. `tools/build.py` turns each file into
the files that the Pixel radio software reads (`module/profiles/<family>/manifests/` and `confseqs/`).

## Format

```
[sim1]                       # one step; steps are applied in file order
NR.CONFIG.MODE = 0x11        # setting = value
OEM_GFEATURE_RAT_ORDER_SEARCH_TBL = 0x40, 0x4, 0x2, 0x1   # array
id:0x46e02611 = 0x11         # a setting known only by its id (crc32 of its name)
```

- Sections: `common`, `sim1` and `sim2` (SIM slot 1 or 2), `multislot` (both slots).
- Values are integers. Setting names are the modem's own names; the file stores the crc32 of the name.
- Set only the values the module needs. `reset` (back to the modem default) is accepted, but avoid it: the module's
  profile replaces the phone's stock profile, and a default that differs from what the stock profile set can stop
  the modem from searching (seen on a Pixel 6 Pro).

## Adding a family

1. Find the phone's modem firmware: `adb shell getprop gsm.version.baseband` (for example `g5400i-260604-...`). Its
   first five characters are the family (`g5400`).
2. Look at the phone's stock profiles. Copy them with the module disabled (or not installed) and after a reboot,
   because with the module active the folder shows the module's profile:
   ```
   adb shell su -c "tar -C /vendor/firmware -cf /data/local/tmp/cc.tar carrierconfig"
   adb pull /data/local/tmp/cc.tar && mkdir stock && tar -C stock -xf cc.tar
   ```
   To read one profile, make a folder with a `manifests/` folder that holds only that profile's manifest, and a copy
   of `stock/carrierconfig/confseqs/`. Then run `python3 tools/build_profile.py --import <folder>`. With
   `--names <file>` (one setting name per line, for example from `strings` on the phone's modem partition) it shows
   names instead of ids.
3. Write `profiles/<family>.txt` with the settings you need. Start from the file of a similar family.
4. Add the firmware prefix (for example `g5500`) to `family_of()` in `module/post-fs-data.sh`, to the `case` in
   `module/customize.sh` and to `tests/modem_family_test.sh`.
5. Build, install, and check that the phone registers on 4G and 5G. To compare with the stock profile, create an
   empty file `skip_mount` in `/data/adb/modules/pixel-5g-enabler/` and reboot: Magisk then leaves the stock profile
   in place.
6. Check that the modem took the values (the profile is applied at every modem start). In a root shell on the phone
   (`adb shell`, then `su`):
   ```
   timeout 3 sh -c 'printf "AT+GOOGGETNV=\"NR.CONFIG.MODE\"\r" > /dev/umts_router & cat /dev/umts_router'
   ```
