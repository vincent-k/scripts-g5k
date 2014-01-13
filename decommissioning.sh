#!/bin/bash

# Get params
VM_BASE_IMG_DIR="$1"
VM_BACKING_IMG_DIR="$2"
REMOTE_IP="$3"

# Get variables from config file
. ./config


function migrate {

	local VM_NAME="$1"
	local NODE_SRC="$2"
	local NODE_DEST="$3"

	if [ -n "$VM_BACKING_IMG_DIR" ]; then
		local SRC_IMG="$VM_BASE_IMG_DIR/$VM_BASE_IMG_NAME"
	else
		local SRC_IMG="$VM_BASE_IMG_DIR/$VM_NAME.${VM_BASE_IMG##*.}"
	fi

	# Create base img / backing img to the destination node
	if [ -n "$VM_BACKING_IMG_DIR" ]; then
		# If backing img is not on shared storage
		if [ "$VM_BACKING_IMG_DIR" == "/tmp" ]; then
			# Execute the script "create_backing_img"
			./create_backing_img $NODE_DEST $VM_NAME $SRC_IMG $VM_BACKING_IMG_DIR
		fi
	else
		# If base img is not on shared storage
		if [ "$VM_BASE_IMG_DIR" == "/tmp" ]; then
			# Create a new empty img with the same size as the src img
			IMG_SIZE=$(ssh $SSH_USER@$NODE_SRC $SSH_OPTS "du -b $SRC_IMG | cut -f1")
			ssh $SSH_USER@$NODE_DEST $SSH_OPTS "dd if=/dev/zero of=$SRC_IMG bs=1 count=0 seek=$IMG_SIZE >/dev/null"
		fi
	fi

	# Execute the script "migrate_vm"
	./migrate_vm $VM_NAME $NODE_SRC $NODE_DEST "$VIRSH_OPTS"

	# Delete base img/backing img from source node
	if [ -n "$VM_BACKING_IMG_DIR" ]; then
		# If backing img is not on shared storage
		if [ "$VM_BACKING_IMG_DIR" == "/tmp" ]; then
			ssh $SSH_USER@$NODE_SRC $SSH_OPTS "rm -rf $VM_BACKING_IMG_DIR/$VM_NAME.qcow2"
		fi
	else
		# If base img is not on shared storage
		if [ "$VM_BASE_IMG_DIR" == "/tmp" ]; then
			ssh $SSH_USER@$NODE_SRC $SSH_OPTS "rm -rf $SRC_IMG"
		fi
	fi
}

function power_on_node {

	local NODE="$1"
	local LOG_DIR="$2"

	local START=$(date +%s)
	./power_on $NODE
	local STOP=$(date +%s)

	echo -e "$(($STOP - $START))" > $LOG_DIR/boot_time
}

function power_off_node {

	local NODE="$1"
	local LOG_DIR="$2"

	local START=$(date +%s)
	./power_off $NODE
	local STOP=$(date +%s)

	echo -e "$(($STOP - $START))" > $LOG_DIR/halt_time
}

function migrate_par {

	local NODE_SRC="$1"
	local NODE_DEST="$2"
	local MIGRATE_DIR="$3" && mkdir "$MIGRATE_DIR"

	# Boot the new node and get boot time
	power_on_node $NODE_DEST $MIGRATE_DIR

	for VM in `virsh --connect qemu+ssh://$SSH_USER@$NODE_SRC/system list | grep $VM_PREFIX | awk '{print $2;}'`; do
		echo "START $VM : $(date)" | tee $MIGRATE_DIR/$VM
		migrate $VM $NODE_SRC $NODE_DEST && echo "STOP $VM : $(date)" | tee -a $MIGRATE_DIR/$VM &
	done

	wait

	# Shutdown the old node and get halt time
	power_off_node $NODE_SRC $MIGRATE_DIR
}

function migrate_seq {

	local NODE_SRC="$1"
        local NODE_DEST="$2"
	local MIGRATE_DIR="$3" && mkdir "$MIGRATE_DIR"
	
	# Boot the new node and get boot time
	power_on_node $NODE_DEST $MIGRATE_DIR

        for VM in `virsh --connect qemu+ssh://$SSH_USER@$NODE_SRC/system list | grep $VM_PREFIX | awk '{print $2;}'`; do
		echo "START $VM : $(date)" | tee $MIGRATE_DIR/$VM
                migrate $VM $NODE_SRC $NODE_DEST && echo "STOP $VM : $(date)" | tee -a $MIGRATE_DIR/$VM
        done

	# Shutdown the old node and get halt time
	power_off_node $NODE_SRC $MIGRATE_DIR
}

