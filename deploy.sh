#!/bin/bash

# Get variables from config file
. ./config

if [ -n "$SHARED_STORAGE" ]; then
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

	identify_nodes

	echo -e "################# LIST OF RESERVED NODES #################"
	echo -ne "CTL : "
	cat $CTL_NODE
	if [ -n "$NFS_SRV" ]; then
		echo -ne "NFS : "
		cat $NFS_SRV
	fi
	echo -e "NODES :"
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
	echo -n > "$NODES_OK"
	echo -n > "$VMS_IPS"
	echo -n > "$IPS_NAMES"
}

function identify_nodes {

	# Define the CTL node
	cat $OAR_NODE_FILE | uniq | grep $CTL_NODE_CLUSTER | head -1  > $CTL_NODE
	cat $OAR_NODE_FILE | uniq | grep $CLUSTER  > $NODES_LIST
	sed -i '/'$(cat $CTL_NODE)'/d' $NODES_LIST

	# Clean other files
	echo -n > "$HOSTING_NODES"
	echo -n > "$IDLE_NODES"

	# Define the hosting and idle nodes + NFS server
	if [ -n "$NFS_SRV" ]; then
		if [ -n "$SWITCH" ] && [ -a $SWITCH -eq 2 ]; then
			NB_RACK=4
			SRV_PER_RACK=18

			FILE_DEST="$HOSTING_NODES"
			FIRST=0
			for rack in $(seq $NB_RACK); do
				COUNT=0
				for node in `cat $NODES_LIST`; do
					num=$(echo -e "$node" | cut -d'-' -f 2 | cut -d'.' -f 1)
					if [ $(($num/$SRV_PER_RACK)) -eq $(($rack-1)) -a $(($num%$SRV_PER_RACK)) -gt 0 ] || [ $(($num/$SRV_PER_RACK)) -eq $rack -a $(($num%$SRV_PER_RACK)) -eq 0 ]; then
						COUNT=$(($COUNT+1))
						echo -e "$node" >> $FILE_DEST
					fi
				done
				if [ $COUNT -gt 0 ]; then
					echo -e "$COUNT nodes from rack $rack\n"
					if [ $FIRST -eq 0 ]; then
						FIRST=$COUNT
						FILE_DEST="$IDLE_NODES"
						continue
					else
						if [ $COUNT -gt $FIRST ]; then
							head -1 $IDLE_NODES > $NFS_SRV
							sed -i "/$(cat $NFS_SRV)/d" $IDLE_NODES
						else
							head -1 $HOSTING_NODES > $NFS_SRV
							sed -i "/$(cat $NFS_SRV)/d" $HOSTING_NODES
						fi
						sed -i "/$(cat $NFS_SRV)/d" $NODES_LIST
						break
					fi
				fi
			done
		else
			# Define the NFS Server
		        head -1 $NODES_LIST > $NFS_SRV
			sed -i "/$(cat $NFS_SRV)/d" $NODES_LIST

			# Define hosting and idle nodes
			head -$(( `cat $NODES_LIST | wc -l` / 2 )) $NODES_LIST > $HOSTING_NODES
			tail -$(( `cat $NODES_LIST | wc -l` / 2 )) $NODES_LIST > $IDLE_NODES
		fi
	else
		# Define hosting and idle nodes
		head -$(( `cat $NODES_LIST | wc -l` / 2 )) $NODES_LIST > $HOSTING_NODES
		tail -$(( `cat $NODES_LIST | wc -l` / 2 )) $NODES_LIST > $IDLE_NODES
	fi
}


function deploy_ctl {

	# Get retry number
	local RETRY=$1

	# Deploy the CTL node
	echo -e "################## CTL NODE DEPLOYMENT ###################"
	kadeploy3 -e $IMG_CTL -f $CTL_NODE --output-ok-nodes $CTL_NODE -k
	echo -e "##########################################################\n"

	# Retry or quit if deployment failed RETRY times
	if [ `cat $CTL_NODE | uniq | grep $CTL_NODE_CLUSTER | wc -l` -eq 0 ]; then
		echo -ne "\nERROR ! "
		if [ $RETRY -gt 0 ]; then
		
			echo -e "Retrying ($RETRY time(s)) :\n"
			deploy_ctl $(($RETRY - 1))
		else
			echo -e "Cancelling all jobs submissions.."
			# Cancel the job
			#oardel $OAR_JOB_ID

			# Cancel the storage reservation if exist
			#if [ -n "$SHARED_STORAGE" ]; then
			#	oardel $SHARED_STORAGE
			#fi
			exit
		fi
	fi
}

