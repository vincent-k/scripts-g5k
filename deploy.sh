#!/bin/bash

# Get options from cmdline
if [ $# -gt 0 ] ; then

	CTL_NODE_CLUSTER="$1"
	CLUSTER="$2"
	NB_VMS_PER_NODE="$3"
	IMG_CTL="$4"
	IMG_NODES="$5"
	VM_BASE_IMG="$6"
	VM_VCPU="$7"
	VM_MEM="$8"
	SHARED_STORAGE="$9"
else
	echo -e "This script requires parameters !"
	exit
fi

# Set some variables
USERNAME=`whoami`
#SSH_USER="$USERNAME"
SSH_USER="root"
OUTPUT_DIR="`pwd`/files"
CTL_NODE="$OUTPUT_DIR/ctl_node"
VM_BASE_IMG_NAME=`basename $VM_BASE_IMG`
NODES_LIST="$OUTPUT_DIR/nodes_list"
NODES_OK="$OUTPUT_DIR/nodes_ok"
HOSTING_NODES="$OUTPUT_DIR/hosting_nodes"
IPS_MACS="$OUTPUT_DIR/ips_macs"
SSH_OPTS=' -o StrictHostKeyChecking=no -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o LogLevel=quiet '
VM_PREFIX="vm-"
VM_BASE_IMG_DIR="/tmp" # Put the VM base img to local nodes directory by default

VM_BACKING_IMG_DIR="$VM_BASE_IMG_DIR" # Comment or set empty to disable backing imgs creation


function create_output_files {

	# Clean/Create the output directory
	if [ -d "$OUTPUT_DIR" ]; then
		rm -rf $OUTPUT_DIR/* && rm -rf $OUTPUT_DIR/.*
	else
		mkdir $OUTPUT_DIR
	fi

	# Get list of nodes
	cat $OAR_NODE_FILE | uniq | grep $CTL_NODE_CLUSTER | head -1  > $CTL_NODE
	cat $OAR_NODE_FILE | uniq | grep $CLUSTER  > $NODES_LIST
	sed -i '/'$(cat $CTL_NODE)'/d' $NODES_LIST
	echo -e "################# LIST OF RESERVED NODES #################"
	echo -ne "CTL : "
	cat $CTL_NODE
	cat $NODES_LIST
	echo -e "##########################################################\n"

	# Get list of ips and macs
	g5k-subnets -im > $IPS_MACS
	echo -e "############# LIST OF RESERVED IPs AND MACs ##############"
	head -5 $IPS_MACS
	echo -e "..."
	tail -5 $IPS_MACS
	echo -e "##########################################################\n"

	# Create/clean the other files
	echo > "$NODES_OK"
	echo > "$HOSTING_NODES"
}

function deploy_ctl {

	# Deploy the CTL node
	echo -e "################## CTL NODE DEPLOYMENT ###################"
	kadeploy3 -e $IMG_CTL -f $CTL_NODE --output-ok-nodes $CTL_NODE -k
	echo -e "##########################################################\n"

	# Quit if deployment failed
	if [ `cat $CTL_NODE | uniq | grep $CTL_NODE_CLUSTER | wc -l` -eq 0 ]; then
		echo -e "\nCANCELING !"
		#oardel $OAR_JOB_ID
		## Delete the storage reservation if exist
		#if [ -n "$SHARED_STORAGE" ]; then
		#	oardel $SHARED_STORAGE
		#fi
		exit
	fi
}

function deploy_nodes {

	# Deploy IMG_NODES to all the nodes and get list of nodes_ok
	echo -e "################### NODES DEPLOYMENT #####################"
	kadeploy3 -e $IMG_NODES -f $NODES_LIST --output-ok-nodes $NODES_OK -k
	NB_NODES=`cat $NODES_OK | uniq | wc -l`
	echo -e "##########################################################\n"

	# Show the diff between nodes deployed and nodes ok
	sort $NODES_LIST -o $NODES_LIST && sort $NODES_OK -o $NODES_OK
	echo -e "######## DIFF BETWEEN RESERVED AND DEPLOYED NODES ########"
	diff -u $NODES_LIST $NODES_OK
	echo -e "##########################################################\n"

	echo -ne "Waiting for nodes networking configuration .." && sleep 60 && echo -e "\n"
}

function define_hosting_nodes {

	head -$(( `cat $NODES_OK | wc -l` / 2 )) $NODES_OK > $HOSTING_NODES
	NB_HOSTING_NODES=$(cat $HOSTING_NODES | wc -l)
}

function mount_shared_storage {

	# Mount storage in all nodes
	echo -e "################# MOUNT SHARED STORAGE  ##################"
	STORAGE_MOUNT=`storage5k -a mount -j $OAR_JOB_ID 2>&1`
	echo -e "$STORAGE_MOUNT"
	echo -e "##########################################################\n"
	if [ `echo -e "$STORAGE_MOUNT" | grep Success | wc -l` -eq 0 ]; then
		echo -e "\nCANCELING !"
		oardel $SHARED_STORAGE
		oardel $OAR_JOB_ID
		exit
	fi

	# Change the remote directory to the shared storage (base img)
	VM_BASE_IMG_DIR="/data/$USERNAME"
	VM_BASE_IMG_DIR+="_$SHARED_STORAGE"

	# Give it more permissions
	chmod go+rwx $VM_BASE_IMG_DIR && chmod -R go+rw $VM_BASE_IMG_DIR
}

function duplicate_imgs_in_node {

	local VM_INDEX=$1
	local NODE="$2"

	echo -en " Duplicating img base for each VM in node $NODE .."

	for (( i=0 ; i<=$NB_VMS_PER_NODE ; i++ )); do
		local VM_NAME="$VM_PREFIX$(($VM_INDEX + $i))"
		local NODE_IMG="$VM_BASE_IMG_DIR/$VM_NAME.${VM_BASE_IMG##*.}"
		if ( ssh $SSH_USER@$NODE $SSH_OPTS ''[ ! -e $NODE_IMG ]'' ); then
			ssh $SSH_USER@$NODE $SSH_OPTS "cp $VM_BASE_IMG_DIR/$VM_BASE_IMG_NAME $NODE_IMG"
		fi
	done
	ssh $SSH_USER@$NODE $SSH_OPTS "sync"

	echo -e ". Done\n"
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

function duplicate_imgs_in_shared_storage {

	local NB_VMS=$1

	echo -e "Duplicate $NB_VMS imgs in shared storage :"
	for (( i=1 ; i<=$NB_VMS ; i++ )); do
		local VM_NAME="$VM_PREFIX$i"
		local NODE_IMG="$VM_BASE_IMG_DIR/$VM_NAME.${VM_BASE_IMG##*.}"
		cp $VM_BASE_IMG_DIR/$VM_BASE_IMG_NAME $NODE_IMG
	done
}

function prepare_vms_in_node {

	local VM_INDEX=$1
	local NODE="$2"

	for (( i=0 ; i<$NB_VMS_PER_NODE ; i++ )); do
		local VM_NUM=$(($VM_INDEX + $i))
		local IP=`cat $IPS_MACS | head -$VM_NUM | tail -1 | cut -f1`

		if [ -n "$VM_BACKING_IMG_DIR" ]; then
			local IMG_DIR="$VM_BACKING_IMG_DIR"
		else
			local IMG_DIR="$VM_BASE_IMG_DIR"
		fi

		# Execute the script "prepare_vm_in_node"
                ./prepare_vm_in_node $VM_PREFIX$VM_NUM $NODE $IP $IMG_DIR
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
}

function create_backing_imgs_in_node {

	local VM_INDEX=$1
	local NODE="$2"

	for (( i=0 ; i<$NB_VMS_PER_NODE ; i++ )); do
		local VM_NUM=$(($VM_INDEX + $i))
		local VM_NAME="$VM_PREFIX$VM_NUM"
		local NODE_IMG="$VM_BASE_IMG_DIR/$VM_NAME.${VM_BASE_IMG##*.}"

                # Execute the script "create_backing_img"
		./create_backing_img $NODE $VM_NAME $NODE_IMG $VM_BACKING_IMG_DIR
        done
}

function create_backing_imgs_in_nodes {

	local NODES="$1"
	local VM_INDEX=1

	echo -e "Creating $NB_VMS_PER_NODE backing imgs per node in $(cat $NODES|wc -l) hosting nodes :"
	for NODE in `cat $NODES`; do
		create_backing_imgs_in_node $VM_INDEX $NODE &
		VM_INDEX=$(( $VM_INDEX + $NB_VMS_PER_NODE ))
	done
	wait
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
                ./start_vm_in_node $NODE $NODE_IMG $VM_MEM $MAC
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
	echo -ne "\nWaiting for VMs booting .." && sleep $((30 + (2*2*$NB_VMS_PER_NODE*$NB_VMS_PER_NODE))) && echo -e "\n"
}

function start_expe {

	local SCRIPT="$1"
	NODE=$(cat $CTL_NODE)

	# Send output directory to CTL node
	scp $SSH_OPTS -r $OUTPUT_DIR $SSH_USER@$NODE:~

	# Send some scripts
	scp $SSH_OPTS ./create_backing_img $SSH_USER@$NODE:~
	scp $SSH_OPTS ./migrate_vm $SSH_USER@$NODE:~
	
	# Send and start experimentation script to the CTL node
	echo -e "Send and execute experimentation script to the CTL :\n"
	scp $SSH_OPTS $SCRIPT $SSH_USER@$NODE:~
	ssh $SSH_USER@$NODE $SSH_OPTS "~$SSH_USER/$SCRIPT $NB_HOSTING_NODES $NB_VMS_PER_NODE $SSH_USER $(basename $OUTPUT_DIR) $VM_BASE_IMG_DIR $VM_PREFIX $VM_BACKING_IMG_DIR"
}


create_output_files
deploy_ctl
deploy_nodes
if [ -n "$SHARED_STORAGE" ]; then mount_shared_storage ; fi
define_hosting_nodes
./send_img_to_nodes $HOSTING_NODES $VM_BASE_IMG $VM_BASE_IMG_DIR
if [ -n "$SHARED_STORAGE" ]; then
	duplicate_imgs_in_nodes $HOSTING_NODES
else
	duplicate_imgs_in_shared_storage $(($NB_VMS_PER_NODE*$(cat $HOSTING_NODES|wc -l)))
fi
if [ -n "$VM_BACKING_IMG_DIR" ]; then create_backing_imgs_in_nodes $HOSTING_NODES ; fi
prepare_vms_in_nodes $HOSTING_NODES
start_vms_in_nodes $HOSTING_NODES
start_expe "./expe.sh"

echo -e "\nALL FINISHED !"

# Wait the end of walltime
while [ true ]; do sleep 60 ; done

