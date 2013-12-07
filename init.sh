#!/bin/bash

######################################################
TIME='3:00'
#RESERVATION='2013-12-06 12:34:00'
######################################################

###################### CTL NODE ######################
CTL_NODE_CLUSTER='helios'
CTL_NODE_IMG='debian-sid-qemu'
####################### NODES ########################
NB_NODES=10
CLUSTER='suno'
IMG_NODES='debian-sid-qemu'
######################## VMS #########################
VM_VCPU=1
VM_MEM=512
#VM_IMG='/home/vinkherbache/images/wheezy-x64-base.qcow2'
VM_IMG='/home/vinkherbache/images/debian.img'
NETWORK='slash_22=1'
NB_VMS_PER_NODE=16
SHARED_STORAGE=10 # 1 chunk => 10Go
######################################################

######################################################
DEPLOY_SCRIPT='deploy.sh'
######################################################



function reserve_storage {

	# Submit the storage reservation
	echo -e "#################### STORAGE RESERVATION #################"
	if [ -n "$RESERVATION" ]; then
		STORAGE_RESERVATION=$(storage5k -a add -l chunks=$SHARED_STORAGE,walltime=$TIME -r "\"$RESERVATION\"" 2>&1)
	else	
		STORAGE_RESERVATION=$(storage5k -a add -l chunks=$SHARED_STORAGE,walltime=$TIME 2>&1)
	fi
	echo -e "$STORAGE_RESERVATION"
	echo -e "##########################################################\n"

	sleep 5

	# Quit if reservation failed
	if [ `echo -e "$STORAGE_RESERVATION" | grep OK | wc -l` -eq 0 ]; then
		echo -e "STORAGE RESERVATION ERROR"
		exit
	else
		SHARED_STORAGE=$(echo "$STORAGE_RESERVATION" | grep OAR_JOB_ID | cut -d "=" -f 2)
	fi
}

function deploy_nodes {

	# Nodes reservation
	echo -e "Nodes reservation .."
	if [ -n "$RESERVATION" ]; then
		SUBMISSION=$(oarsub -l $NETWORK+{"cluster='$CTL_NODE_CLUSTER'"}nodes=1+{"cluster='$CLUSTER'"}nodes=$NB_NODES,walltime=$TIME -r "$RESERVATION" -t deploy "$(pwd)/$DEPLOY_SCRIPT $CTL_NODE_CLUSTER $CLUSTER $NB_VMS_PER_NODE $CTL_NODE_IMG $IMG_NODES $VM_IMG $VM_VCPU $VM_MEM $SHARED_STORAGE" 2>&1)
	else
		SUBMISSION=$(oarsub -l $NETWORK+{"cluster='$CTL_NODE_CLUSTER'"}nodes=1+{"cluster='$CLUSTER'"}nodes=$NB_NODES,walltime=$TIME -t deploy "$(pwd)/$DEPLOY_SCRIPT $CTL_NODE_CLUSTER $CLUSTER $NB_VMS_PER_NODE $CTL_NODE_IMG $IMG_NODES $VM_IMG $VM_VCPU $VM_MEM $SHARED_STORAGE" 2>&1)
	fi

	# Get the JOB_ID of reservation
	JOB_ID=$(echo -e "$SUBMISSION" | grep OAR_JOB_ID | cut -d "=" -f 2)

	# Exit if resources are not available
	if [ $JOB_ID -eq -5 ]; then
		echo -e "NODES RESERVATION ERROR :\n\n$SUBMISSION"
		exit
	fi

	# Follow the deployment process
	show_deployment
}

function show_deployment {

	# Show job status if we are waiting
	OARSTAT="JOB_ID = $JOB_ID"
	while [ ! -f ./OAR.$JOB_ID.stdout ]; do
		clear
		echo -e "#################### JOB INFORMATIONS ####################"
		echo -e "$OARSTAT"
		echo -e "##########################################################\n"
		OARSTAT=$(oarstat -f -j $JOB_ID)
		sleep 2
	done

	# Follow the std output from the start
	tail -c +1 -f ./OAR.$JOB_ID.stdout
}


clear
if [ -n "$SHARED_STORAGE" ]; then
	reserve_storage
fi
deploy_nodes