function deploy_nfs_server {

	# Get retry number
	local RETRY=$1

	# Deploy the NFS server
	echo -e "################# NFS SERVER DEPLOYMENT ##################"
	kadeploy3 -e $IMG_NODES -f $NFS_SRV --output-ok-nodes $NFS_SRV -k
	echo -e "##########################################################\n"

	# Retry or quit if deployment failed RETRY times
	if [ `cat $NFS_SRV | uniq | grep $CLUSTER | wc -l` -eq 0 ]; then
		echo -ne "\nERROR ! "
		if [ $RETRY -gt 0 ]; then
		
			echo -e "Retrying ($RETRY time(s)) :\n"
			deploy_nfs_server $(($RETRY - 1))
		else
			echo -e "Cancelling all jobs submissions.."
			# Cancel the job
			#oardel $OAR_JOB_ID

			# Cancel the storage reservation if exist
			if [ -n "$SHARED_STORAGE" ]; then
				oardel $SHARED_STORAGE
			fi
			exit
		fi
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

	echo -ne "Waiting for nodes networking configuration.." && sleep 60 && echo -e "\n"
}

function send_to_ctl {

	local SRC="$1"
	local DEST_DIR="$2"

	scp $SSH_OPTS -r $SRC $SSH_USER@$(cat $CTL_NODE):$DEST_DIR > /dev/null
}

function configure_infiniband_in_nodes {

	echo -en "Configuring Infiniband to all deployed nodes.."

	# Configure infiniband interface into CTL
	ssh $SSH_USER@$(cat $CTL_NODE) $SSH_OPTS 'bash -s' < ./config_infiniband $NFS_INFINIBAND_IF &
	
	# Configure infiniband interface into NFS SRV
	if [ -n "$NFS_SRV" ]; then
		ssh $SSH_USER@$(cat $NFS_SRV) $SSH_OPTS 'bash -s' < ./config_infiniband $NFS_INFINIBAND_IF &
	fi

	# Configure infiniband interface into NODES
	for NODE in `cat $NODES_OK`; do
		ssh $SSH_USER@$NODE $SSH_OPTS 'bash -s' < ./config_infiniband $NFS_INFINIBAND_IF &
	done

	wait
	echo -e ". DONE\n"
}

function configure_bmc_in_nodes {

	echo -en "Configuring BMC in all deployed nodes.."

	# Configure infiniband interface into CTL
	ssh $SSH_USER@$(cat $CTL_NODE) $SSH_OPTS 'bash -s' < ./config_bmc $BMC_USER $BMC_MDP &
	
	# Configure infiniband interface into NFS SRV
	if [ -n "$NFS_SRV" ]; then
		ssh $SSH_USER@$(cat $NFS_SRV) $SSH_OPTS 'bash -s' < ./config_bmc $BMC_USER $BMC_MDP &
	fi

	# Configure infiniband interface into NODES
	for NODE in `cat $NODES_OK`; do
		ssh $SSH_USER@$NODE $SSH_OPTS 'bash -s' < ./config_bmc $BMC_USER $BMC_MDP &
	done

	wait
	echo -e ". DONE\n"
}

function mount_shared_storage {

	# Mount storage in all nodes
	echo -e "################# MOUNT SHARED STORAGE ###################"
	STORAGE_MOUNT=`storage5k -a mount -j $OAR_JOB_ID 2>&1`
	echo -e "$STORAGE_MOUNT"
	echo -e "##########################################################\n"
	if [ `echo -e "$STORAGE_MOUNT" | grep Success | wc -l` -eq 0 ]; then
		echo -e "\nCANCELING !"
		oardel $SHARED_STORAGE
		#oardel $OAR_JOB_ID
		exit
	fi

	# Change the remote directory to the shared storage (base img)
	VM_BASE_IMG_DIR="/data/$(whoami)_$SHARED_STORAGE"

	# Define backing img directory if necessary
	if [ -n "$BACKING_DIR" ]; then VM_BACKING_IMG_DIR="$VM_BASE_IMG_DIR/$BACKING_DIR"; fi

	# Give it more permissions
	chmod go+rwx $VM_BASE_IMG_DIR && chmod -R go+rw $VM_BASE_IMG_DIR
}

