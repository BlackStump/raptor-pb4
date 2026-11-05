#!/bin/sh
# mkpb4.sh -- package Raptor for the Vatilon PB4 into the OpenIPC image.
#
#   sh mkpb4.sh overlay    build rvd/rsd/ric/raptorctl and assemble the
#                          overlay tree in $OVL (nothing else touched)
#   sh mkpb4.sh image      overlay + install it into the Buildroot target,
#                          remove Majestic, set the 64M VMM pool in
#                          load_fullhan, and regenerate the images
#
# Daemons: rvd rsd ric (video, RTSP, day/night), rhd + rcd (web console on
# :8080 with config editing), raptorctl (CLI, also used by the init script).
#
# Paths below match the PB4 working tree; change them here if yours differ.

set -e
PB4=/home/crazyasskooter/Cams/PB4
R=$PB4/raptor/raptor
OUT=$PB4/openipc-fh/output
PKG=$(cd "$(dirname "$0")" && pwd)
OVL=$PB4/pb4-overlay
B=$OUT/host/bin/arm-openipc-linux-musleabi

overlay() {
    echo ">>> building rvd rsd ric raptorctl rhd rcd"
    (cd "$R" && ./build.sh fh8856v200 "$OUT" rvd rsd ric raptorctl rhd rcd > /tmp/mkpb4-build.log 2>&1) ||
        { echo "build failed -- see /tmp/mkpb4-build.log"; tail -20 /tmp/mkpb4-build.log; exit 1; }

    echo ">>> assembling $OVL"
    rm -rf "$OVL"
    mkdir -p "$OVL/usr/bin" "$OVL/usr/lib" "$OVL/etc/init.d" "$OVL/usr/share/raptor"
    cp "$R/rvd/rvd" "$R/rsd/rsd" "$R/ric/ric" "$R/raptorctl/raptorctl" \
       "$R/rhd/rhd" "$R/rcd/rcd" "$OVL/usr/bin/"
    # Web console: rhd serves exactly one page, /usr/share/raptor/index.html,
    # at "/" (plus the portal page). The console is that page; rhd's own
    # index.html is only a snapshot/MJPEG stub. rcd answers the console's
    # /api/v1/rcd requests.
    cp "$R/rhd/console.html" "$OVL/usr/share/raptor/index.html"
    cp "$R/rhd/portal.html" "$OVL/usr/share/raptor/"
    cp -L "$PB4/raptor/raptor-common/librss_common.so" "$PB4/raptor/raptor-ipc/librss_ipc.so" "$OVL/usr/lib/"
    cp -L "$(find "$OUT/host/arm-openipc-linux-musleabi/sysroot" -name 'libatomic.so.1' | head -1)" "$OVL/usr/lib/"
    $B-strip "$OVL"/usr/bin/* "$OVL"/usr/lib/*
    chmod 644 "$OVL"/usr/share/raptor/*

    cp "$PKG/overlay/etc/raptor.conf" "$OVL/etc/raptor.conf"
    cp "$PKG/overlay/etc/init.d/S95pb4" "$OVL/etc/init.d/S95pb4"
    # Raptor's own init script, run last: after the vendor modules and the
    # PB4 pin setup. rvd first, then rsd and ric; daemons not installed
    # (rhd, rod, ...) are skipped by the script itself.
    cp "$R/config/S31raptor" "$OVL/etc/init.d/S96raptor"
    chmod +x "$OVL"/etc/init.d/* "$OVL"/usr/bin/*

    echo ">>> overlay contents"
    (cd "$OVL" && find . -type f | sort | xargs ls -l | awk '{printf "  %8s  %s\n", $5, $9}')
    du -sk "$OVL" | awk '{print "  total " $1 " KiB"}'
}

image() {
    overlay
    T=$OUT/target

    echo ">>> installing into $T"
    cp -a "$OVL"/. "$T"/

    # This Buildroot tree carries whichever streamer it was configured with
    # (Majestic upstream, Divinus on the PB4 branch). Both open the sensor
    # and the encoder, so neither may start beside rvd. Their binaries,
    # configs and init scripts go; anything else of theirs is listed.
    # wlight is the Divinus-era white-light daemon: without Divinus it
    # leaves the white LEDs on (bench, 2026-11-05).
    echo ">>> removing other streamers and their helpers (majestic, divinus, wlight)"
    for n in majestic divinus wlight; do
        rm -f "$T/usr/bin/$n" "$T/etc/$n.yaml" "$T/etc/$n.conf" "$T/etc/init.d/"S??"$n"
    done
    left=$(find "$T/etc" "$T/usr/bin" "$T/usr/sbin" -iname '*majestic*' -o -iname '*divinus*' -o -iname '*wlight*' 2>/dev/null)
    if [ -n "$left" ]; then
        echo "  still present (check these):"; echo "$left" | sed 's/^/    /'
    else
        echo "  gone"
    fi
    echo "  init scripts now in the image:"
    ls "$T/etc/init.d" | tr '\n' ' ' | sed 's/^/    /'; echo

    echo ">>> load_fullhan: 64M VMM pool at 0xA2000000"
    L=$T/usr/bin/load_fullhan
    if [ -f "$L" ]; then
        sed -i 's/mmz=anonymous,0,0x[0-9A-Fa-f]*,[0-9]*M/mmz=anonymous,0,0xA2000000,64M/' "$L"
        grep -n 'mmz=' "$L" | sed 's/^/  /'
    else
        echo "  $L not found -- set the pool by hand"
    fi

    echo ">>> regenerating images"
    make -C "$OUT" > /tmp/mkpb4-image.log 2>&1 ||
        { echo "image build failed -- see /tmp/mkpb4-image.log"; tail -20 /tmp/mkpb4-image.log; exit 1; }
    ls -l "$OUT/images/"
}

case "$1" in
overlay) overlay ;;
image) image ;;
*) echo "usage: $0 overlay|image"; exit 1 ;;
esac
