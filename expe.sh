#!/bin/bash

# Get params
NB_HOSTING_NODES="$1"
NB_VMS_PER_NODE="$2"
SSH_USER="$3"
OUTPUT_DIR="$HOME/$4"
BASE_IMG_DIR="$5"
BACKING_IMG_DIR="$6"
BASE_IMG_NAME="$7"
VM_PREFIX="$8"

# Define vars
NODES_LIST="$OUTPUT_DIR/nodes_list"
NODES_OK="$OUTPUT_DIR/nodes_ok"
IPS_MACS="$OUTPUT_DIR/ips_macs"
CTL_NODE="$OUTPUT_DIR/ctl_node"
SSH_OPTS=' -o StrictHostKeyChecking=no -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o LogLevel=quiet '

REPETITION=2
RESULTS_DIR="results"


function migrate {

	local VM_NAME="$1"
	local NODE_SRC="$2"
	local NODE_DEST="$3"

	local SRC_IMG="$VM_BASE_IMG_DIR/$VM_NAME.${VM_BASE_IMG##*.}"

	# Execute the script "create_backing_img"
	./create_backing_img $NODE_DEST $VM_NAME $SRC_IMG $BACKING_IMG_DIR

	# Execute the script "migrate_vm"
	./migrate_vm $VM_NAME $NODE_SRC $NODE_DEST $VIRSH_OPTS

	# Delete backing img from source node
	local BACKING_IMG="$BACKING_IMG_DIR/$VM_NAME.qcow2"
	if ( ssh $SSH_USER@$NODE_SRC $SSH_OPTS ''[ ! -e $BACKING_IMG ]'' ); then
		ssh $SSH_USER@$NODE_SRC $SSH_OPTS "rm -rf $BACKING_IMG"
	fi
}

function migrate_par {

	local NODE_SRC="$1"
	local NODE_DEST="$2"
	local MIGRATE_DIR="$3"

	mkdir "$MIGRATE_DIR"
	for VM in `virsh --connect qemu+ssh://$SSH_USER@$NODE_SRC/system list | grep $VM_PREFIX | awk '{print $2;}'`; do
		echo "START $VM : $(date)" | tee $MIGRATE_DIR/$VM
		migrate $VM $NODE_SRC $NODE_DEST && echo "STOP $VM : $(date)" | tee -a $MIGRATE_DIR/$VM &
	done

	wait
}

function migrate_seq {

	local NODE_SRC="$1"
        local NODE_DEST="$2"
	local MIGRATE_DIR="$3"

	mkdir "$MIGRATE_DIR"
        for VM in `virsh --connect qemu+ssh://$SSH_USER@$NODE_SRC/system list | grep $VM_PREFIX | awk '{print $2;}'`; do
		echo "START $VM : $(date)" | tee $MIGRATE_DIR/$VM
                migrate $VM $NODE_SRC $NODE_DEST && echo "STOP $VM : $(date)" | tee -a $MIGRATE_DIR/$VM
        done
}

function scenario_1 {

        local SCENARIO_DIR="$1"
        mkdir "$SCENARIO_DIR"

	echo -e "############### SCENARIO 1 : PARALLEL-PARALLEL MIGRATIONS #############"
	local NODE_DEST_NUM=$NB_HOSTING_NODES
	for NODE_SRC in `head -$NB_HOSTING_NODES $NODES_OK`; do
		NODE_DEST=$(tail -$NODE_DEST_NUM $NODES_OK | head -1)
		migrate_par $NODE_SRC $NODE_DEST $SCENARIO_DIR/$NODE_SRC &
		NODE_DEST_NUM=$(( $NODE_DEST_NUM - 1 ))	
	done
	wait
	echo -e "#######################################################################\n"

	sleep 30
}

function scenario_2 {

        local SCENARIO_DIR="$1"
        mkdir "$SCENARIO_DIR"

	echo -e "############# SCENARIO 2 : PARALLEL-SEQUENTIAL MIGRATIONS #############"
	local NODE_DEST_NUM=$(cat $NODES_OK | wc -l)
	for NODE_SRC in `tail -$NB_HOSTING_NODES $NODES_OK`; do
		NODE_DEST=$(tail -$NODE_DEST_NUM $NODES_OK | head -1)
		migrate_seq $NODE_SRC $NODE_DEST $SCENARIO_DIR/$NODE_SRC &
		NODE_DEST_NUM=$(( $NODE_DEST_NUM - 1 ))	
	done
	wait
	echo -e "#######################################################################\n"

	sleep 30
}

function scenario_3 {

        local SCENARIO_DIR="$1"
        mkdir "$SCENARIO_DIR"

	echo -e "############# SCENARIO 3 : SEQUENTIAL-PARALLEL MIGRATIONS #############"
	local NODE_DEST_NUM=$NB_HOSTING_NODES
	for NODE_SRC in `head -$NB_HOSTING_NODES $NODES_OK`; do
		NODE_DEST=$(tail -$NODE_DEST_NUM $NODES_OK | head -1)
		migrate_par $NODE_SRC $NODE_DEST $SCENARIO_DIR/$NODE_SRC
		NODE_DEST_NUM=$(( $NODE_DEST_NUM - 1 )) 
	done
	echo -e "#######################################################################\n"

	sleep 30
}

function scenario_4 {

        local SCENARIO_DIR="$1"
        mkdir "$SCENARIO_DIR"

	echo -e "############ SCENARIO 4 : SEQUENTIAL-SEQUENTIAL MIGRATIONS ############"
	local NODE_DEST_NUM=$(cat $NODES_OK | wc -l)
	for NODE_SRC in `tail -$NB_HOSTING_NODES $NODES_OK`; do
		NODE_DEST=$(tail -$NODE_DEST_NUM $NODES_OK | head -1)
		migrate_seq $NODE_SRC $NODE_DEST $SCENARIO_DIR/$NODE_SRC
		NODE_DEST_NUM=$(( $NODE_DEST_NUM - 1 ))
	done
	echo -e "#######################################################################\n"

	sleep 30
}

function launch_migration_scenarios {

	local LAUNCH_DIR="$1"
	mkdir "$LAUNCH_DIR"

	# Scenario 1 : Parallel Nodes , Parallel VMs
	scenario_1 $LAUNCH_DIR/scenario_1

	# Scenario 2 : Parallel Nodes , Sequential VMs
	scenario_2 $LAUNCH_DIR/scenario_2

	# Scenario 3 : Sequetial Nodes , Parallel VMs
	scenario_3 $LAUNCH_DIR/scenario_3

	# Scenario 4 : Sequential Nodes , Sequential VMs
	scenario_4 $LAUNCH_DIR/scenario_4
}

function get_files_back {
	tar czf $RESULTS_DIR.tgz $RESULTS_DIR && sync
	scp $RESULTS_DIR.tgz vinkherbache@fsophia:/home/vinkherbache/
}


mkdir "$RESULTS_DIR"
 
VIRSH_OPTS=" --live --copy-storage-inc "
for (( i=1 ; i<=$REPETITION ; i++ )); do
	launch_migration_scenarios $RESULTS_DIR/storage-inc_scenarios-N$i
done
sleep 60

VIRSH_OPTS=" --live --copy-storage-all "
for (( i=1 ; i<=$REPETITION ; i++ )); do
	launch_migration_scenarios $RESULTS_DIR/storage-all_scenarios-N$i
done
sleep 60

get_files_back

echo -e "\nEND OF EXPERIMENTATION"

