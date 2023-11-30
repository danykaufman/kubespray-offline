#!/bin/bash

# Exit on any error
set -e
# Override configs to avoid replacing the script multiple times
cat ./igz_config.sh > ./config.sh && . ./config.sh
pushd ./kubespray-$KUBESPRAY_VERSION && . ./venv/bin/activate && popd

BASEDIR="."
FILES_DIR=./files
KUBESPRAY_DIR_NAME=kubespray-$KUBESPRAY_VERSION
BASEDIR=$(cd $BASEDIR; pwd)
NGINX_IMAGE=iguazio/nginx_server:latest
RESET="no"
SKIP_INSTALL="no"
SCALE_OUT="no"
DEPLOYMENT_PLAYBOOK="cluster.yml"
LOCAL_REGISTRY=${LOCAL_REGISTRY:-"localhost:${REGISTRY_PORT}"}
if [ -f /etc/ansible/facts.d/haproxy.fact ]; then
    HAPROXY=$(grep 'enabled' /etc/ansible/facts.d/haproxy.fact | awk -F ' = ' '{print $2}') || HAPROXY="false"
else
    HAPROXY="false"
fi



###### Flow starts here ##########################

# Get the deploy options
for arg in "$@"
do
   if [ "$arg" == "--reset" ]; then
       echo "Reset was requested"
       RESET="yes"
   elif [ "$arg" == "--skip-k8s-install" ]; then
       echo "skip-k8s-install was requested"
       SKIP_INSTALL="yes"
   elif [ "$arg" == "--scale" ]; then
       echo "Scale out requested"
       SCALE_OUT="yes"
       DEPLOYMENT_PLAYBOOK="scale.yml"
   fi
done

# Verify deploy options
if [ "$SCALE_OUT" == "yes" ]; then
 RESET="no"
 SKIP_INSTALL="no"
fi

echo "==> Build Iguazio inventory"
python3 ./igz_inventory_builder.py "${@: -4}" "$HAPROXY"

# Don't stop containers in case of scale out - it's a live data node!
if [ "$SCALE_OUT" == "yes" ]; then
  echo -e "\n# Live system flag\nlive_system: true" >> igz_override.yml
else
  echo -e "\n# Live system flag\nlive_system: false" >> igz_override.yml
fi

# TODO: Ugly piece of code
echo "==> Copy Iguazio files"
pushd ./$KUBESPRAY_DIR_NAME
cp -r inventory/sample inventory/igz
# Copy and rename file in one line
cat ../igz_offline.yml > inventory/igz/group_vars/all/offline.yml
cp ../igz_override.yml .
cp ../igz_inventory.ini ./inventory/igz
cp ../igz_hosts.toml.j2 .
cp ../config.toml.patch .
cp ../igz_reset.yml .
cp ../igz_pre_install.yml .
cp ../igz_post_install.yml .
cp ../igz_run_ansible.sh .

# Copy playbook for offline repo
cp -r ../playbook .

# The files in kubespray dir are owned by root and we don't like it
chown -R iguazio:iguazio .

# Run igz_preinstall playbook
./igz_run_ansible.sh -i inventory/igz/igz_inventory.ini igz_pre_install.yml --become --extra-vars=@igz_override.yml

# Run offline repo playbook
./igz_run_ansible.sh -i inventory/igz/igz_inventory.ini playbook/offline-repo.yml --become --extra-vars=@igz_override.yml

# Reset Kubespray
if [[ "${RESET}" == "yes" ]]; then
  echo "==> Reset Kubernetes"
  ./igz_run_ansible.sh -i inventory/igz/igz_inventory.ini reset.yml --become --extra-vars=@igz_override.yml --extra-vars reset_confirmation=yes
  ./igz_run_ansible.sh -i inventory/igz/igz_inventory.ini igz_reset.yml --become --extra-vars=@igz_override.yml
fi

# Run kubespray
if [[ "${SKIP_INSTALL}" == "no" ]]; then
    echo "==> Install  Kubernetes"
    ./igz_run_ansible.sh -i inventory/igz/igz_inventory.ini $DEPLOYMENT_PLAYBOOK --become --extra-vars=@igz_override.yml
    ./igz_run_ansible.sh -i inventory/igz/igz_inventory.ini igz_post_install.yml --become --extra-vars=@igz_override.yml
fi

popd

echo "<=== Kubespray deployed. Happy k8s'ing ===>"
exit 0