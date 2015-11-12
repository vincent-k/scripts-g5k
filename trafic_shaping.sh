#!/bin/bash
#
#  tc uses the following units when passed as a parameter.
#  kbps: Kilobytes per second
#  mbps: Megabytes per second
#  kbit: Kilobits per second
#  mbit: Megabits per second
#  bps: Bytes per second
#       Amounts of data can be specified in:
#       kb or k: Kilobytes
#       mb or m: Megabytes
#       mbit: Megabits
#       kbit: Kilobits

#
# Name of the traffic control command.
TC=/sbin/tc

# The network interface we're planning on limiting bandwidth.
IF=eth0             # Interface
IFB=ifb0	    # Virtual interface (usually doesn't change)

# Download limit (in mega bits)
DNLD=500mbit          # DOWNLOAD Limit

# Upload limit (in mega bits)
UPLD=500mbit          # UPLOAD Limit


start() {
	# Start the bandwidth shaping
	modprobe ifb numifbs=1
	ip link set dev $IFB up
	$TC qdisc add dev $IF handle ffff: ingress
	$TC filter add dev $IF parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev $IFB

	$TC qdisc add dev $IF root handle 1:0 htb default 10
	$TC class add dev $IF parent 1: classid 1:1 htb rate $UPLD
	$TC class add dev $IF parent 1:0 classid 1:10 htb rate $UPLD ceil $UPLD

	$TC qdisc add dev $IFB root handle 1: htb default 10
	$TC class add dev $IFB parent 1: classid 1:1 htb rate $DNLD
	$TC class add dev $IFB parent 1:1 classid 1:10 htb rate $DNLD
}

stop() {
	# Stop the bandwidth shaping
	$TC qdisc del dev $IFB root
	$TC qdisc del dev $IF root
	$TC qdisc del dev $IF ingress
	ip link set dev $IFB down
	modprobe -r ifb
}

restart() {
    stop
    sleep 1
    start
}


case "$1" in

  start)

    echo -n "Starting bandwidth shaping: "
    start
    echo "done"
    ;;

  stop)

    echo -n "Stopping bandwidth shaping: "
    stop
    echo "done"
    ;;

  restart)

    echo -n "Restarting bandwidth shaping: "
    restart
    echo "done"
    ;;

  *)

    pwd=$(pwd)
    echo "Usage: shaping {start|stop|restart}"
    ;;

esac

exit 0
