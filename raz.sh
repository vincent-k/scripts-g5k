#!/bin/bash

. ./config

echo -e "Starting down nodes :"
for NODE in `cat $NODES_OK`; do
	if [ `ipmitool -H $(host $(echo "$NODE" | cut -d'.' -f1)-bmc.$(echo "$NODE" | cut -d'.' -f2,3,4) | awk '{print $4;}') -I lan -U $BMC_USER -P $BMC_MDP chassis status | grep System | grep on | wc -l` -lt 1 ]; then
		./power_on $NODE $BMC_USER $BMC_MDP /tmp &
	fi
done

wait

sleep 10

echo -ne "Killing existing VMs.."
for NODE in `cat $NODES_OK`; do
	for VM in `virsh -c qemu+ssh://$NODE/system list --all | grep $VM_PREFIX | awk '{print $2;}'`; do
		virsh -c qemu+ssh://$NODE/system destroy $VM >/dev/null 2>&1
		virsh -c qemu+ssh://$NODE/system undefine $VM >/dev/null 2>&1
	done
done

rm -rf /data/nfs/$BACKING_DIR/*

echo ". DONE"
rm -rf ~/files
rm -rf ~/decommissioning_results
sync
