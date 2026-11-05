#!/bin/sh
# codectest.sh -- does rate control hold its target with libdsp's real
# RC layout? ~40 s each; wave a hand in front of the lens for the second
# half of each run so the encoder has something to spend bits on.
#   A  H.264 CBR (main 4000, sub 1000 kbit/s)
#   B  H.264 VBR
#   C  H.265 CBR main, H.264 CBR sub
cd /tmp || exit 1
export LD_LIBRARY_PATH=/tmp

mkconf() { # $1 codec0 $2 rc0 $3 qp0 $4 rc1 $5 qp1
    cat > /tmp/codectest.conf <<CONF
[sensor]
name = gc4653

[stream0]
width = 2560
height = 1440
fps = 25
codec = $1
profile = 1
bitrate = 4000000
rc_mode = $2
init_qp = $3
osd_enabled = false
jpeg = false

[stream1]
width = 640
height = 360
fps = 25
codec = h264
profile = 0
bitrate = 1000000
rc_mode = $4
init_qp = $5
osd_enabled = false
jpeg = false
CONF
}

run() { # $1 label
    killall ric rsd rvd 2>/dev/null; sleep 3
    /tmp/rvd -f -c /tmp/codectest.conf > /tmp/rvd-codec.log 2>&1 &
    printf '\n>>> %s: running 40 s (still for 20 s...)\n' "$1"
    sleep 20
    printf '>>> ...now WAVE A HAND in front of the lens for 20 s\n'
    sleep 20
    grep -E 'venc chn [01]: (H\.26|RC as)' /tmp/rvd-codec.log | sed 's/.*venc/venc/'
    grep -E 'kbit/s' /tmp/rvd-codec.log | tail -6 | sed 's/.*venc/venc/'
    grep -E 'fatal|ERROR' /tmp/rvd-codec.log
}

mkconf h264 cbr -1 cbr -1;     run "A  H.264 CBR"
mkconf h264 vbr -1 vbr -1;     run "B  H.264 VBR"
mkconf h265 cbr -1 cbr -1;     run "C  H.265 CBR main, H.264 CBR sub"

killall rvd 2>/dev/null
printf '\n>>> done; restart normally with: sh /tmp/dntest.sh start\n'
