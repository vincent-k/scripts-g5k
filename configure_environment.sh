#!/bin/bash

# Get variables from config file
. ./config

# Configure physical environment
. ./config_physical_env

# Configure virtual environment
. ./config_virtual_env $VM_BASE_IMG_DIR $VM_BACKING_IMG_DIR

echo -e "\nDONE !"

