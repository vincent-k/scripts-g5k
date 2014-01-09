#!/bin/bash

IB_IF="$1"

# Load required modules
modprobe mlx4_ib
modprobe ib_ipoib

# Assign IP address
ip addr add $(host -t A `hostname -s`-$IB_IF | awk '{print $4;}')/20 dev $IB_IF
ip link set dev $IB_IF up
