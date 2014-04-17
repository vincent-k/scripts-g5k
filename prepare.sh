#!/bin/bash

# Get variables from config file
. ./config

# Get parameters
VM_BASE_IMG_DIR="$1"
if [ -n "$BACKING_DIR" ]; then
	VM_BACKING_IMG_DIR="$2"
fi


function remove_bad_nodes {

	for NODE in `cat $HOSTING_NODES`; do
		if [ $(cat $NODES_OK | grep $NODE | wc -l) -eq 0 ]; then
			sed -i "/$NODE/d" $HOSTING_NODES
		fi
	done

	for NODE in `cat $IDLE_NODES`; do
		if [ $(cat $NODES_OK | grep $NODE | wc -l) -eq 0 ]; then
			sed -i "/$NODE/d" $IDLE_NODES
		fi
	done

	HOSTING_NB=$(cat $HOSTING_NODES | wc -l)
	IDLE_NB=$(cat $IDLE_NODES | wc -l)

	if [ $HOSTING_NB -gt $IDLE_NB ]; then
		sed -i "1,$(($HOSTING_NB-$IDLE_NB))d" $HOSTING_NODES
	elif [ $IDLE_NB -gt $HOSTING_NB ]; then
		sed -i "1,$(($IDLE_NB-$HOSTING_NB))d" $IDLE_NODES
	fi
}

function send_to_ctl {

	local SRC="$1"
	local DEST_DIR="$2"

	scp $SSH_OPTS -r $SRC $SSH_USER@$(cat $CTL_NODE):$DEST_DIR > /dev/null
}

function duplicate_imgs_in_node {

	local VM_INDEX=$1
	local NODE="$2"

	for (( i=0 ; i<=$NB_VMS_PER_NODE ; i++ )); do
		local VM_NAME="$VM_PREFIX$(($VM_INDEX + $i))"
		local NODE_IMG="$VM_BASE_IMG_DIR/$VM_NAME.${VM_BASE_IMG##*.}"
		if ( ssh $SSH_USER@$NODE $SSH_OPTS ''[ ! -e $NODE_IMG ]'' ); then
			ssh $SSH_USER@$NODE $SSH_OPTS "cp $VM_BASE_IMG_DIR/$VM_BASE_IMG_NAME $NODE_IMG"
		fi
	done
	ssh $SSH_USER@$NODE $SSH_OPTS "sync"

	echo -e " $NODE DONE\n"
}

function duplicate_imgs_in_nodes {

	local NODES="$1"
	local VM_INDEX=1

	echo -e "Duplicate $NB_VMS_PER_NODE imgs per node in $(cat $NODES|wc -l) nodes :"
	for NODE in `cat $NODES`; do
		duplicate_imgs_in_node $VM_INDEX $NODE &
		VM_INDEX=$(( $VM_INDEX + $NB_VMS_PER_NODE ))
	done
	wait
}

function prepare_vms_in_node {

	local VM_INDEX=$1
	local NODE="$2"

	echo -n > $IPS_NAMES

	for (( i=0 ; i<$NB_VMS_PER_NODE ; i++ )); do
		local VM_NUM=$(($VM_INDEX + $i))
		local IP=`cat $IPS_MACS | head -$VM_NUM | tail -1 | cut -f1`

		if [ -n "$VM_BACKING_IMG_DIR" ]; then
			local IMG_DIR="$VM_BACKING_IMG_DIR"
		else
			local IMG_DIR="$VM_BASE_IMG_DIR"
		fi

		# Execute the script "prepare_vm_in_node"
                ./prepare_vm_in_node $VM_PREFIX$VM_NUM $NODE $IP $IMG_DIR "$(cat $CTL_NODE)"

		# Fill a file with ip/name values
		echo -e "$VM_PREFIX$VM_NUM\t$IP" >> $IPS_NAMES
        done
}

function prepare_vms_in_nodes {

	local NODES="$1"
	local VM_INDEX=1

	echo -e "Preparing $NB_VMS_PER_NODE VMs per node in $(cat $NODES|wc -l) nodes :"
	for NODE in `cat $NODES`; do
		prepare_vms_in_node $VM_INDEX $NODE &
		VM_INDEX=$(( $VM_INDEX + $NB_VMS_PER_NODE ))
	done
	wait

	cat $IPS_MACS | head -$(($(cat $NODES | wc -l) * $NB_VMS_PER_NODE)) | cut -f1 > $VMS_IPS
	echo
}

