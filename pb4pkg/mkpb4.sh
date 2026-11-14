#!/bin/sh
# mkpb4.sh -- package Raptor for the Vatilon PB4 into the OpenIPC image.
#
#   sh mkpb4.sh overlay    build rvd/rsd/ric/raptorctl and assemble the
#                          overlay tree in $OVL (nothing else touched)
#   sh mkpb4.sh image      overlay + install it into the Buildroot target,
#                          remove Majestic, and regenerate the images
#                          (load_fullhan stays the package's: 90M pool
#                          above mem=36M)
#
# Daemons: rvd rsd ric (video, RTSP, day/night), rhd + rcd (web console on
# :8080 with config editing), raptorctl (CLI, also used by the init script).
# ONVIF on port 80 (onvif-simple-server), off until [onvif] enabled = true.
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
    echo ">>> building rvd rsd ric raptorctl rhd rcd rmd"
    (cd "$R" && ./build.sh fh8856v200 "$OUT" rvd rsd ric raptorctl rhd rcd rmd > /tmp/mkpb4-build.log 2>&1) ||
        { echo "build failed -- see /tmp/mkpb4-build.log"; tail -20 /tmp/mkpb4-build.log; exit 1; }

    echo ">>> assembling $OVL"
    rm -rf "$OVL"
    mkdir -p "$OVL/usr/bin" "$OVL/usr/lib" "$OVL/etc/init.d" "$OVL/usr/share/raptor"
    cp "$R/rvd/rvd" "$R/rsd/rsd" "$R/ric/ric" "$R/raptorctl/raptorctl" \
       "$R/rhd/rhd" "$R/rcd/rcd" "$R/rmd/rmd" "$OVL/usr/bin/"
    # Web console: rhd serves exactly one page, /usr/share/raptor/index.html,
    # at "/" (plus the portal page). The console is that page; rhd's own
    # index.html is only a snapshot/MJPEG stub. rcd answers the console's
    # /api/v1/rcd requests.
    cp "$R/rhd/console.html" "$OVL/usr/share/raptor/index.html"
    cp "$R/rhd/portal.html" "$OVL/usr/share/raptor/"
    cp -L "$PB4/raptor/raptor-common/librss_common.so" "$PB4/raptor/raptor-ipc/librss_ipc.so" "$OVL/usr/lib/"
    cp -L "$(find "$OUT/host/arm-openipc-linux-musleabi/sysroot" -name 'libatomic.so.1' | head -1)" "$OVL/usr/lib/"
    # Motion white light: wlight samples the sub-stream (rvd save raw),
    # ydiff compares frames, lamp drives the white LEDs.
    $B-gcc -O2 -Wall -o "$OVL/usr/bin/ydiff" "$PKG/src/ydiff.c"
    $B-strip "$OVL"/usr/bin/rvd "$OVL"/usr/bin/rsd "$OVL"/usr/bin/ric "$OVL"/usr/bin/raptorctl \
        "$OVL"/usr/bin/rhd "$OVL"/usr/bin/rcd "$OVL"/usr/bin/rmd "$OVL"/usr/bin/ydiff "$OVL"/usr/lib/*
    chmod 644 "$OVL"/usr/share/raptor/*

    cp "$PKG/overlay/usr/bin/lamp" "$PKG/overlay/usr/bin/wlight" "$OVL/usr/bin/"
    cp "$PKG/overlay/etc/wlight.conf" "$OVL/etc/wlight.conf"
    cp "$PKG/overlay/etc/init.d/S97wlight" "$OVL/etc/init.d/S97wlight"

    cp "$PKG/overlay/etc/raptor.conf" "$OVL/etc/raptor.conf"
    # fw_printenv's map of the U-Boot env (mtd1, 64K): OpenIPC's get_mac
    # reads ethaddr through it, and without it eth0 gets a random MAC
    # instead of the one mkpb4full.sh put in the env
    cp "$PKG/overlay/etc/fw_env.config" "$OVL/etc/fw_env.config"
    cp "$PKG/overlay/etc/init.d/S95pb4" "$OVL/etc/init.d/S95pb4"
    # Raptor's own init script, run last: after the vendor modules and the
    # PB4 pin setup. rvd first, then rsd and ric; daemons not installed
    # (rhd, rod, ...) are skipped by the script itself.
    cp "$R/config/S31raptor" "$OVL/etc/init.d/S96raptor"

    # ONVIF (off until [onvif] enabled = true): the init script replacing
    # the onvif-simple-server package's, onvif-conf/onvif-cgi (the conf
    # from raptor.conf), the CGI links, and httpd's docroot.
    mkdir -p "$OVL/usr/sbin" "$OVL/usr/share/onvif-www" "$OVL/var/www/onvif"
    cp "$PKG/overlay/etc/init.d/S96onvifserver" "$OVL/etc/init.d/"
    cp "$PKG/overlay/usr/sbin/onvif-conf" "$PKG/overlay/usr/sbin/onvif-cgi" "$OVL/usr/sbin/"
    cp -P "$PKG/overlay/usr/share/onvif-www/onvif" "$OVL/usr/share/onvif-www/"
    cp -P "$PKG"/overlay/var/www/onvif/*_service "$OVL/var/www/onvif/"
    chmod +x "$OVL"/etc/init.d/* "$OVL"/usr/bin/* "$OVL"/usr/sbin/*

    echo ">>> overlay contents"
    (cd "$OVL" && find . \( -type f -o -type l \) | sort | xargs ls -ld | awk '{printf "  %8s  %s %s %s\n", $5, $9, $10, $11}')
    du -sk "$OVL" | awk '{print "  total " $1 " KiB"}'
}

image() {
    overlay
    T=$OUT/target

    # This Buildroot tree carries whichever streamer it was configured with
    # (Majestic upstream, Divinus on the PB4 branch). Both open the sensor
    # and the encoder, so neither may start beside rvd. Their binaries,
    # configs and init scripts go; anything else of theirs is listed.
    # The Divinus-era wlight left the white LEDs on without Divinus (bench,
    # 2026-11-05). It is removed first; the overlay then installs the Raptor
    # wlight (rvd-sampled motion) in its place.
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

    # ONVIF: OpenIPC's onvif-simple-server package (server, WS-Discovery,
    # XML templates), built and installed before the overlay goes in, so
    # the overlay's init script and CGI links replace the package's and
    # the final make does not reinstall them.
    echo ">>> onvif-simple-server: selected and built"
    for sym in BR2_PACKAGE_MBEDTLS BR2_PACKAGE_ONVIF_SIMPLE_SERVER; do
        sed -i "/^# $sym is not set/d; /^$sym=/d" "$OUT/.config"
        echo "$sym=y" >> "$OUT/.config"
    done
    make -C "$OUT" olddefconfig > /dev/null
    grep -q '^BR2_PACKAGE_ONVIF_SIMPLE_SERVER=y' "$OUT/.config" ||
        { echo "  could not select BR2_PACKAGE_ONVIF_SIMPLE_SERVER"; exit 1; }
    # utils.c includes zlib.h whether or not USE_ZLIB is set, and the
    # package lists only mbedtls: with per-package directories there is
    # no zlib.h to find. The include goes under USE_ZLIB (patch 03, put
    # into the tree's package directory; a rebuild then picks it up).
    PD=$OUT/../general/package/onvif-simple-server
    PF=03-zlib-only-with-USE_ZLIB.patch
    if [ -d "$PD" ] && ! cmp -s "$PKG/patches/onvif-simple-server-$PF" "$PD/$PF"; then
        cp "$PKG/patches/onvif-simple-server-$PF" "$PD/$PF"
        make -C "$OUT" onvif-simple-server-dirclean > /dev/null
        echo "  $PF added to $PD"
    fi
    make -C "$OUT" onvif-simple-server > /tmp/mkpb4-onvif.log 2>&1 ||
        { echo "onvif-simple-server failed -- see /tmp/mkpb4-onvif.log"; tail -20 /tmp/mkpb4-onvif.log; exit 1; }

    # Motion events: the package builds onvif_notify_server and the events
    # templates but installs neither. They go into the overlay: the
    # server, the events service's templates and the notification
    # template, with the event's data item named IsMotion (what the stock
    # PB4 sends under RuleEngine/CellMotionDetector/Motion), not State.
    OSS=$(ls -d "$OUT"/build/onvif-simple-server-*/ 2>/dev/null | head -1)
    [ -x "$OSS/onvif_notify_server" ] || { echo "  no onvif_notify_server in '$OSS'"; exit 1; }
    mkdir -p "$OVL/usr/sbin" "$OVL/var/www/onvif/events_service_files" "$OVL/etc/onvif_notify_server"
    cp "$OSS/onvif_notify_server" "$OVL/usr/sbin/"
    $B-strip "$OVL/usr/sbin/onvif_notify_server"
    for f in "$OSS"/events_service_files/*; do
        sed 's/Name="State"/Name="IsMotion"/' "$f" > "$OVL/var/www/onvif/events_service_files/${f##*/}"
    done
    sed 's/Name="State"/Name="IsMotion"/' "$OSS/notify_files/Notify.xml" > "$OVL/etc/onvif_notify_server/Notify.xml"
    grep -q 'Name="IsMotion"' "$OVL/var/www/onvif/events_service_files/PullMessages_2.xml" ||
        { echo "  events templates: no State item to rename"; exit 1; }
    chmod 644 "$OVL"/var/www/onvif/events_service_files/* "$OVL/etc/onvif_notify_server/Notify.xml"
    echo "  motion events: onvif_notify_server and its templates in the overlay"

    echo ">>> installing into $T"
    cp -a "$OVL"/. "$T"/

    # This tree builds with per-package directories: the final make
    # merges every package's own target files into $T, over what was
    # copied in above (onvif-simple-server's init script and CGI links
    # among them). A rootfs overlay is applied after that merge, so the
    # overlay is also listed there and its files are the ones that ship.
    echo ">>> the overlay: added to BR2_ROOTFS_OVERLAY (applied after the packages)"
    cur=$(sed -n 's/^BR2_ROOTFS_OVERLAY="\(.*\)"$/\1/p' "$OUT/.config")
    case " $cur " in
    *" $OVL "*) ;;
    *) sed -i "/^BR2_ROOTFS_OVERLAY=/d" "$OUT/.config"
       echo "BR2_ROOTFS_OVERLAY=\"$cur $OVL\"" >> "$OUT/.config"
       make -C "$OUT" olddefconfig > /dev/null ;;
    esac
    grep '^BR2_ROOTFS_OVERLAY=' "$OUT/.config" | sed 's/^/  /'

    echo ">>> regenerating images"
    make -C "$OUT" > /tmp/mkpb4-image.log 2>&1 ||
        { echo "image build failed -- see /tmp/mkpb4-image.log"; tail -20 /tmp/mkpb4-image.log; exit 1; }
    ls -l "$OUT/images/"

    echo ">>> checking the target (ONVIF, VMM pool)"
    bad=0
    for f in usr/sbin/onvif_simple_server usr/sbin/wsd_simple_server usr/sbin/onvif_notify_server \
             usr/bin/rmd var/www/onvif/device_service_files/GetDeviceInformation.xml \
             var/www/onvif/events_service_files/PullMessages_2.xml etc/onvif_notify_server/Notify.xml; do
        [ -e "$T/$f" ] || { echo "  FAIL: /$f missing"; bad=1; }
    done
    for s in device media events ptz; do
        [ "$(readlink "$T/var/www/onvif/${s}_service")" = /usr/sbin/onvif-cgi ] ||
            { echo "  FAIL: /var/www/onvif/${s}_service -> $(readlink "$T/var/www/onvif/${s}_service")"; bad=1; }
    done
    # newer OpenIPC trees strip shell comments in post-build: compare
    # through the same awk when the tree has it
    STRIPPER=$OUT/../general/scripts/strip-shell-comments.awk
    if [ -f "$STRIPPER" ]; then
        awk -f "$STRIPPER" "$OVL/etc/init.d/S96onvifserver" | cmp -s - "$T/etc/init.d/S96onvifserver"
    else
        cmp -s "$OVL/etc/init.d/S96onvifserver" "$T/etc/init.d/S96onvifserver"
    fi || { echo "  FAIL: S96onvifserver is the package's, not ours"; bad=1; }
    # load_fullhan ships as the package has it: its active pool, 90M at
    # 0xA2400000, sits just above the kernel's mem=36M (0xA0000000 +
    # 36M). The old 64M-at-0xA2000000 edit put the pool inside the
    # kernel's memory ("map address 0xA2000000 in kernel range!", rvd
    # down); it only ever shipped once the overlay made it stick.
    base=$(sed -n 's/^[ \t]*insmod vmm.ko mmz=anonymous,0,\(0x[0-9A-Fa-f]*\),.*/\1/p' "$T/usr/bin/load_fullhan" | head -1)
    if [ -z "$base" ] || [ $((base)) -lt $((0xA0000000 + 36 * 1024 * 1024)) ]; then
        echo "  FAIL: load_fullhan's VMM pool (${base:-none}) is not above mem=36M (0xA2400000)"; bad=1
    else
        echo "  VMM pool at $base (mem=36M ends at 0xA2400000)"
    fi
    grep -q '^/dev/mtd1[[:space:]]' "$T/etc/fw_env.config" 2>/dev/null ||
        { echo "  FAIL: /etc/fw_env.config does not map the env (mtd1); MACs would be random"; bad=1; }
    # busybox httpd runs CGI under /onvif/ only with OpenIPC's patch
    grep -q 'onvif/' "$T/bin/busybox" || { echo "  FAIL: busybox httpd has no /onvif/ CGI support"; bad=1; }
    [ $bad = 0 ] && echo "  ok"
    [ $bad = 0 ]
}

case "$1" in
overlay) overlay ;;
image) image ;;
*) echo "usage: $0 overlay|image"; exit 1 ;;
esac
