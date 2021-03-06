#!/usr/bin/env bash

# **volumes.sh**

# Test cinder volumes with the ``cinder`` command from ``python-cinderclient``

echo "*********************************************************************"
echo "Begin DevStack Exercise: $0"
echo "*********************************************************************"

# This script exits on an error so that errors don't compound and you see
# only the first error that occurred.
set -o errexit

# Print the commands being run so that we can see the command that triggers
# an error.  It is also useful for following as the install occurs.
set -o xtrace


# Settings
# ========

# Keep track of the current directory
EXERCISE_DIR=$(cd $(dirname "$0") && pwd)
TOP_DIR=$(cd $EXERCISE_DIR/..; pwd)

# Import common functions
source $TOP_DIR/functions

# Import configuration
source $TOP_DIR/openrc

# Import project functions
source $TOP_DIR/lib/cinder
source $TOP_DIR/lib/neutron
source $TOP_DIR/lib/neutron-legacy

# Import exercise configuration
source $TOP_DIR/exerciserc

# If cinder is not enabled we exit with exitcode 55 which mean
# exercise is skipped.
is_service_enabled cinder || exit 55

# Ironic does not currently support volume attachment.
[ "$VIRT_DRIVER" == "ironic" ] && exit 55

# Instance type to create
DEFAULT_INSTANCE_TYPE=${DEFAULT_INSTANCE_TYPE:-m1.tiny}

# Boot this image, use first AMI image if unset
DEFAULT_IMAGE_NAME=${DEFAULT_IMAGE_NAME:-ami}

# Security group name
SECGROUP=${SECGROUP:-vol_secgroup}

# Instance and volume names
VM_NAME=${VM_NAME:-ex-vol-inst}
VOL_NAME="ex-vol-$(openssl rand -hex 4)"


# Launching a server
# ==================

# List servers for tenant:
openstack server list

# Images
# ------

# List the images available
openstack image list

# Grab the id of the image to launch
IMAGE=$(openstack image list | egrep " $DEFAULT_IMAGE_NAME " | get_field 1)
die_if_not_set $LINENO IMAGE "Failure getting image $DEFAULT_IMAGE_NAME"

# Security Groups
# ---------------

# List security groups
openstack security group list

if is_service_enabled n-cell; then
    # Cells does not support security groups, so force the use of "default"
    SECGROUP="default"
    echo "Using the default security group because of Cells."
else
    # Create a secgroup
    if ! openstack security group list | grep -q $SECGROUP; then
        openstack security group create $SECGROUP --description "$SECGROUP description"
        if ! timeout $ASSOCIATE_TIMEOUT sh -c "while ! openstack security group list | grep -q $SECGROUP; do sleep 1; done"; then
            echo "Security group not created"
            exit 1
        fi
    fi
fi

# Configure Security Group Rules
if ! openstack security group rule list $SECGROUP | grep -q icmp; then
    openstack security group rule create $SECGROUP --proto icmp 
fi
if ! openstack security group rule list $SECGROUP | grep -q " tcp .* 22 "; then
    openstack security group rule create $SECGROUP --proto tcp --dst-port 22 
fi

# List secgroup rules
openstack security group rule list $SECGROUP

# Set up instance
# ---------------

# List flavors
openstack flavor list

# Select a flavor
INSTANCE_TYPE=$(openstack flavor list | grep $DEFAULT_INSTANCE_TYPE | get_field 1)
if [[ -z "$INSTANCE_TYPE" ]]; then
    # grab the first flavor in the list to launch if default doesn't exist
    INSTANCE_TYPE=$(openstack flavor list | head -n 4 | tail -n 1 | get_field 1)
    die_if_not_set $LINENO INSTANCE_TYPE "Failure retrieving INSTANCE_TYPE"
fi

# Clean-up from previous runs
openstack server delete $VM_NAME || true
if ! timeout $ACTIVE_TIMEOUT sh -c "while openstack server show $VM_NAME; do sleep 1; done"; then
    die $LINENO "server didn't terminate!"
fi

# Boot instance
# -------------

VM_UUID=$(openstack server create $VM_NAME --flavor $INSTANCE_TYPE --image $IMAGE --security-group=$SECGROUP | grep ' id ' | get_field 2)
die_if_not_set $LINENO VM_UUID "Failure launching $VM_NAME"

