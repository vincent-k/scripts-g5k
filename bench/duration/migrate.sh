#!/bin/bash

VM_NAME="$1"
NODE_SRC="$2"
NODE_DEST="$3"
BANDWIDTH="$4"
VIRSH_OPTS="$5"

SSH_USER="root"
SSH_OPTS=' -o StrictHostKeyChecking=no -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o LogLevel=quiet '

# Add custom vars
VM_BASE_IMG='/home/vinkherbache/images/ubuntu_desktop_10G.img'
VM_BASE_IMG_NAME=$(basename $VM_BASE_IMG)
VM_BASE_IMG_DIR="/data/nfs/base_img"
VM_BACKING_IMG_DIR="/data/nfs/backing"

START=$(date +%s)
echo -e "Start:\tMigrate $VM_NAME from $NODE_SRC to $NODE_DEST at $BANDWIDTH Mbps"

# Convert Mb/s to MiB/s and round
BANDWIDTH=`bc <<< "$BANDWIDTH/8.388608"`

if [ -n "$VM_BACKING_IMG_DIR" ]; then
        SRC_IMG="$VM_BASE_IMG_DIR/$VM_BASE_IMG_NAME"
else
        SRC_IMG="$VM_BASE_IMG_DIR/$VM_NAME.${VM_BASE_IMG##*.}"
fi

# Create base img / backing img to the destination node
if [ -n "$VM_BACKING_IMG_DIR" ]; then
        # If backing img is not on shared storage
        if [ "$VM_BACKING_IMG_DIR" == "/tmp" ]; then
                # Create a qcow2 backing img file if it doesn't already exist
                BACKING_IMG="$VM_BACKING_IMG_DIR/$VM_NAME.qcow2"
                if ( ssh $SSH_USER@$NODE_DEST $SSH_OPTS ''[ -e $BACKING_IMG ]'' ); then
                        ssh $SSH_USER@$NODE_DEST $SSH_OPTS "rm -rf $BACKING_IMG 2>/dev/null"
                fi
                ssh $SSH_USER@$NODE_DEST $SSH_OPTS "qemu-img create -f qcow2 -o backing_file=$SRC_IMG,backing_fmt=raw $BACKING_IMG >/dev/null"

        fi
else
        # If base img is not on shared storage
        if [ "$VM_BASE_IMG_DIR" == "/tmp" ]; then
                # Create a new empty img with the same size as the src img
                IMG_SIZE=$(ssh $SSH_USER@$NODE_SRC $SSH_OPTS "du -b $SRC_IMG | cut -f1")
                ssh $SSH_USER@$NODE_DEST $SSH_OPTS "dd if=/dev/zero of=$SRC_IMG bs=1 count=0 seek=$IMG_SIZE >/dev/null"
        fi
fi

# Set bandwidth
virsh --connect qemu+tcp://$NODE_SRC/system migrate-setspeed $VM_NAME $BANDWIDTH

# Do the migration
virsh --connect qemu+tcp://$NODE_SRC/system migrate $VIRSH_OPTS $VM_NAME qemu+tcp://$NODE_DEST/system

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

END=$(date +%s)
echo -e "End:\tMigrate $VM_NAME from $NODE_SRC to $NODE_DEST at $BANDWIDTH MiB/s\t(time=$(($END - $START)))s"
