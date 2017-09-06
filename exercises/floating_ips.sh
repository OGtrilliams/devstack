#!/usr/bin/env bash

# **floating_ips.sh** - using the cloud can be fun

# Test instance connectivity with the ``nova`` command from ``python-novaclient``

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
source $TOP_DIR/lib/neutron
source $TOP_DIR/lib/neutron-legacy

# Import exercise configuration
source $TOP_DIR/exerciserc

# If nova api is not enabled we exit with exitcode 55 so that
# the exercise is skipped
is_service_enabled n-api || exit 55

# Instance type to create
DEFAULT_INSTANCE_TYPE=${DEFAULT_INSTANCE_TYPE:-m1.tiny}

# Boot this image, use first AMI image if unset
DEFAULT_IMAGE_NAME=${DEFAULT_IMAGE_NAME:-ami}

# Security group name
SECGROUP=${SECGROUP:-test_secgroup}

# Default floating IP pool name
DEFAULT_FLOATING_POOL=${DEFAULT_FLOATING_POOL:-public}

# Additional floating IP pool and range
TEST_FLOATING_POOL=${TEST_FLOATING_POOL:-test}

# Instance name
VM_NAME="ex-float"

# Cells does not support floating ips API calls
is_service_enabled n-cell && exit 55

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

# Create a secgroup
if ! openstack security group list | grep -q $SECGROUP; then
    openstack security group create $SECGROUP "$SECGROUP description"
    if ! timeout $ASSOCIATE_TIMEOUT sh -c "while ! openstack  security group list | grep -q $SECGROUP; do sleep 1; done"; then
        die $LINENO "Security group not created"
    fi
fi

# Configure Security Group Rules
if ! openstack security group list $SECGROUP | grep -q icmp; then
    openstack security group rule create --proto icmp $SECGROUP
fi
if ! openstack security group rule list $SECGROUP | grep -q " tcp .* 22 "; then
    openstack security group rule create --proto tcp --dst-port 22 $SECGROUP
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
    exit 1
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

# Floating IPs
# ------------

# Allocate a floating IP from the default pool
FLOATING_IP=$(openstack floating ip create $DEFAULT_FLOATING_POOL | grep $DEFAULT_FLOATING_POOL | get_field 1)
die_if_not_set $LINENO FLOATING_IP "Failure creating floating IP from pool $DEFAULT_FLOATING_POOL"

# List floating addresses
if ! timeout $ASSOCIATE_TIMEOUT sh -c "while ! openstack floating ip list | grep -q $FLOATING_IP; do sleep 1; done"; then
    die $LINENO "Floating IP not allocated"
fi

# Add floating IP to our server
openstack add floating ip $VM_UUID $FLOATING_IP || \
    die $LINENO "Failure adding floating IP $FLOATING_IP to $VM_NAME"

# Test we can ping our floating IP within ASSOCIATE_TIMEOUT seconds
ping_check $FLOATING_IP $ASSOCIATE_TIMEOUT "$PUBLIC_NETWORK_NAME"

if ! is_service_enabled neutron; then
    # Allocate an IP from second floating pool
    TEST_FLOATING_IP=$(openstack floating ip create $TEST_FLOATING_POOL | grep $TEST_FLOATING_POOL | get_field 1)
    die_if_not_set $LINENO TEST_FLOATING_IP "Failure creating floating IP in $TEST_FLOATING_POOL"

    # list floating addresses
    if ! timeout $ASSOCIATE_TIMEOUT sh -c "while ! openstack floating ip list | grep $TEST_FLOATING_POOL | grep -q $TEST_FLOATING_IP; do sleep 1; done"; then
        die $LINENO "Floating IP not allocated"
    fi
fi

# Dis-allow icmp traffic (ping)
openstack security group rule delete $(openstack security group rule list $SECGROUP | grep icmp | awk {'print $2} || \
    die $LINENO "Failure deleting security group rule from $SECGROUP"

if ! timeout $ASSOCIATE_TIMEOUT sh -c "while openstack security group rule list $SECGROUP | grep -q icmp; do sleep 1; done"; then
    die $LINENO "Security group rule not deleted from $SECGROUP"
fi

# FIXME (anthony): make xs support security groups
if [ "$VIRT_DRIVER" != "ironic" -a "$VIRT_DRIVER" != "xenserver" -a "$VIRT_DRIVER" != "openvz" ]; then
    # Test we can aren't able to ping our floating ip within ASSOCIATE_TIMEOUT seconds
    ping_check $FLOATING_IP $ASSOCIATE_TIMEOUT "$PUBLIC_NETWORK_NAME" Fail
fi

# Clean up
# --------

if ! is_service_enabled neutron; then
    # Delete second floating IP
    openstack floating ip delete $TEST_FLOATING_IP || \
        die $LINENO "Failure deleting floating IP $TEST_FLOATING_IP"
fi

# Delete the floating ip
openstack floating ip delete $FLOATING_IP || \
    die $LINENO "Failure deleting floating IP $FLOATING_IP"

# Delete instance
openstack server delete $VM_UUID || die $LINENO "Failure deleting instance $VM_NAME"
# Wait for termination
if ! timeout $TERMINATE_TIMEOUT sh -c "while openstack server list | grep -q $VM_UUID; do sleep 1; done"; then
    die $LINENO "Server $VM_NAME not deleted"
fi

# Delete secgroup
openstack security group delete $SECGROUP || \
    die $LINENO "Failure deleting security group $SECGROUP"

set +o xtrace
echo "*********************************************************************"
echo "SUCCESS: End DevStack Exercise: $0"
echo "*********************************************************************"
