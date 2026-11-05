#!/bin/sh
# dntest.sh -- day/night bench test for the PB4 (M2), run on the camera.
#
#   sh /tmp/dntest.sh          start rvd + ric, guide the cover test, report
#   sh /tmp/dntest.sh start    only (re)start rvd + ric, then exit
#
# Everything lives in /tmp: rvd, ric, raptor.conf and the logs.

cd /tmp || exit 1
export LD_LIBRARY_PATH=/tmp
HOLD=30        # seconds to hold each state after its click
WAIT=60        # seconds to wait for a switch before giving up

say() { printf '\n>>> %s\n' "$*"; }

# Wait until ric.log gains a "switched to <MODE>" line beyond the first $2
# such lines; prints how long it took, or gives up after $WAIT seconds.
wait_switch() {
    mode=$1; before=$2; t=0
    while [ $t -lt $WAIT ]; do
        n=$(grep -c "switched to $mode" /tmp/ric.log)
        if [ "$n" -gt "$before" ]; then
            say "ric switched to $mode after ${t}s"
            return 0
        fi
        sleep 1; t=$((t + 1))
    done
    say "no switch to $mode within ${WAIT}s"
    return 1
}

countdown() {
    t=$1
    while [ $t -gt 0 ]; do
        printf '\r    hold... %2ds ' "$t"
        sleep 1; t=$((t - 1))
    done
    printf '\r    done.        \n'
}

# --- start the daemons ------------------------------------------------------
killall ric rvd 2>/dev/null
sleep 3

say "starting rvd"
/tmp/rvd -f -c /tmp/raptor.conf > /tmp/rvd.log 2>&1 &
t=0
until grep -q 'venc chn 0: first frame' /tmp/rvd.log; do
    sleep 1; t=$((t + 1))
    if [ $t -ge 20 ] || ! pidof rvd >/dev/null; then
        say "rvd did not come up -- last lines of rvd.log:"
        tail -15 /tmp/rvd.log
        exit 1
    fi
done
say "rvd streaming after ${t}s"

/tmp/ric -f -d -c /tmp/raptor.conf > /tmp/ric.log 2>&1 &
sleep 3
if ! pidof ric >/dev/null; then
    say "ric did not start -- ric.log:"
    cat /tmp/ric.log
    exit 1
fi
grep 'ric running' /tmp/ric.log

[ "$1" = "start" ] && exit 0

# --- the cover test ---------------------------------------------------------
sleep 2
nights=$(grep -c 'switched to NIGHT' /tmp/ric.log)
days=$(grep -c 'switched to DAY' /tmp/ric.log)

say "MAKE IT DARK NOW -- room lights off, or cover the lens (waiting for the night click)"
wait_switch NIGHT "$nights"
say "keep it DARK"
countdown $HOLD

days=$(grep -c 'switched to DAY' /tmp/ric.log)
say "LIGHT IT AGAIN NOW -- lights on, or uncover (waiting for the day click)"
wait_switch DAY "$days"
say "keep it LIT"
countdown $HOLD

# --- report -----------------------------------------------------------------
say "ric:"
grep -E "baseline|detected|switched|verification|probe|ir850" /tmp/ric.log
say "rvd:"
grep -E 'isp: (day|night)|fatal' /tmp/rvd.log
say "still running:"
ps | grep -E '[r]vd -f|[r]ic -f'