function scenario_par-par {

        local SCENARIO_DIR="$1"
        mkdir "$SCENARIO_DIR"

	echo -e "############### SCENARIO 1 : PARALLEL-PARALLEL MIGRATIONS #############"
	local NB_MIGRATE_NODES=$(cat $HOSTING_NODES | wc -l)
	for i in $(seq 1 $NB_MIGRATE_NODES); do
		local NODE_SRC=$(cat $HOSTING_NODES | head -$NB_MIGRATE_NODES | tail -1)
		local NODE_DEST=$(cat $IDLE_NODES | head -$NB_MIGRATE_NODES | tail -1)

		migrate_par $NODE_SRC $NODE_DEST $SCENARIO_DIR/$NODE_SRC &
	done
	wait
	echo -e "#######################################################################\n"
}

function scenario_par-seq {

        local SCENARIO_DIR="$1"
        mkdir "$SCENARIO_DIR"

	echo -e "############# SCENARIO 2 : PARALLEL-SEQUENTIAL MIGRATIONS #############"
	local NB_MIGRATE_NODES=$(cat $HOSTING_NODES | wc -l)
	for i in $(seq 1 $NB_MIGRATE_NODES); do
		local NODE_SRC=$(cat $HOSTING_NODES | head -$NB_MIGRATE_NODES | tail -1)
		local NODE_DEST=$(cat $IDLE_NODES | head -$NB_MIGRATE_NODES | tail -1)

		migrate_seq $NODE_SRC $NODE_DEST $SCENARIO_DIR/$NODE_SRC &
	done
	wait
	echo -e "#######################################################################\n"
}

function scenario_seq-par {

        local SCENARIO_DIR="$1"
        mkdir "$SCENARIO_DIR"

	echo -e "############# SCENARIO 3 : SEQUENTIAL-PARALLEL MIGRATIONS #############"
	local NB_MIGRATE_NODES=$(cat $HOSTING_NODES | wc -l)
	for i in $(seq 1 $NB_MIGRATE_NODES); do
		local NODE_SRC=$(cat $HOSTING_NODES | head -$NB_MIGRATE_NODES | tail -1)
		local NODE_DEST=$(cat $IDLE_NODES | head -$NB_MIGRATE_NODES | tail -1)

		migrate_par $NODE_SRC $NODE_DEST $SCENARIO_DIR/$NODE_SRC
	done
	echo -e "#######################################################################\n"
}

function scenario_seq-seq {

        local SCENARIO_DIR="$1"
        mkdir "$SCENARIO_DIR"

	echo -e "############ SCENARIO 4 : SEQUENTIAL-SEQUENTIAL MIGRATIONS ############"
	local NB_MIGRATE_NODES=$(cat $HOSTING_NODES | wc -l)
	for i in $(seq 1 $NB_MIGRATE_NODES); do
		local NODE_SRC=$(cat $HOSTING_NODES | head -$NB_MIGRATE_NODES | tail -1)
		local NODE_DEST=$(cat $IDLE_NODES | head -$NB_MIGRATE_NODES | tail -1)

		migrate_seq $NODE_SRC $NODE_DEST $SCENARIO_DIR/$NODE_SRC
	done
	echo -e "#######################################################################\n"
}

function start_workload_in_vms {

	local WORKLOAD_SCRIPT="$1"
	local SCRIPT_OPTIONS="$2"
	local RESULTS_DIR="$3"
	local VMS="$4"

	mkdir $RESULTS_DIR
	echo -e "Starting workload in $(cat $VMS | wc -l) VMs :"
	for IP in `cat $VMS`; do
		./start_workload_in_vm $WORKLOAD_SCRIPT "$SCRIPT_OPTIONS" $RESULTS_DIR $IP &
	done
	wait
}


	sleep 5
}

function get_files_back {
	tar czf $RESULTS_DIR.tgz $RESULTS_DIR && sync
	scp $RESULTS_DIR.tgz vinkherbache@$REMOTE_IP:/home/vinkherbache/
}


## MAIN

RESULTS_DIR="decommissioning_results"
#VIRSH_OPTS=" --live --copy-storage-inc "
VIRSH_OPTS=" --live "

mkdir "$RESULTS_DIR"
scenario_par-par $RESULTS_DIR/scenario_par-par

get_files_back

echo -e "\nEND OF DECOMMISSIONING"
