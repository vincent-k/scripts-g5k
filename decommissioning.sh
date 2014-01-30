#!/bin/bash

# Get params
VM_BASE_IMG_DIR="$1"
VM_BACKING_IMG_DIR="$2"
REMOTE_USER="$3"
REMOTE_IP="$4"

# Get variables from config file
. ./config


function power_on_node {

	local NODE="$1"
	local LOG_DIR="$2"

	local START=$(date +%s)
	./power_on $NODE $BMC_USER $BMC_MDP /tmp
	local STOP=$(date +%s)

	if [ -n "$LOG_DIR" ]; then
		echo -e "$(($STOP - $START))" > $LOG_DIR/boot_time
		echo -e "START\t$START\nSTOP\t$STOP" > $LOG_DIR/boot
	fi

	sleep 5
}

function power_off_node {

	local NODE="$1"
	local LOG_DIR="$2"

	local START=$(date +%s)
	./power_off $NODE $BMC_USER $BMC_MDP /tmp
	local STOP=$(date +%s)

	if [ -n "$LOG_DIR" ]; then
		echo -e "$(($STOP - $START))" > $LOG_DIR/halt_time
		echo -e "START\t$START\nSTOP\t$STOP" > $LOG_DIR/halt
	fi
}

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

function migrate_node_par {

	local NODE_SRC="$1"
	local NODE_DEST="$2"
	local MIGRATE_DIR="$3" && mkdir "$MIGRATE_DIR"
	local PIDS=""

	# Boot the new node and get boot time
	power_on_node $NODE_DEST $MIGRATE_DIR

	for VM in `virsh --connect qemu+ssh://$SSH_USER@$NODE_SRC/system list | grep $VM_PREFIX | awk '{print $2;}'`; do
		echo "START $VM : $(date +%s)" | tee $MIGRATE_DIR/$VM
		migrate $VM $NODE_SRC $NODE_DEST && echo "STOP $VM : $(date +%s)" | tee -a $MIGRATE_DIR/$VM &
		PIDS+="$!\n"
	done
	for P in `echo -e $PIDS`; do wait $P; done
	
	# Shutdown the old node and get halt time
	power_off_node $NODE_SRC $MIGRATE_DIR
}

function migrate_node_seq {

	local NODE_SRC="$1"
        local NODE_DEST="$2"
	local MIGRATE_DIR="$3" && mkdir "$MIGRATE_DIR"
	
	# Boot the new node and get boot time
	power_on_node $NODE_DEST $MIGRATE_DIR

        for VM in `virsh --connect qemu+ssh://$SSH_USER@$NODE_SRC/system list | grep $VM_PREFIX | awk '{print $2;}'`; do
	
		echo -e "Migrating VMs from '$NODE_SRC' to '$NODE_DEST' :"

		echo "START $VM : $(date +%s)" | tee $MIGRATE_DIR/$VM
                migrate $VM $NODE_SRC $NODE_DEST && echo "STOP $VM : $(date +%s)" | tee -a $MIGRATE_DIR/$VM
        done

	# Shutdown the old node and get halt time
	power_off_node $NODE_SRC $MIGRATE_DIR
}

function decommissioning_par-par {

        local DECOMMISSIONING_DIR="$1"
	local PIDS=""
        mkdir "$DECOMMISSIONING_DIR"

	echo -e "############### DECOMMISSIONING : PARALLEL-PARALLEL MIGRATIONS #############"
	local NB_MIGRATE_NODES=$(cat $HOSTING_NODES | wc -l)
	for i in $(seq 1 $NB_MIGRATE_NODES); do
		local NODE_SRC=$(cat $HOSTING_NODES | head -$i | tail -1)
		local NODE_DEST=$(cat $IDLE_NODES | head -$i | tail -1)

		echo -e "Migrating VMs from '$NODE_SRC' to '$NODE_DEST' :"
		migrate_node_par $NODE_SRC $NODE_DEST $DECOMMISSIONING_DIR/$NODE_SRC &
		PIDS+="$!\n"
	done
	for P in `echo -e $PIDS`; do wait $P; done
	echo -e "###########################################################################\n"
}

function decommissioning_par-seq {

        local DECOMMISSIONING_DIR="$1"
	local PIDS=""
        mkdir "$DECOMMISSIONING_DIR"

	echo -e "############# DECOMMISSIONING : PARALLEL-SEQUENTIAL MIGRATIONS #############"
	local NB_MIGRATE_NODES=$(cat $HOSTING_NODES | wc -l)
	for i in $(seq 1 $NB_MIGRATE_NODES); do
		local NODE_SRC=$(cat $HOSTING_NODES | head -$i | tail -1)
		local NODE_DEST=$(cat $IDLE_NODES | head -$i | tail -1)

		echo -e "Migrating VMs from '$NODE_SRC' to '$NODE_DEST' :"
		migrate_node_seq $NODE_SRC $NODE_DEST $DECOMMISSIONING_DIR/$NODE_SRC &
		PIDS+="$!\n"
	done
	for P in `echo -e $PIDS`; do wait $P; done
	echo -e "###########################################################################\n"
}

