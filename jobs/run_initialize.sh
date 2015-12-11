#!/bin/bash
#
# Copyright 2013 Cloudbase Solutions Srl
# All Rights Reserved.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.
#

# Loading OpenStack credentials
source /home/jenkins-slave/tools/keystonerc_admin

# Loading all the needed functions
source /usr/local/src/oswin-ci/jobs/library.sh

FLOATING_IP=$(nova floating-ip-create public | awk '{print $2}'|sed '/^$/d' | tail -n 1) || echo `date -u +%H:%M:%S` "Failed to alocate floating IP"
if [ -z "$FLOATING_IP" ]
then
   exit 1
fi
echo FLOATING_IP=$FLOATING_IP >> /home/jenkins-slave/runs/devstack_params.$ZUUL_UUID.txt

NAME="osw-dvs-$ZUUL_CHANGE-$ZUUL_PATCHSET"
if [[ ! -z $IS_DEBUG_JOB ]] && [[ $IS_DEBUG_JOB = "yes" ]]; then
	NAME="$NAME-dbg"
fi
export NAME=$NAME

echo NAME=$NAME >> /home/jenkins-slave/runs/devstack_params.$ZUUL_UUID.txt

NET_ID=$(nova net-list | grep private| awk '{print $2}')
echo NET_ID=$NET_ID >> /home/jenkins-slave/runs/devstack_params.$ZUUL_UUID.txt

echo FLOATING_IP=$FLOATING_IP
echo NAME=$NAME
echo NET_ID=$NET_ID

echo "Deploying devstack $NAME"

devstack_image="devstack-71v2"

echo "Image used is: $devstack_image"
echo "Deploying devstack $NAME"

# Boot the new 10G of RAM flavor
VMID=$(nova boot --availability-zone hyper-v --flavor nova.devstack --image $devstack_image --key-name default --security-groups devstack --nic net-id="$NET_ID" "$NAME" --poll | awk '{if (NR == 21) {print $4}}')
export VMID=$VMID
echo VMID=$VMID >>  /home/jenkins-slave/runs/devstack_params.$ZUUL_UUID.txt
echo VMID=$VMID

if [ $? -ne 0 ]
then
    echo "Failed to create devstack VM: $VMID"
    nova show "$VMID"
    exit 1
fi

echo "Showing details of the new created instance: $VMID"
nova show "$VMID"

echo "Fetching devstack VM fixed IP address"
FIXED_IP=$(nova show "$VMID" | grep "private network" | awk '{print $5}')
export FIXED_IP="${FIXED_IP//,}"

COUNT=1
while [ -z "$FIXED_IP" ]
do
    if [ $COUNT -lt 10 ]
    then
        sleep 15
        FIXED_IP=$(nova show "$VMID" | grep "private network" | awk '{print $5}')
        export FIXED_IP="${FIXED_IP//,}"
        COUNT=$(($COUNT + 1))
    else
        echo "Failed to get fixed IP using nova show $VMID"
        echo "Trying to get the IP from console-log and port-list"
        FIXED_IP1=`nova console-log $VMID | grep "ci-info" | grep "eth0" | grep "True" | awk '{print $7}'`
        echo "From console-log we got IP: $FIXED_IP1"
        FIXED_IP2=`neutron port-list -D -c device_id -c fixed_ips | grep $VMID | awk '{print $7}' | tr -d \" | tr -d }`
        echo "From neutron port-list we got IP: $FIXED_IP2"
        if [[ -z "$FIXED_IP1" || -z "$FIXED_IP2" ||  "$FIXED_IP1" != "$FIXED_IP2" ]]
        then
            echo "Failed to get fixed IP"
            echo "nova show output:"
            nova show "$VMID"
            echo "nova console-log output:"
            nova console-log "$VMID"
            echo "neutron port-list output:"
            neutron port-list -D -c device_id -c fixed_ips | grep $VMID
            exit 1
        else
            export FIXED_IP=$FIXED_IP1
        fi
    fi
done

echo FIXED_IP=$FIXED_IP >> /home/jenkins-slave/runs/devstack_params.$ZUUL_UUID.txt
echo "FIXED_IP=$FIXED_IP"

sleep 10
exec_with_retry "nova add-floating-ip $VMID $FLOATING_IP" 15 5 || { echo "nova show $VMID:"; nova show "$VMID"; echo "nova console-log $VMID:"; nova console-log "$VMID"; exit 1; }

