#!/bin/bash

# Get variables from config file
. ./config

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
		SUBMISSION=$(oarsub -l $NETWORK=$NETWORK_NB+{"cluster='$CTL_NODE_CLUSTER'"}nodes=1+{"cluster='$CLUSTER'"}nodes=$NB_NODES,walltime=$TIME -r "$RESERVATION" -t deploy "$(pwd)/$DEPLOY_SCRIPT \"$SHARED_STORAGE\"" 2>&1)
	else
		SUBMISSION=$(oarsub -l $NETWORK=$NETWORK_NB+{"cluster='$CTL_NODE_CLUSTER'"}nodes=1+{"cluster='$CLUSTER'"}nodes=$NB_NODES,walltime=$TIME -t deploy "$(pwd)/$DEPLOY_SCRIPT \"$SHARED_STORAGE\"" 2>&1)
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


## MAIN

./clean.sh
clear
if [ -n "$SHARED_STORAGE" -a ! -n "$NFS_SRV" ]; then
	reserve_storage
fi
deploy_nodes
