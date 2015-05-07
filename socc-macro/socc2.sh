#!/bin/bash

. ./config

function set_allocated_mem {
	
	# Set the allocated memory size of VMs
	for NODE in `cat $HOSTING_NODES`; do
		#./define_ram $NODE 1 "2G" &
		./define_ram $NODE 2 "4G" &
	done
	wait
}

function set_used_mem {
	
	# Set the amount of memory used by VMs
	for NODE in `cat $HOSTING_NODES`; do
		# 2Go
		./use_ram $NODE 1 " --vm 1000 --vm-bytes 1400k " &
		# 4Go
		./use_ram $NODE 2 " --vm 1000 --vm-bytes 3550k " &
	done
	wait
}

function set_workload {
	
	# Start a workload inside VMs
	local NUM=0
	for NODE in `cat $HOSTING_NODES`; do
		if [ $(($NUM % 2)) -eq 0 ]; then
			./run_workload $NODE 2 " --vm 1000 --vm-bytes 70k " &
		else
			./run_workload $NODE 1 " --vm 1000 --vm-bytes 70k " &
		fi
		NUM=$(($NUM+1))
	done
	wait
}

function shutdown_dest_nodes {
	
	for NODE in `cat $IDLE_NODES`; do
		ssh $SSH_USER@$NODE $SSH_OPTS 'halt' &
	done
	wait
}

## MAIN

#shutdown_dest_nodes

set_allocated_mem
sleep 60

set_used_mem

set_workload