echo "nova show $VMID:"
nova show "$VMID"

sleep 60
wait_for_listening_port $FLOATING_IP 22 30 || { echo "nova console-log $VMID:"; nova console-log "$VMID"; echo "Failed listening for ssh port on devstack";exit 1; }

echo "adding $NAME to /etc/hosts"
run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY 'VMNAME=$(hostname); sudo sed -i "s/127.0.0.1 localhost/127.0.0.1 localhost $VMNAME/g" /etc/hosts' 1

echo "adding apt-cacher-ng:"
run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY 'echo "Acquire::http { Proxy \"http://10.21.7.214:3142\" };" | sudo tee --append /etc/apt/apt.conf.d/90-apt-proxy.conf' 1

echo "clean any apt files:"
run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY "sudo rm -rf /var/lib/apt/lists/*" 1

echo "apt-get update:"
run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY "sudo apt-get update -y" 1

echo "apt-get upgrade:"
run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY 'DEBIAN_FRONTEND=noninteractive && DEBIAN_PRIORITY=critical && sudo apt-get -q -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade' 1
run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY 'DEBIAN_FRONTEND=noninteractive && DEBIAN_PRIORITY=critical && sudo apt-get -q -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" autoremove' 1

# set timezone to UTC
run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY "sudo ln -fs /usr/share/zoneinfo/UTC /etc/localtime" 1

# copy files to devstack
scp -v -r -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null" -i $DEVSTACK_SSH_KEY /usr/local/src/oswin-ci/devstack_vm/* ubuntu@$FLOATING_IP:/home/ubuntu/

ZUUL_SITE=`echo "$ZUUL_URL" |sed 's/.\{2\}$//'`
echo ZUUL_SITE=$ZUUL_SITE >> /home/jenkins-slave/runs/devstack_params.$ZUUL_UUID.txt

set +e
VLAN_RANGE=`/usr/local/src/oswin-ci/vlan_allocation.py -a $VMID`
if [ ! -z "$VLAN_RANGE" ]
then
  run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY "sed -i 's/TENANT_VLAN_RANGE.*/TENANT_VLAN_RANGE='$VLAN_RANGE'/g' /home/ubuntu/devstack/local.conf" 3
fi
set -e

run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY "sed -i 's/export OS_AUTH_URL.*/export OS_AUTH_URL=http:\/\/127.0.0.1:5000\/v2.0\//g' /home/ubuntu/keystonerc" 3

# Add 1 more interface after successful SSH
nova interface-attach --net-id "$NET_ID" "$VMID"

# update repos
run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY "/home/ubuntu/bin/update_devstack_repos.sh --branch $ZUUL_BRANCH --build-for $ZUUL_PROJECT" 1

echo ZUUL_SITE=$ZUUL_SITE >> /home/jenkins-slave/runs/devstack_params.$ZUUL_UUID.txt

# Set ZUUL IP in hosts file
ZUUL="10.21.7.8"
if  ! grep -qi zuul /etc/hosts ; then
    run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY "echo '$ZUUL zuul.openstack.tld' | sudo tee -a /etc/hosts"
fi

# gerrit-git-prep
run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY "/home/ubuntu/bin/gerrit_git_prep.sh --zuul-site $ZUUL_SITE --gerrit-site $ZUUL_SITE --zuul-ref $ZUUL_REF --zuul-change $ZUUL_CHANGE --zuul-project $ZUUL_PROJECT" 1

# get locally the vhdx files used by tempest
run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY "mkdir -p /home/ubuntu/devstack/files/images"
run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY "wget http://dl.openstack.tld/cirros-0.3.3-x86_64.vhdx -O /home/ubuntu/devstack/files/images/cirros-0.3.3-x86_64.vhdx"
run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY "wget http://dl.openstack.tld/Fedora-x86_64-20-20140618-sda.vhdx.gz -O /home/ubuntu/devstack/files/images/Fedora-x86_64-20-20140618-sda.vhdx.gz"

# install neutron pip package as it is external
#run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY "sudo pip install -U networking-hyperv --pre"

# make local.sh executable
run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY "chmod a+x /home/ubuntu/devstack/local.sh"

