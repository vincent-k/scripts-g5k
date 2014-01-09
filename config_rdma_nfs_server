#!/bin/bash

# Load RDMA modules and restart
modprobe ib_mthca
modprobe svcrdma

# Restart NFS server
/etc/init.d/nfs-kernel-server restart > /dev/null

# Define NFS RDMA listening port
echo rdma 20049 > /proc/fs/nfsd/portlist
