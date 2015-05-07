#!/bin/bash

# Get variables from config file
. ./config

if [ -n "$SHARED_STORAGE" ]; then
	SHARED_STORAGE="$1"
fi

if [ -n "$BACKING_DIR" ]; then
	VM_BACKING_IMG_DIR="$VM_BASE_IMG_DIR/$BACKING_DIR";
fi


function configure_infiniband_in_nodes {

	echo -en "Configuring Infiniband to all deployed nodes.."

	# Configure infiniband interface into CTL
	ssh $SSH_USER@$(cat $CTL_NODE) $SSH_OPTS 'bash -s' < ./config_infiniband $NFS_INFINIBAND_IF &
	
	# Configure infiniband interface into NFS SRV
	ssh $SSH_USER@$(cat $NFS_SRV_A) $SSH_OPTS 'bash -s' < ./config_infiniband $NFS_INFINIBAND_IF &
	ssh $SSH_USER@$(cat $NFS_SRV_B) $SSH_OPTS 'bash -s' < ./config_infiniband $NFS_INFINIBAND_IF &

	# Configure infiniband interface into NODES
	for NODE in `cat $NODES_OK`; do
		ssh $SSH_USER@$NODE $SSH_OPTS 'bash -s' < ./config_infiniband $NFS_INFINIBAND_IF &
	done

	wait
	echo -e ". DONE\n"
}

function configure_bmc_in_nodes {

	echo -en "Configuring BMC in all deployed nodes.."

	# Configure bmc into CTL
	ssh $SSH_USER@$(cat $CTL_NODE) $SSH_OPTS 'bash -s' < ./config_bmc $BMC_USER $BMC_MDP &
	
	# Configure bmc into NFS SRV
	ssh $SSH_USER@$(cat $NFS_SRV_A) $SSH_OPTS 'bash -s' < ./config_bmc $BMC_USER $BMC_MDP &
	ssh $SSH_USER@$(cat $NFS_SRV_B) $SSH_OPTS 'bash -s' < ./config_bmc $BMC_USER $BMC_MDP &

	# Configure bmc into NODES
	for NODE in `cat $NODES_OK`; do
		ssh $SSH_USER@$NODE $SSH_OPTS 'bash -s' < ./config_bmc $BMC_USER $BMC_MDP &
	done

	wait
	echo -e ". DONE\n"
}

function mount_nfs_storage {
	
	local NFS_SRV="$1"
	local NODES="$2"

	echo -e "################### MOUNT NFS STORAGE ####################"
	# Use infiniband interface if declared in config file
	IP_NFS_SRV=$(host `cat $NFS_SRV | cut -d'.' -f 1`-$NFS_INFINIBAND_IF.`cat $NFS_SRV | cut -d'.' -f 2,3,4` | awk '{print $4;}')
	echo -ne "Set up NFS using infiniband $NFS_INFINIBAND_IF interface.."

	# Use ram for backing imgs in NFS share and start server (cluster edel => 24 Go max)
	ssh $SSH_USER@$(cat $NFS_SRV) $SSH_OPTS "mkdir -p /data/nfs && sync"
	ssh $SSH_USER@$(cat $NFS_SRV) $SSH_OPTS "mount -t tmpfs -o size=15G tmpfs /data/nfs"
	ssh $SSH_USER@$(cat $NFS_SRV) $SSH_OPTS "/etc/init.d/rpcbind start >/dev/null 2>&1"
	ssh $SSH_USER@$(cat $NFS_SRV) $SSH_OPTS "/etc/init.d/nfs-kernel-server start >/dev/null 2>&1"
	echo -e ".\nNFS Server configured and started"

#	# Mount NFS share to the CTL
#	echo -ne "Mounting share in the CTL.."
#	ssh $SSH_USER@`cat $CTL_NODE` $SSH_OPTS "mkdir -p /data/nfs/{base_img,$BACKING_DIR} && sync"
#	ssh $SSH_USER@`cat $CTL_NODE` $SSH_OPTS "mount $IP_NFS_SRV:/data/nfs $VM_BACKING_IMG_DIR"
#	ssh $SSH_USER@`cat $CTL_NODE` $SSH_OPTS "mount $IP_NFS_SRV:/tmp $VM_BASE_IMG_DIR"
#	echo -e ". DONE"

	# Mount NFS share to all nodes and make the share persistent	
	echo -ne "Mounting share in all nodes.."
	for NODE in `cat $NODES`; do	
		ssh $SSH_USER@$NODE $SSH_OPTS "mkdir -p /data/nfs/{base_img,$BACKING_DIR} && sync"
		ssh $SSH_USER@$NODE $SSH_OPTS "mount $IP_NFS_SRV:/data/nfs $VM_BACKING_IMG_DIR"
		ssh $SSH_USER@$NODE $SSH_OPTS "mount $IP_NFS_SRV:/tmp $VM_BASE_IMG_DIR"
		ssh $SSH_USER@$NODE $SSH_OPTS "echo -e \"$IP_NFS_SRV:/data/nfs\t$VM_BACKING_IMG_DIR\tnfs\trsize=8192,wsize=8192,timeo=14,intr\" >> /etc/fstab"
		ssh $SSH_USER@$NODE $SSH_OPTS "echo -e \"$IP_NFS_SRV:/tmp\t$VM_BASE_IMG_DIR\tnfs\trsize=8192,wsize=8192,timeo=14,intr\" >> /etc/fstab"
	done
	wait
	echo -e ". DONE"
	echo -e "##########################################################\n"
}

function send_to_ctl {

	local SRC="$1"
	local DEST_DIR="$2"

	scp $SSH_OPTS -r $SRC $SSH_USER@$(cat $CTL_NODE):$DEST_DIR > /dev/null
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


## MAIN

NFS_SRV_A="$OUTPUT_DIR/nfs_srv_a"
NFS_SRV_B="$OUTPUT_DIR/nfs_srv_b"

configure_infiniband_in_nodes

NODES_A="$OUTPUT_DIR/nodes_a"
NODES_B="$OUTPUT_DIR/nodes_b"

VM_BASE_IMG_DIR="/data/nfs/base_img"
VM_BACKING_IMG_DIR="/data/nfs/backing"

mount_nfs_storage $NFS_SRV_A $NODES_A
mount_nfs_storage $NFS_SRV_B $NODES_B

if [ -n "$BMC_USER" -a -n "$BMC_MDP" ]; then configure_bmc_in_nodes ; fi

./send_img_to_nodes $HOSTING_NODES $VM_BASE_IMG $VM_BASE_IMG_DIR
create_backing_imgs_in_nodes $HOSTING_NODES
prepare_vms_in_nodes $HOSTING_NODES
start_vms_in_nodes $HOSTING_NODES
wait_for_vms_to_boot $VMS_IPS