function mount_nfs_storage {

	# Change the remote directory to the shared storage (base img)
	VM_BASE_IMG_DIR="/data/nfs/base_img"

	# Define backing img directory if necessary
	if [ -n "$BACKING_DIR" ]; then
		VM_BACKING_IMG_DIR="/data/nfs/$BACKING_DIR"
	fi

	echo -e "################### MOUNT NFS STORAGE ####################"
	# Use infiniband interface if declared in config file
	if [ -n "$NFS_INFINIBAND_IF" ]; then
		IP_NFS_SRV=$(host `cat $NFS_SRV | cut -d'.' -f 1`-$NFS_INFINIBAND_IF.`cat $NFS_SRV | cut -d'.' -f 2,3,4` | awk '{print $4;}')
		echo -ne "Set up NFS using infiniband $NFS_INFINIBAND_IF interface.."
	else	
		IP_NFS_SRV=$(host `cat $NFS_SRV` | awk '{print $4;}')
		echo -ne "Set up NFS using standard eth0 interface.."
	fi

	# Use ram for vm_base in NFS share and start server (cluster edel => 24 Go max)
	ssh $SSH_USER@$(cat $NFS_SRV) $SSH_OPTS "mkdir -p /data/nfs && sync"
	ssh $SSH_USER@$(cat $NFS_SRV) $SSH_OPTS "mount -t tmpfs -o size=14G tmpfs /data/nfs"
	#ssh $SSH_USER@$(cat $NFS_SRV) $SSH_OPTS "mkdir -p /data/nfs/$BACKING_DIR && sync"
	ssh $SSH_USER@$(cat $NFS_SRV) $SSH_OPTS "/etc/init.d/rpcbind start >/dev/null 2>&1"
	ssh $SSH_USER@$(cat $NFS_SRV) $SSH_OPTS "/etc/init.d/nfs-kernel-server start >/dev/null 2>&1"
	echo -e ".\nNFS Server configured and started"

	# Mount NFS share to the CTL
	echo -ne "Mounting share in the CTL.."
	ssh $SSH_USER@`cat $CTL_NODE` $SSH_OPTS "mkdir -p /data/nfs/{base_img,$BACKING_DIR} && sync"
	#ssh $SSH_USER@`cat $CTL_NODE` $SSH_OPTS "mkdir -p /data/nfs && sync"
	ssh $SSH_USER@`cat $CTL_NODE` $SSH_OPTS "mount $IP_NFS_SRV:/data/nfs $VM_BACKING_IMG_DIR"
	#ssh $SSH_USER@`cat $CTL_NODE` $SSH_OPTS "mount $IP_NFS_SRV:/data/nfs /data/nfs"
	ssh $SSH_USER@`cat $CTL_NODE` $SSH_OPTS "mount $IP_NFS_SRV:/tmp $VM_BASE_IMG_DIR"
	echo -e ". DONE"

	# Mount NFS share to all nodes and make the share persistent	
	echo -ne "Mounting share in all nodes.."
	for NODE in `cat $NODES_OK`; do
	
		ssh $SSH_USER@$NODE $SSH_OPTS "mkdir -p /data/nfs/{base_img,$BACKING_DIR} && sync"
		#ssh $SSH_USER@$NODE $SSH_OPTS "mkdir -p /data/nfs && sync"
		ssh $SSH_USER@$NODE $SSH_OPTS "mount $IP_NFS_SRV:/data/nfs $VM_BACKING_IMG_DIR"
		#ssh $SSH_USER@$NODE $SSH_OPTS "mount $IP_NFS_SRV:/data/nfs /data/nfs"
		ssh $SSH_USER@$NODE $SSH_OPTS "mount $IP_NFS_SRV:/tmp $VM_BASE_IMG_DIR"
		ssh $SSH_USER@$NODE $SSH_OPTS "echo -e \"$IP_NFS_SRV:/data/nfs\t$VM_BACKING_IMG_DIR\tnfs\trsize=8192,wsize=8192,timeo=14,intr\" >> /etc/fstab"
		#ssh $SSH_USER@$NODE $SSH_OPTS "echo -e \"$IP_NFS_SRV:/data/nfs\t/data/nfs\tnfs\trsize=8192,wsize=8192,timeo=14,intr\" >> /etc/fstab"
		ssh $SSH_USER@$NODE $SSH_OPTS "echo -e \"$IP_NFS_SRV:/tmp\t$VM_BASE_IMG_DIR\tnfs\trsize=8192,wsize=8192,timeo=14,intr\" >> /etc/fstab"
	done
	wait
	echo -e ". DONE"
	echo -e "##########################################################\n"
}


## MAIN

#create_output_files
#deploy_ctl 3
#if [ -n "$NFS_SRV" ]; then deploy_nfs_server 3 ; fi
#deploy_nodes
if [ -n "$SHARED_STORAGE" ]; then
	if [ -n "$NFS_SRV" ]; then
		if [ -n "$NFS_INFINIBAND_IF" ]; then configure_infiniband_in_nodes ; fi
		mount_nfs_storage
	else mount_shared_storage ; fi
fi
if [ -n "$BMC_USER" -a -n "$BMC_MDP" ]; then configure_bmc_in_nodes ; fi

# Prepare nodes
#./prepare.sh $VM_BASE_IMG_DIR $VM_BACKING_IMG_DIR

echo -e "\nALL FINISHED !"

# Wait the end of walltime
while [ true ]; do sleep 60 ; done