function decommissioning_seq-par {

        local DECOMMISSIONING_DIR="$1"
        mkdir "$DECOMMISSIONING_DIR"

	echo -e "############# DECOMMISSIONING : SEQUENTIAL-PARALLEL MIGRATIONS #############"
	local NB_MIGRATE_NODES=$(cat $HOSTING_NODES | wc -l)
	for i in $(seq 1 $NB_MIGRATE_NODES); do
		local NODE_SRC=$(cat $HOSTING_NODES | head -$i | tail -1)
		local NODE_DEST=$(cat $IDLE_NODES | head -$i | tail -1)

		echo -e "Migrating VMs from '$NODE_SRC' to '$NODE_DEST' :"
		migrate_node_par $NODE_SRC $NODE_DEST $DECOMMISSIONING_DIR/$NODE_SRC
	done
	echo -e "###########################################################################\n"
}

function decommissioning_seq-seq {

        local DECOMMISSIONING_DIR="$1"
        mkdir "$DECOMMISSIONING_DIR"

	echo -e "############ DECOMMISSIONING : SEQUENTIAL-SEQUENTIAL MIGRATIONS ############"
	local NB_MIGRATE_NODES=$(cat $HOSTING_NODES | wc -l)
	for i in $(seq 1 $NB_MIGRATE_NODES); do
		local NODE_SRC=$(cat $HOSTING_NODES | head -$i | tail -1)
		local NODE_DEST=$(cat $IDLE_NODES | head -$i | tail -1)

		migrate_node_seq $NODE_SRC $NODE_DEST $DECOMMISSIONING_DIR/$NODE_SRC
	done
	echo -e "###########################################################################\n"
}

function start_workload_in_vms {

	local WORKLOAD_SCRIPT="$1"
	local SCRIPT_OPTIONS="$2"
	local RESULTS_DIR="$3"
	local VMS="$4"
	local PIDS=""
	mkdir $RESULTS_DIR

	echo -e "Starting workload in $(cat $VMS | wc -l) VMs..\n"
	for IP in `cat $VMS`; do
		./start_workload_in_vm $WORKLOAD_SCRIPT "$SCRIPT_OPTIONS" $RESULTS_DIR $IP $(cat $IPS_NAMES | grep $IP | head -1 | cut -f 1) &
		PIDS+="$!\n"
	done
	for P in `echo -e $PIDS`; do wait $P; done
}

function get_files_back {

	tar czf $RESULTS_DIR.tgz $RESULTS_DIR && sync
	scp $RESULTS_DIR.tgz $REMOTE_USER@$REMOTE_IP:~$REMOTE_USER/ > /dev/null
}


## MAIN

RESULTS_DIR="decommissioning_results"
VIRSH_OPTS=" --live "
#VIRSH_OPTS=" --live --copy-storage-inc "

rm -rf "$RESULTS_DIR" && mkdir "$RESULTS_DIR"

power_off_node $IDLE_NODES
sleep 5
./collect_energy_consumption $NODES_OK $BMC_USER $BMC_MDP $RESULTS_DIR/consumption &
COLLECT_ENERGY_TASK=$!
sleep 5
#start_workload_in_vms ./handbrake_workload "/opt/big_buck_bunny_480p_h264.mov" $RESULTS_DIR/workload $VMS_IPS &
#start_workload_in_vms ./handbrake_workload "/opt/Sintel.2010.1080p.mkv" $RESULTS_DIR/workload $VMS_IPS &
#start_workload_in_vms ./handbrake_workload "/opt/bluray-1080p-2go.mkv" $RESULTS_DIR/workload $VMS_IPS &
start_workload_in_vms ./apache_workload "100000000 50" $RESULTS_DIR/workload $VMS_IPS &
WORKLOAD=$!
sleep 5
decommissioning_par-par $RESULTS_DIR/decommissioning_par-par
#decommissioning_seq-seq $RESULTS_DIR/decommissioning_seq-seq
#decommissioning_par-seq $RESULTS_DIR/decommissioning_par-seq
#decommissioning_seq-par $RESULTS_DIR/decommissioning_seq-par
sleep 5
kill -TERM $COLLECT_ENERGY_TASK
wait $WORKLOAD
get_files_back

echo -e "\nEND OF DECOMMISSIONING"