function create_backing_imgs_in_node {

	local VM_INDEX=$1
	local NODE="$2"
	local NODE_IMG="$VM_BASE_IMG_DIR/$VM_BASE_IMG_NAME"

	# Create remote backing dir
	ssh $SSH_USER@$NODE $SSH_OPTS "mkdir $VM_BACKING_IMG_DIR 2>/dev/null"

	for (( i=0 ; i<$NB_VMS_PER_NODE ; i++ )); do
		local VM_NUM=$(($VM_INDEX + $i))
		local VM_NAME="$VM_PREFIX$VM_NUM"

		if [ ! -n "$VM_BACKING_IMG_DIR" ]; then
			local NODE_IMG="$VM_BASE_IMG_DIR/$VM_NAME.${VM_BASE_IMG##*.}"
		fi

                # Execute the script "create_backing_img"
		./create_backing_img $NODE $VM_NAME $NODE_IMG $VM_BACKING_IMG_DIR
        done
}

function create_backing_imgs_in_nodes {

	local NODES="$1"
	local VM_INDEX=1

	echo -ne "Creating $NB_VMS_PER_NODE backing imgs per node in $(cat $NODES|wc -l) hosting nodes.."
	for NODE in `cat $NODES`; do
		create_backing_imgs_in_node $VM_INDEX $NODE &
		VM_INDEX=$(( $VM_INDEX + $NB_VMS_PER_NODE ))
	done
	wait
	echo -e ". DONE\n"
}

function start_vms_in_node {

	local VM_INDEX=$1
	local NODE="$2"

	for (( i=0 ; i<$NB_VMS_PER_NODE ; i++ )); do
		local VM_NUM=$(($VM_INDEX + $i))
		local VM_NAME="$VM_PREFIX$VM_NUM"
		local MAC="$(cat $IPS_MACS | head -$VM_NUM | tail -1 | cut -f2)"

		if [ -n "$VM_BACKING_IMG_DIR" ]; then
			local NODE_IMG="$VM_BACKING_IMG_DIR/$VM_NAME.qcow2"
		else
			local NODE_IMG="$VM_BASE_IMG_DIR/$VM_NAME.${VM_BASE_IMG##*.}"
		fi

		## Execute the script "start_vm_in_node"
                ./start_vm_in_node $NODE $NODE_IMG $VM_VCPU $VM_MEM $MAC
        done
}

function start_vms_in_nodes {

	local NODES="$1"
	local VM_INDEX=1

	echo -e "Starting $NB_VMS_PER_NODE VMs per node in $(cat $NODES|wc -l) nodes :"
	for NODE in `cat $NODES`; do
		start_vms_in_node $VM_INDEX $NODE &
		VM_INDEX=$(( $VM_INDEX + $NB_VMS_PER_NODE ))
	done
	wait
	echo
}

function wait_for_vms_to_boot {

	local VMS="$1"
	local CTL_NODE_NAME="$(cat $CTL_NODE)"

	send_to_ctl $VMS
	send_to_ctl ./rWait
	ssh $SSH_USER@$(cat $CTL_NODE) $SSH_OPTS "python ~$SSH_USER/rWait $(host `cat $CTL_NODE` | awk '{print $4;}') ~$SSH_USER/$(basename $VMS)"
	echo
}

function start_expe {

	local SCRIPT="$1"
	local SCRIPT_OPTS="$2"

	# Send output directory to CTL node
	send_to_ctl $OUTPUT_DIR

	# Send config file to the CTL
	send_to_ctl ./config

	# Send some scripts (dependencies)
	send_to_ctl ./power_on
	send_to_ctl ./power_off
	send_to_ctl ./create_backing_img
	send_to_ctl ./migrate_vm
	send_to_ctl ./collect_energy_consumption
	send_to_ctl ./start_workload_in_vm
	send_to_ctl ./get_workload_stats
	send_to_ctl ./handbrake_workload
	send_to_ctl ./apache_workload
	send_to_ctl ./httperf_workload
	
	# Send and start experimentation script to the CTL node
	echo -e "Send and execute experimentation script to the CTL :\n"
	send_to_ctl ./$SCRIPT
	ssh $SSH_USER@$(cat $CTL_NODE) $SSH_OPTS "~$SSH_USER/$SCRIPT $SCRIPT_OPTS"
}


## MAIN

remove_bad_nodes
./send_img_to_nodes $HOSTING_NODES $VM_BASE_IMG $VM_BASE_IMG_DIR
if [ ! -n "$SHARED_STORAGE" ]; then duplicate_imgs_in_nodes $HOSTING_NODES ; fi
if [ -n "$VM_BACKING_IMG_DIR" ]; then create_backing_imgs_in_nodes $HOSTING_NODES ; fi
prepare_vms_in_nodes $HOSTING_NODES
start_vms_in_nodes $HOSTING_NODES
wait_for_vms_to_boot $VMS_IPS

# Start experiment
start_expe "decommissioning.sh" "$VM_BASE_IMG_DIR $VM_BACKING_IMG_DIR $(whoami) $(ip a | grep inet | grep eth0 | awk '{print $2;}' | cut -d'/' -f1)"