# Preparing share for HyperV logs
run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY 'mkdir -p /openstack/logs; chmod 777 /openstack/logs; sudo chown nobody:nogroup /openstack/logs'

# Unzip Fedora image
echo `date -u +%H:%M:%S` "Started to unzip Fedora image.."
run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY "gzip --decompress --force /home/ubuntu/devstack/files/images/Fedora-x86_64-20-20140618-sda.vhdx.gz"

# Building devstack as a threaded job
echo `date -u +%H:%M:%S` "Started to build devstack as a threaded job"
nohup /usr/local/src/oswin-ci/jobs/build_devstack.sh > /home/jenkins-slave/logs/devstack-build-log-$ZUUL_UUID 2>&1 &
pid_devstack=$!

# Building and joining HyperV nodes
echo `date -u +%H:%M:%S` "Started building & joining Hyper-V node: $hyperv01"
nohup /usr/local/src/oswin-ci/jobs/build_hyperv.sh $hyperv01 > /home/jenkins-slave/logs/hyperv-build-log-$ZUUL_UUID-$hyperv01 2>&1 &
pid_hv01=$!

echo `date -u +%H:%M:%S` "Started building & joining Hyper-V node: $hyperv02"
nohup /usr/local/src/oswin-ci/jobs/build_hyperv.sh $hyperv02 > /home/jenkins-slave/logs/hyperv-build-log-$ZUUL_UUID-$hyperv02 2>&1 &
pid_hv02=$!

# Waiting for devstack threaded job to finish
wait $pid_devstack

# Wait for both nodes to finish building and joining
wait $pid_hv01

wait $pid_hv02

OSTACK_PROJECT=`echo "$ZUUL_PROJECT" | cut -d/ -f2`

if [[ ! -z $IS_DEBUG_JOB ]] && [[ $IS_DEBUG_JOB = "yes" ]]
    then
        echo "devstack build log can be found in http://64.119.130.115/debug/$OSTACK_PROJECT/$ZUUL_CHANGE/$ZUUL_PATCHSET/<timestamp>/devstack-build-log-$ZUUL_UUID.log"
        echo "$hyperv01 build log can be found in http://64.119.130.115/debug/$OSTACK_PROJECT/$ZUUL_CHANGE/$ZUUL_PATCHSET/<timestamp>/hyperv-build-log-$ZUUL_UUID-$hyperv01.log"
        echo "$hyperv02 build log can be found in http://64.119.130.115/debug/$OSTACK_PROJECT/$ZUUL_CHANGE/$ZUUL_PATCHSET/<timestamp>/hyperv-build-log-$ZUUL_UUID-$hyperv02.log"
    else
        echo "devstack build log can be found in http://64.119.130.115/$OSTACK_PROJECT/$ZUUL_CHANGE/$ZUUL_PATCHSET/devstack-build-log-$ZUUL_UUID.log"
        echo "$hyperv01 build log can be found in http://64.119.130.115/$OSTACK_PROJECT/$ZUUL_CHANGE/$ZUUL_PATCHSET/hyperv-build-log-$ZUUL_UUID-$hyperv01.log"
        echo "$hyperv02 build log can be found in http://64.119.130.115/$OSTACK_PROJECT/$ZUUL_CHANGE/$ZUUL_PATCHSET/hyperv-build-log-$ZUUL_UUID-$hyperv02.log"
fi

# HyperV post-build services restart
post_build_restart_hyperv_services $hyperv01 $WIN_USER $WIN_PASS
post_build_restart_hyperv_services $hyperv02 $WIN_USER $WIN_PASS

# Check for nova join (must equal 2)
run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY 'source /home/ubuntu/keystonerc; NOVA_COUNT=$(nova service-list | grep nova-compute | grep -c -w up); if [ "$NOVA_COUNT" != 2 ];then nova service-list; exit 1;fi' 12
run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY 'source /home/ubuntu/keystonerc; nova service-list' 1

# Check for neutron join (must equal 2)
run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY 'source /home/ubuntu/keystonerc; NEUTRON_COUNT=$(neutron agent-list | grep -c "HyperV agent.*:-)"); if [ "$NEUTRON_COUNT" != 2 ];then neutron agent-list; exit 1;fi' 12
run_ssh_cmd_with_retry ubuntu@$FLOATING_IP $DEVSTACK_SSH_KEY 'source /home/ubuntu/keystonerc; neutron agent-list' 1

