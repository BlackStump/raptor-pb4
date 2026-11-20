#!/bin/sh
# mkpb4full.sh -- one PB4's complete 8 MB flash image, for the CH347.
#
#   sh tools/mkpb4full.sh NAME MAC [pb4|ceiling]
#   sh tools/mkpb4full.sh garage1 f6:70:00:0d:25:71
#   sh tools/mkpb4full.sh hall2 f6:70:00:0d:25:72 ceiling
#
# The housing (default pb4: IR + white LEDs, wlight on) goes into the env
# as housing=; S95pb4 applies it on first boot (`housing` on the camera
# changes it later). One image file covers both kinds of housing.
#
# Writes pb4-NAME-full.bin (and its md5) in the current directory:
#
#   0x000000  256K  OpenIPC U-Boot
#   0x040000   64K  U-Boot env: M2's working env, with this camera's MAC
#   0x050000    2M  uImage            (the Raptor PB4 build)
#   0x250000    5M  rootfs.squashfs   (the Raptor PB4 build)
#   0x750000  704K  overlay, erased   (first boot formats it)
#
# One image per camera because the MAC lives in the env sector. Take the
# MAC from the camera's stock backup (vendor mac.conf), its stock ifconfig
# or its sticker -- and read the stock flash twice with the CH347 before
# writing this, so the stock image stays recoverable.
#
# UBOOT, KERNEL and ROOTFS can be overridden from the environment.

set -e
PB4=/home/crazyasskooter/Cams/PB4
OUT=$PB4/openipc-fh/output
UBOOT=${UBOOT:-$PB4/pb4-openipc-uboot/u-boot-fh8856v200-nor.bin}
KERNEL=${KERNEL:-$OUT/images/uImage}
ROOTFS=${ROOTFS:-$OUT/images/rootfs.squashfs}

NAME=$1
MAC=$(echo "$2" | tr 'A-F' 'a-f')
HOUSING=${3:-pb4}
[ -n "$NAME" ] && [ -n "$MAC" ] || { echo "usage: $0 NAME MAC [pb4|ceiling]"; exit 1; }
case "$HOUSING" in pb4 | ceiling) ;; *) echo "housing '$HOUSING' is not pb4 or ceiling"; exit 1 ;; esac
echo "$MAC" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' ||
    { echo "MAC '$2' is not xx:xx:xx:xx:xx:xx"; exit 1; }
# bit 0 of the first byte set = multicast, never a NIC's address
[ $((0x${MAC%%:*} & 1)) = 0 ] || { echo "MAC $MAC is a multicast address"; exit 1; }

MKENV=$(command -v mkenvimage || true)
[ -n "$MKENV" ] || MKENV=$OUT/host/bin/mkenvimage
[ -x "$MKENV" ] || { echo "no mkenvimage (u-boot-tools, or $OUT/host/bin)"; exit 1; }

for f in "$UBOOT" "$KERNEL" "$ROOTFS"; do
    [ -f "$f" ] || { echo "missing $f"; exit 1; }
done

fits() { # file limit what
    s=$(wc -c < "$1")
    [ "$s" -le $(($2)) ] || { echo "$3 is $s bytes, more than its $(($2)) byte partition"; exit 1; }
    printf "  %-8s %8d of %8d bytes  %s\n" "$3" "$s" $(($2)) "$1"
}
echo ">>> parts"
fits "$UBOOT" 0x40000 u-boot
fits "$KERNEL" 0x200000 kernel
fits "$ROOTFS" 0x500000 rootfs
# a real uImage and squashfs, not something else by that name
[ "$(od -An -tx1 -N4 "$KERNEL" | tr -d ' ')" = 27051956 ] || { echo "$KERNEL is not a uImage"; exit 1; }
[ "$(head -c 4 "$ROOTFS")" = hsqs ] || { echo "$ROOTFS is not a squashfs"; exit 1; }

# M2's env (fw_printenv, 2026-11-15) with this MAC. osmem is 36M: the
# kernel's own command line has mem=36M, which the 90M VMM pool at
# 0xA2400000 sits just above; the env says the same in case a kernel
# ever takes these bootargs instead.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cat > "$T/env.txt" <<EOF
baudrate=115200
ethaddr=$MAC
housing=$HOUSING
baseaddr=0xA1000000
kernaddr=0x00050000
kernsize=0x200000
rootaddr=0x00250000
rootsize=0x500000
mtdparts=spi0.0:256k(u-boot),64k(env),2048k(kernel),5120k(rootfs),7168k@0x50000(firmware),-(rootfs_data)
osmem=36M
bootargs=mem=\${osmem} console=ttyS0,115200 panic=20 root=/dev/mtdblock3 rootfstype=squashfs init=/init mtdparts=\${mtdparts} \${extras}
loadkernel=sf probe 0; sf read \${baseaddr} \${kernaddr} \${kernsize}
bootflash=setenv setargs setenv bootargs \${bootargs}; run setargs; run loadkernel; bootm \${baseaddr}; reset
bootcmd=run bootflash
bootdelay=1
EOF
"$MKENV" -s 0x10000 -o "$T/env.bin" "$T/env.txt"

IMG=pb4-$NAME-$HOUSING-full.bin
echo ">>> $IMG"
# 8 MB of erased flash, then each part at its offset
head -c $((0x800000)) /dev/zero | tr '\000' '\377' > "$IMG"
put() { dd if="$1" of="$IMG" bs=1 seek=$(($2)) conv=notrunc status=none; }
put "$UBOOT" 0x000000
put "$T/env.bin" 0x040000
put "$KERNEL" 0x050000
put "$ROOTFS" 0x250000

# read every part back out of the image and compare
back() { # file offset what
    s=$(wc -c < "$1")
    dd if="$IMG" bs=1 skip=$(($2)) count="$s" status=none | cmp -s - "$1" ||
        { echo "  $3 in the image does not match"; exit 1; }
}
back "$UBOOT" 0x000000 u-boot
back "$T/env.bin" 0x040000 env
back "$KERNEL" 0x050000 kernel
back "$ROOTFS" 0x250000 rootfs
[ "$(wc -c < "$IMG")" = $((0x800000)) ] || { echo "  image is not 8 MB"; exit 1; }
strings -n 8 "$IMG" | grep -q "^ethaddr=$MAC$" || { echo "  ethaddr not in the image"; exit 1; }
strings -n 8 "$IMG" | grep -q "^housing=$HOUSING$" || { echo "  housing not in the image"; exit 1; }
echo "  ok: 8 MB, all parts read back, ethaddr=$MAC, housing=$HOUSING"
md5sum "$IMG" | tee "$IMG.md5" | sed 's/^/  /'
