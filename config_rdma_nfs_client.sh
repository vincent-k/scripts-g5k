#!/bin/bash

# Load RDMA modules
modprobe ib_mthca
modprobe xprtrdma

# Remount NFS share through RDMA
SHARE=$(mount | grep /data/nfs | awk '{print $1;}')
umount /data/nfs
mount -o rdma,port=20049 $SHARE /data/nfs
