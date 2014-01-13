#!/bin/bash

# Get variables from config file
. ./config

if [ -n $SHARED_STORAGE ]; then
	SHARED_STORAGE="$1"
fi

if [ -n "$BACKING_DIR" ]; then
	VM_BACKING_IMG_DIR="$VM_BASE_IMG_DIR/$BACKING_DIR";
fi


function create_output_files {

	# Clean/Create the output directory
	if [ -d "$OUTPUT_DIR" ]; then
		rm -rf $OUTPUT_DIR/* && rm -rf $OUTPUT_DIR/.* >/dev/null 2>&1
	else
		mkdir $OUTPUT_DIR
	fi

	# Define the CTL node
	cat $OAR_NODE_FILE | uniq | grep $CTL_NODE_CLUSTER | head -1  > $CTL_NODE
	cat $OAR_NODE_FILE | uniq | grep $CLUSTER  > $NODES_LIST
	sed -i '/'$(cat $CTL_NODE)'/d' $NODES_LIST

	# Define the first node as NFS server
	if [ -n "$NFS_SRV" ]; then
	        head -1 $NODES_LIST > $NFS_SRV
	        echo -e "$(tail -$(( `cat $NODES_LIST | wc -l` - 1 )) $NODES_LIST)" > $NODES_LIST
	fi

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
	echo > "$VMS_IPS"
	echo > "$IPS_NAMES"
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

function deploy_nfs_server {

	# Get retry number
	local RETRY=$1

	# Deploy the NFS server
	echo -e "################# NFS SERVER DEPLOYMENT ##################"
	kadeploy3 -e $IMG_NODES -f $NFS_SRV --output-ok-nodes $NFS_SRV -k
	echo -e "##########################################################\n"

	# Quit if deployment failed
	if [ `cat $NFS_SRV | uniq | grep $CLUSTER | wc -l` -eq 0 ]; then
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
	tail -$(( `cat $NODES_OK | wc -l` / 2 )) $NODES_OK > $IDLE_NODES
}

function send_to_ctl {

	local SRC="$1"
	local DEST_DIR="$2"

	scp $SSH_OPTS -r $SRC $SSH_USER@$(cat $CTL_NODE):$DEST_DIR > /dev/null
}

function configure_infiniband_in_nodes {

	echo -en "Configuring Infiniband to all deployed nodes .."

	# Configure infiniband interface into CTL
	ssh $SSH_USER@$(cat $CTL_NODE) $SSH_OPTS 'bash -s' < ./config_infiniband $NFS_INFINIBAND_IF &
	
	# Configure infiniband interface into NFS SRV
	ssh $SSH_USER@$(cat $NFS_SRV) $SSH_OPTS 'bash -s' < ./config_infiniband $NFS_INFINIBAND_IF &

	# Configure infiniband interface into NODES
	for NODE in `cat $NODES_OK`; do
		ssh $SSH_USER@$NODE $SSH_OPTS 'bash -s' < ./config_infiniband $NFS_INFINIBAND_IF &
	done

	wait
	echo -e ". DONE\n"
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
	VM_BASE_IMG_DIR="/data/$(whoami)"
	VM_BASE_IMG_DIR+="_$SHARED_STORAGE"

	# Define backing img directory if necessary
	if [ -n "$BACKING_DIR" ]; then VM_BACKING_IMG_DIR="$VM_BASE_IMG_DIR/$BACKING_DIR"; fi

	# Give it more permissions
	chmod go+rwx $VM_BASE_IMG_DIR && chmod -R go+rw $VM_BASE_IMG_DIR
}

function mount_nfs_storage {

	# Use infiniband interface if declared in config file
	if [ -n "$NFS_INFINIBAND_IF" ]; then
		IP_NFS_SRV=$(host `cat $NFS_SRV`-$NFS_INFINIBAND_IF | awk '{print $4;}')
	else	
		IP_NFS_SRV=$(host `cat $NFS_SRV` | awk '{print $4;}')
	fi

	# Use ram for NFS share and start server (cluster edel => 24 Go max)
	ssh $SSH_USER@$(cat $NFS_SRV) $SSH_OPTS "mount -t tmpfs -o size=15G tmpfs /data/nfs && sync"
	ssh $SSH_USER@$(cat $NFS_SRV) $SSH_OPTS "/etc/init.d/rpcbind start >/dev/null 2>&1"
	ssh $SSH_USER@$(cat $NFS_SRV) $SSH_OPTS "/etc/init.d/nfs-kernel-server start >/dev/null 2>&1"
	
	for NODE in `cat $NODES_OK`; do
		ssh $SSH_USER@$NODE $SSH_OPTS "mkdir -p /data/nfs && mount $IP_NFS_SRV:/data/nfs /data/nfs && sync"
	done

	# Change the remote directory to the shared storage (base img)
	VM_BASE_IMG_DIR="/data/nfs"

	# Define backing img directory if necessary
	if [ -n "$BACKING_DIR" ]; then VM_BACKING_IMG_DIR="$VM_BASE_IMG_DIR/$BACKING_DIR"; fi
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
	echo -e ". DONE\n."
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

	# Send output directory to CTL node
	send_to_ctl $OUTPUT_DIR

	# Send some scripts
	send_to_ctl ./create_backing_img
	send_to_ctl ./migrate_vm
	
	# Send and start experimentation script to the CTL node
	echo -e "Send and execute experimentation script to the CTL :\n"
	send_to_ctl $SCRIPT
	ssh $SSH_USER@$(cat $CTL_NODE) $SSH_OPTS "~$SSH_USER/$SCRIPT"
}


## MAIN

create_output_files
deploy_ctl
if [ -n "$NFS_SRV" ]; then deploy_nfs_server ; fi
deploy_nodes
if [ -n "$SHARED_STORAGE" ]; then
	if [ -n "$NFS_SRV" ]; then
		if [ -n "$NFS_INFINIBAND_IF" ]; then configure_infiniband_in_nodes ; fi
		mount_nfs_storage
	else mount_shared_storage ; fi
fi
define_hosting_nodes
./send_img_to_nodes $HOSTING_NODES $VM_BASE_IMG $VM_BASE_IMG_DIR
if [ ! -n "$SHARED_STORAGE" ]; then duplicate_imgs_in_nodes $HOSTING_NODES ; fi
if [ -n "$VM_BACKING_IMG_DIR" ]; then create_backing_imgs_in_nodes $HOSTING_NODES ; fi
prepare_vms_in_nodes $HOSTING_NODES
start_vms_in_nodes $HOSTING_NODES
wait_for_vms_to_boot $VMS_IPS

# Start experiment
start_expe "decommissioning.sh $VM_BASE_IMG_DIR $VM_BACKING_IMG_DIR $(ip a | grep inet | grep eth0 | awk '{print $2;}' | cut -d'/' -f1)"

wait

echo -e "\nALL FINISHED !"

# Wait the end of walltime
while [ true ]; do sleep 60 ; done