# Check that the status is active within ACTIVE_TIMEOUT seconds
if ! timeout $ACTIVE_TIMEOUT sh -c "while ! openstack server show $VM_UUID | grep status | grep -q ACTIVE; do sleep 1; done"; then
    die $LINENO "server didn't become active!"
fi

# Get the instance IP
IP=$(get_instance_ip $VM_UUID $PRIVATE_NETWORK_NAME)

die_if_not_set $LINENO IP "Failure retrieving IP address"

# Private IPs can be pinged in single node deployments
ping_check $IP $BOOT_TIMEOUT "$PRIVATE_NETWORK_NAME"

# Volumes
# -------

# Verify it doesn't exist
if [[ -n $(openstack volume list | grep $VOL_NAME | head -1 | get_field 2) ]]; then
    die $LINENO "Volume $VOL_NAME already exists"
fi

# Create a new volume
start_time=$(date +%s)
openstack volume create $VOL_NAME --description "test volume: $VOL_NAME" --size $DEFAULT_VOLUME_SIZE || \
    die $LINENO "Failure creating volume $VOL_NAME"
if ! timeout $ACTIVE_TIMEOUT sh -c "while ! openstack volume list | grep $VOL_NAME | grep available; do sleep 1; done"; then
    die $LINENO "Volume $VOL_NAME not created"
fi
end_time=$(date +%s)
echo "Completed cinder create in $((end_time - start_time)) seconds"

# Get volume ID
VOL_ID=$(openstack volume list | grep $VOL_NAME | head -1 | get_field 1)
die_if_not_set $LINENO VOL_ID "Failure retrieving volume ID for $VOL_NAME"

# Attach to server
DEVICE=/dev/vdb
start_time=$(date +%s)
openstack server add volume $VM_UUID $VOL_ID --device $DEVICE || \
    die $LINENO "Failure attaching volume $VOL_NAME to $VM_NAME"
if ! timeout $ACTIVE_TIMEOUT sh -c "while ! openstack volume list | grep $VOL_NAME | grep in-use; do sleep 1; done"; then
    die $LINENO "Volume $VOL_NAME not attached to $VM_NAME"
fi
end_time=$(date +%s)
echo "Completed volume-attach in $((end_time - start_time)) seconds"

VOL_ATTACH=$(openstack volume list | grep $VOL_NAME | head -1 | get_field -1)
die_if_not_set $LINENO VOL_ATTACH "Failure retrieving $VOL_NAME status"
if [[ "$VOL_ATTACH" != $VM_UUID ]]; then
    die $LINENO "Volume not attached to correct instance"
fi

# Clean up
# --------

# Detach volume
start_time=$(date +%s)
openstack remove volume $VM_UUID $VOL_ID || die $LINENO "Failure detaching volume $VOL_NAME from $VM_NAME"
if ! timeout $ACTIVE_TIMEOUT sh -c "while ! openstack volume list | grep $VOL_NAME | grep available; do sleep 1; done"; then
    die $LINENO "Volume $VOL_NAME not detached from $VM_NAME"
fi
end_time=$(date +%s)
echo "Completed volume detach in $((end_time - start_time)) seconds"

# Delete volume
start_time=$(date +%s)
openstack volume delete $VOL_ID || die $LINENO "Failure deleting volume $VOL_NAME"
if ! timeout $ACTIVE_TIMEOUT sh -c "while openstack volume list | grep $VOL_NAME; do sleep 1; done"; then
    die $LINENO "Volume $VOL_NAME not deleted"
fi
end_time=$(date +%s)
echo "Completed cinder delete in $((end_time - start_time)) seconds"

# Delete instance
nova delete $VM_UUID || die $LINENO "Failure deleting instance $VM_NAME"
if ! timeout $TERMINATE_TIMEOUT sh -c "while openstack server list | grep -q $VM_UUID; do sleep 1; done"; then
    die $LINENO "Server $VM_NAME not deleted"
fi

if [[ $SECGROUP = "default" ]] ; then
    echo "Skipping deleting default security group"
else
    # Delete secgroup
    openstack security group delete $SECGROUP || die $LINENO "Failure deleting security group $SECGROUP"
fi

set +o xtrace
echo "*********************************************************************"
echo "SUCCESS: End DevStack Exercise: $0"
echo "*********************************************************************"
