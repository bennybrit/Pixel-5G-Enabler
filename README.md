# Pixel 5G Enabler

[![Latest release](https://img.shields.io/github/v/release/bennybrit/Pixel-5G-Enabler)](https://github.com/bennybrit/Pixel-5G-Enabler/releases/latest)
[![License](https://img.shields.io/badge/license-Apache--2.0-green)](LICENSE)

A Magisk module that lets Google Pixel phones (Pixel 6 to Pixel 10) use 5G, VoLTE and VoNR with the SIM cards of
networks that the phone does not support on its own. It was made for private and test networks, such as a campus or
lab network, but it works with any network you choose.

## What it does and how it works

Every mobile network has a network code, also called PLMN: a country code (MCC) and a network number (MNC), for
example 315-010. Your phone uses the network code of the SIM card to decide which features to turn on. When it does
not know the network, as with private and test networks and some smaller operators, it uses safe defaults: 5G off,
some bands blocked, and no VoLTE or VoNR switches. The SIM works, but only on 4G.

The module turns these features on for the network codes in its list. By default the list has the three codes that
most private and test networks use:

| Network code | Used by |
|---|---|
| 001-01 | 3GPP test networks |
| 315-010 | private networks on the US CBRS shared spectrum |
| 999-70 | private networks |

**It is not only for private networks: the module works with any network code you add.** For example, add the code
of an operator whose SIM gets no 5G or no VoLTE on your Pixel. See [Choose your networks](#choose-your-networks).

Add only networks that do not already work well on your phone: for a code in the list, the module's settings replace
the settings Google made for that network.

At every boot the module does three things:

1. **Modem:** it gives the modem a 5G profile for the listed codes. 5G is turned on and all the 5G bands of the phone
   are allowed. The profile comes from a changed copy of the phone's carrier database that Magisk lays over the
   original. Nothing in the system or vendor partitions is changed.
2. **Android:** it gives Android matching carrier settings for SIMs with a listed code. 5G is allowed, the phone puts
   data first, and the VoLTE, VoNR, video calling and Wi-Fi calling switches appear in Settings.
3. **4G/5G switching:** a small background script follows the network type you choose and helps the phone get onto
   5G and stay there.

When you disable or remove the module and reboot, the phone goes back to its own settings.

## Supported features

- **5G standalone (SA) and non-standalone (NSA)** for every network in the list.
- **All the 5G bands of the phone**, including n48, n77 and n78, also when the network code belongs to another
  country. Without the module the modem allows only the bands of the SIM's country: a Pixel 6 or 6a with a US code
  such as 315-010 cannot use n78.
- **5G without calls over 5G:** the phone stays on 5G even when the network offers no voice service on 5G.
- **VoLTE, VoNR, video calling and Wi-Fi calling** switches in Settings. They start off. Turn them on if your network
  offers these services.
- **4G/5G switching** with the phone's own network type setting. When a cell does not keep the phone in 5G only
  mode, the module falls back to "5G first, 4G allowed" by itself.
- **Radio check at boot:** if the radio stays off after a reboot, the module turns it on.
- **Status in Magisk:** the module's line in the Magisk module list shows if everything works.
- **Report with one tap** for troubleshooting. SIM numbers, IMEI and phone numbers in it are masked.
- **Low battery use:** the background script uses about 2% of one CPU core while the phone is awake (measured on a
  Pixel 6a), and nothing while the phone sleeps.
- **Clean disable and removal:** after a reboot the phone uses its own settings again.
- **New Pixels work without an update:** the module chooses the modem profile by the phone's modem, not by the phone
  model.

## Requirements

- A Google Pixel 6, 7, 8, 9 or 10 series phone. These phones have a Samsung Exynos modem. Pixel 5 and older are not
  supported, and the installer stops on a phone without an Exynos modem.
- Android 17. The module was tested on it. Older versions may work but are not tested.
- Root with Magisk 31.0, the version the module was tested with. KernelSU and APatch are not tested.
- A SIM card or eSIM of your network. The 4G/5G switching works on SIM slot 1.
- An APN for your network (see [Installation](#installation)).

## Supported phones

| Modem | Phones | Tested on |
|---|---|---|
| Exynos 5123 | Pixel 6, 6 Pro, 6a | Pixel 6, 6 Pro, 6a |
| Exynos 5300 | Pixel 7, 7 Pro, 7a, Fold, 8, 8 Pro, 8a, 9a | Pixel 9a |
| Exynos 5400 | Pixel 9, 9 Pro, 9 Pro XL, 9 Pro Fold, 10, 10 Pro, 10 Pro XL, 10 Pro Fold | Pixel 9, Pixel 10 (with an eSIM) |

All phones with the same modem get the same modem profile. The status line in Magisk shows if the module works on
your phone (see [Status](#status)).

A newer Pixel with an Exynos modem that is not in this table is not fully supported yet. On such a phone the module
changes only Android's settings (the calling switches appear), not the modem's, so 5G will most likely not work. Its
status line then starts with "⚠️ No modem profile for modem".

## Installation

1. Download `Pixel-5G-Enabler-<version>.zip` from the
   [latest release](https://github.com/bennybrit/Pixel-5G-Enabler/releases/latest) and copy it to the phone.
2. In the Magisk app, go to **Modules** > **Install from storage** and select the zip.
3. Reboot the phone.
4. Add an APN for your network if the phone has none (Android has no APN for a private network code). Go to
   **Settings** > **Network & internet** > **SIMs**, select your SIM, then **Access Point Names** > **+**, and enter:
   - **Name:** any name, for example `My network`
   - **APN:** the APN of your network, for example `internet`

   Leave the other fields as they are. Save the APN and select it.

If your network code is not in the default list, add it after the reboot (see
[Choose your networks](#choose-your-networks)) and reboot once more.

A SIM that the phone has never seen gets its settings at the next reboot: insert it while the phone is on, wait until
it shows up in Settings, then reboot. The status line tells you when a reboot is needed.

To update the module, install the new zip the same way and reboot. Your network list is kept.

## Usage

### Choose your networks

The network list is the file `/data/adb/modules/pixel-5g-enabler/plmns.conf`. It has one network code per line,
written without the dash: 315-010 is `315010`. Write the network number with as many digits as your network uses
(2 or 3). Text after `#` is a comment. The default list:

```
00101      # 001-01, the 3GPP test network
315010     # 315-010, US CBRS shared spectrum
99970      # 999-70, private network range
```

Edit the file with a root file manager, or from a computer with adb (this example adds 999-71):

```
adb shell su -c "echo 99971 >> /data/adb/modules/pixel-5g-enabler/plmns.conf"
adb shell su -c "cat /data/adb/modules/pixel-5g-enabler/plmns.conf"
```

Then reboot the phone.

### Switch between 4G and 5G

Use the phone's normal setting: **Settings** > **Network & internet** > **SIMs**, select your SIM, then **Preferred
network type**. With **5G** selected, the phone uses 5G when it can and 4G when it cannot.

To use only 5G or only 4G, use the phone's testing menu:

1. Open the Phone app and dial `*#*#4636#*#*`.
2. Tap **Phone information**.
3. In **Set preferred network type**, select **NR only** (5G only) or **LTE only** (4G only).

Some cells do not keep a phone in 5G only mode. When this happens, the module changes the setting to **NR/LTE** (5G
first, 4G allowed) by itself, and the status line ends with "NR only did not work here: NR first, LTE allowed".

### Status

The module's line in the Magisk module list shows its status. The module checks itself at every boot and after
every SIM change. To refresh the line, open the Modules tab again.

| Status (examples) | Meaning |
|---|---|
| ✅ Working: g5300 modem profile in use, SIM 999-70 ready | Everything is in place for your SIM. |
| ⏳ Starting… | The check has not run yet. |
| ⚠️ Reboot once to apply the settings of SIM 999-70 | A SIM from the list was inserted after the boot. |
| ℹ️ No SIM from plmns.conf (SIM 1: 262-01) | The SIM's network is not in the list, so the module does nothing. |
| ❌ Modem profile not in use for SIM 999-70 … | Reboot once. If the message stays, make a report (see below). |
| ❌ Android does not use the carrier settings of SIM 999-70 … | Reboot once. If the message stays, make a report. |
| ⚠️ No modem profile for modem '…' | The module does not know this phone's modem: only Android's settings are changed, so 5G may not work. |
| ⏸️ Disabled: phone's own settings restored | The module is disabled. |

### Report

For a closer look, tap the module's **Action** button in Magisk, or run this from a computer:

```
adb shell su -c sh /data/adb/modules/pixel-5g-enabler/action.sh
```

It shows the checks and saves a report in the phone's Download folder
(`pixel-5g-enabler-report-<date>-<time>.txt`). The report lists the phone, modem and module versions, the checks,
the modem settings, the SIM and network state, and the module's logs. SIM numbers, IMEI and phone numbers are masked.
Attach the file when you report a problem (see [If it does not work](#if-it-does-not-work)). Making a report changes
nothing on the phone.

### Logs

| File | Content |
|---|---|
| `/data/local/tmp/pixel-5g-enabler-boot.log` | modem profile setup at boot |
| `/data/local/tmp/pixel-5g-enabler.log` | carrier settings, status, 4G/5G switching, radio check |

The logs of the previous boot are kept as `pixel-5g-enabler-boot.log.1` and `pixel-5g-enabler.log.1`.

### Disable or remove

1. First set the network type back to a normal one, for example **5G** in Settings. Without the module, 5G
   standalone is off in the modem, so a phone left in NR only mode would have no service.
2. In Magisk, disable or remove the module, then reboot.

After the reboot the phone uses its own settings again. A small script in `/data/adb/service.d/` does this, because
Magisk does not run the scripts of a disabled module. After a removal the script deletes itself.

## If it does not work

1. Look at the module's status line in Magisk (see [Status](#status)) and do what it says. Many problems go away
   after one reboot.
2. Check the usual causes:
   - The network code of your SIM is in `plmns.conf`. If it is not, the status line shows the code of the SIM.
   - An APN for your network is added and selected.
   - The phone was rebooted once after you inserted a new SIM or changed `plmns.conf`.
3. If it still does not work, make a report (see [Report](#report)) and open an issue on
   [GitHub](https://github.com/bennybrit/Pixel-5G-Enabler/issues). Write your phone model, the network code, what
   you expected and what happened, and attach the report file. SIM numbers, IMEI and phone numbers in the report are
   masked. Read the report before you upload it, and remove anything else you do not want to share.

## Build

The build was tested on Rocky Linux 9 with Python 3.9 and zig 0.17.0. You need:

- Python 3.8 or newer
- zig, to compile a small `sqlite3` program for the phone (tested with 0.17.0)
- internet access for the first build, to download the SQLite source

Install zig (Linux x86_64):

```
curl -LO https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz
echo "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026  zig-x86_64-linux-0.17.0.tar.xz" | sha256sum -c
tar -xf zig-x86_64-linux-0.17.0.tar.xz -C ~
export PATH=$HOME/zig-x86_64-linux-0.17.0:$PATH
```

Build the module:

```
python3 tools/build.py
```

The zip is written to `dist/Pixel-5G-Enabler-<version>.zip`. The build:

1. turns the modem profiles in `profiles/*.txt` into the files the modem reads,
2. downloads the official SQLite 3.54.1 source from sqlite.org (only once, checked against a fixed checksum) and
   compiles `sqlite3` for the phone,
3. writes the zip with the module, the license files and the license notices of what `sqlite3` contains.

The build is reproducible: with zig 0.17.0, `module/bin/sqlite3` always has the SHA-256
`4eaee027ca70a5dc18168882f9b872277cb6f0cedade01dcf8d1bd32d0ba3bb3`.

The tests check the logic of the module scripts against simulated phone states. They need no phone:

```
for t in tests/*.sh; do sh "$t"; done
```

Each test ends with `all passed` or `0 failed`.

## Adding a phone family

The modem profile depends on the phone's modem, not on the phone model, so a new Pixel with a modem from the table
above works without changes. For a new modem, write a profile in `profiles/<family>.txt` and add the modem's firmware
prefix to the module scripts and the tests. The steps are in [profiles/README.md](profiles/README.md).

## License

Apache License 2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE). The zip also includes `THIRD-PARTY-NOTICES.txt` for
the parts of its `sqlite3` program: SQLite is in the public domain, and musl libc and parts of the Zig runtime are
under the MIT license.

This project is not affiliated with Google or Samsung. Pixel is a trademark of Google LLC.
