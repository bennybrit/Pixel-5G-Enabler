#!/bin/sh
# Test of the modem detection in module/post-fs-data.sh (family_of): the function is taken from the module script
# (no phone needed; any POSIX sh, also on a phone).
#   sh tests/modem_family_test.sh [path to post-fs-data.sh]
SRC=${1:-$(dirname "$0")/../module/post-fs-data.sh}
eval "$(sed -n '/^family_of() {/,/^}/p' "$SRC")"

fails=0
check() {  # $1 = modem firmware version, $2 = expected family
    got=$(family_of "$1")
    if [ "$got" = "$2" ]; then echo "ok   '$1' -> '$2'"; else echo "FAIL '$1': expected '$2', got '$got'"; fails=$((fails + 1)); fi
}

check g5123b-145971-260721-B-15910359 g5123    # Pixel 6 / 6 Pro / 6a
check g5300t-260604-260807-B-16036236 g5300    # Pixel 9a
check g5300q-230913-231013-B-10988354 g5300    # another Exynos 5300 variant letter
check g5400c-260604-260807-B-16035863 g5400    # Pixel 9
check g5400i-260604-260807-B-16035863 g5400    # Pixel 10
check g5500x-270101-270201-B-17000000 ""       # an unknown modem: no profile
check default ""                               # unresolved link name
check "" ""                                    # nothing found
check s5100sit ""                              # the boot protocol property, not a modem version
[ $fails = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
