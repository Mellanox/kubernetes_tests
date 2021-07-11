#!/bin/bash

export RECLONE=${RECLONE:-true}
export WORKSPACE=${WORKSPACE:-/tmp/k8s_$$}
export LOGDIR=$WORKSPACE/logs
export ARTIFACTS=$WORKSPACE/artifacts
export TIMEOUT=${TIMEOUT:-600}
export POLL_INTERVAL=${POLL_INTERVAL:-10}

# can be <latest_stable|master|vA.B.C>
export KUBERNETES_VERSION=${KUBERNETES_VERSION:-latest_stable}
export KUBERNETES_BRANCH=${KUBERNETES_BRANCH:-master}

export HARBOR_REGESTRY=${HARBOR_REGESTRY:-harbor.mellanox.com}
export HARBOR_PROJECT=${HARBOR_PROJECT:-cloud-orchestration}

export MULTUS_CNI_REPO=${MULTUS_CNI_REPO:-https://github.com/intel/multus-cni}
export MULTUS_CNI_BRANCH=${MULTUS_CNI_BRANCH:-''}
export MULTUS_CNI_PR=${MULTUS_CNI_PR:-''}
export MULTUS_CNI_HARBOR_IMAGE=${MULTUS_CNI_HARBOR_IMAGE:-${HARBOR_REGESTRY}/${HARBOR_PROJECT}/multus}

export SRIOV_NETWORK_DEVICE_PLUGIN_REPO=${SRIOV_NETWORK_DEVICE_PLUGIN_REPO:-https://github.com/k8snetworkplumbingwg/sriov-network-device-plugin}
export SRIOV_NETWORK_DEVICE_PLUGIN_BRANCH=${SRIOV_NETWORK_DEVICE_PLUGIN_BRANCH:-''}
export SRIOV_NETWORK_DEVICE_PLUGIN_PR=${SRIOV_NETWORK_DEVICE_PLUGIN_PR:-''}
export SRIOV_NETWORK_DEVICE_PLUGIN_HARBOR_IMAGE=${SRIOV_NETWORK_DEVICE_PLUGIN_HARBOR_IMAGE:-${HARBOR_REGESTRY}/${HARBOR_PROJECT}/sriov-device-plugin}

export PLUGINS_REPO=${PLUGINS_REPO:-https://github.com/containernetworking/plugins.git}
export PLUGINS_BRANCH=${PLUGINS_BRANCH:-''}
export PLUGINS_BRANCH_PR=${PLUGINS_BRANCH_PR:-''}

export PATH=/usr/local/go/bin/:$GOPATH/src/k8s.io/kubernetes/third_party/etcd:$PATH

export API_HOST=$(hostname)
export API_HOST_IP=$(hostname -I | awk '{print $1}')
export POD_CIDER=${POD_CIDER:-'192.168.0.0/16'}
export SERVICE_CIDER=${SERVICE_CIDER:-'172.0.0.0/16'}
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}

export CNI_BIN_DIR=${CNI_BIN_DIR:-/opt/cni/bin/}
export CNI_CONF_DIR=${CNI_CONF_DIR:-/etc/cni/net.d/}

export SRIOV_INTERFACE=${SRIOV_INTERFACE:-auto_detect}
export RDMA_RESOURCE=${RDMA_RESOURCE:-"auto_detect"}

# generate random network
N=$((1 + RANDOM % 128))
export NETWORK=${NETWORK:-"192.168.$N"}

export SCRIPTS_DIR=${SCRIPTS_DIR:-$(pwd)}

##################################################
##################################################
###############   Functions   ####################
##################################################
##################################################

create_workspace(){
    echo "Working in $WORKSPACE"
    mkdir -p $WORKSPACE
    mkdir -p $LOGDIR
    mkdir -p $ARTIFACTS

    date +"%Y-%m-%d %H:%M:%S" > ${LOGDIR}/start-time.log
}

get_arch(){
    if [[ $(uname -a) == *"ppc"* ]]; then
        echo ppc
    else
        echo amd
    fi
}

k8s_build(){
    status=0
    echo "Download K8S"
    sudo rm -rf /usr/local/bin/kubectl
    if [ ${KUBERNETES_VERSION} == 'latest_stable' ]; then
        export KUBERNETES_VERSION=$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)
    fi
    sudo rm -rf $WORKSPACE/src/k8s.io/kubernetes

    git clone https://github.com/kubernetes/kubernetes.git $WORKSPACE/src/k8s.io/kubernetes

    pushd $WORKSPACE/src/k8s.io/kubernetes
    git checkout ${KUBERNETES_VERSION}
    git log -p -1 > $ARTIFACTS/kubernetes.txt

    make kubectl kubeadm kubelet

    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to build K8S ${KUBERNETES_VERSION}: Failed to make."
        return $status
    fi

    cp _output/bin/kubectl _output/bin/kubeadm _output/bin/kubelet  /usr/local/bin/

    kubectl version --client
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to run kubectl please fix the error above!"
        return $status
    fi

    popd
}

prepare_kubelet(){
    cp -rf ${SCRIPTS_DIR}/deploy/kubelet/* /etc/systemd/system/
    sudo systemctl daemon-reload
}

get_distro(){
    grep ^NAME= /etc/os-release | cut -d'=' -f2 -s | tr -d '"' | tr [:upper:] [:lower:] | cut -d" " -f 1
}

get_distro_version(){
    grep ^VERSION_ID= /etc/os-release | cut -d'=' -f2 -s | tr -d '"'
}

get_kind_distro_version(){
    # (abdallahyas): This is used to determine the kind cluster OS version
    # Since this is called before the cluster is up, it is hard to read it
    # so static value is returned.

    # Also Ubuntu version 20.10 is not currently supported for mofed container
    # so a workaround of retaging the 20.04 version to 20.10 and using it is
    # adopted to run the mofed container inside the kind nodes.

    echo "20.10"
}

configure_firewall(){
    local os_distro=$(get_distro)
    if [[ "$os_distro" == "ubuntu" ]];then
        sudo systemctl stop ufw
        sudo systemctl disable ufw
    elif [[ "$os_distro" == "centos" ]]; then
        sudo systemctl stop firewalld
        sudo systemctl stop iptables
        sudo systemctl disable firewalld
        sudo systemctl disable iptables
    else
        echo "Warning: Unknown Distribution \"$os_distro\", stopping iptables..."
        sudo systemctl stop iptables
        sudo systemctl disable iptables
    fi
}

k8s_run(){
    status=0

    prepare_kubelet

    configure_firewall

    sudo kubeadm init --apiserver-advertise-address=$API_HOST_IP --node-name=$API_HOST --pod-network-cidr $POD_CIDER --service-cidr $SERVICE_CIDER
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo 'Failed to run kubeadm!'
        return $status
    fi

    sudo chmod 644 /etc/kubernetes/*.conf

    kubectl taint nodes $(kubectl get nodes -o name | cut -d'/' -f 2) --all node-role.kubernetes.io/master-
    return $?
}

network_plugins_install(){
    status=0
    echo "Download $PLUGINS_REPO"
    sudo rm -rf $WORKSPACE/plugins
    git clone $PLUGINS_REPO $WORKSPACE/plugins
    pushd $WORKSPACE/plugins
    if test ${PLUGINS_PR}; then
        git fetch --tags --progress ${PLUGINS_REPO} +refs/pull/*:refs/remotes/origin/pr/*
        git pull origin pull/${PLUGINS_PR}/head
        let status=status+$?
        if [ "$status" != 0 ]; then
            echo "Failed to fetch container networking pull request #${PLUGINS_PR}!!"
            return $status
        fi
    elif test $PLUGINS_BRANCH; then
        git checkout $PLUGINS_BRANCH
        if [ "$status" != 0 ]; then
            echo "Failed to switch to container networking branch ${PLUGINS_BRANCH}!!"
            return $status
        fi
    fi
    git log -p -1 > $ARTIFACTS/plugins-git.txt
    bash ./build_linux.sh
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to build $PLUGINS_REPO $PLUGINS_BRANCH"
        return $status
    fi

    cp bin/* $CNI_BIN_DIR/
    popd
}

multus_install(){
    status=0
    build_github_project "multus-cni" "sudo docker build -t $MULTUS_CNI_HARBOR_IMAGE ."

    change_k8s_resource "DaemonSet" "kube-multus-ds" "spec.template.spec.containers[0].image"\
        "$MULTUS_CNI_HARBOR_IMAGE" "$WORKSPACE/multus-cni/images/multus-daemonset.yml"
}

multus_configuration() {
    status=0
    echo "Configure Multus"
    local arch=$(get_arch)
    date
    sleep 30
    sed -i 's;/etc/cni/net.d/multus.d/multus.kubeconfig;/etc/kubernetes/admin.conf;g' $WORKSPACE/multus-cni/images/multus-daemonset.yml

    kubectl create -f $WORKSPACE/multus-cni/images/multus-daemonset.yml

    kubectl -n kube-system get ds
    rc=$?
    let stop=$(date '+%s')+$TIMEOUT
    d=$(date '+%s')
    while [ $d -lt $stop ]; do
       echo "Wait until multus is ready"
       ready=$(kubectl -n kube-system get ds |grep kube-multus-ds|awk '{print $4}')
       rc=$?
       kubectl -n kube-system get ds
       d=$(date '+%s')
       sleep $POLL_INTERVAL
       if [ $ready -gt 0 ]; then
           echo "System is ready"
           break
      fi
    done
    if [ $d -gt $stop ]; then
        kubectl -n kube-system get ds
        echo "kube-multus-ds-${arch}64 is not ready in $TIMEOUT sec"
        return 1
    fi

    if [[ ! -d $CNI_CONF_DIR ]];then
        return 0
    fi

    multus_config=$CNI_CONF_DIR/99-multus.conf
    cat > $multus_config <<EOF
    {
        "cniVersion": "0.3.0",
        "name": "macvlan-network",
        "type": "macvlan",
        "mode": "bridge",
          "ipam": {
                "type": "host-local",
                "subnet": "${NETWORK}.0/24",
                "rangeStart": "${NETWORK}.100",
                "rangeEnd": "${NETWORK}.216",
                "routes": [{"dst": "0.0.0.0/0"}],
                "gateway": "${NETWORK}.1"
            }
        }
EOF
    cp $multus_config $ARTIFACTS
    return $?
}

function load_rdma_modules {
    status=0

    if [[ -n "$(lsmod | grep rdma_ucm)" ]]; then
        sudo modprobe -r rdma_ucm
        if [ "$?" != "0" ]; then
            echo "Warning: faild to remove the rdma_ucm module"
        fi
        sleep 2
    fi

    if [[ -n "$(lsmod | grep rdma_cm)" ]]; then
        sudo modprobe -r rdma_cm
        if [ "$?" != "0" ]; then
            echo "Warning: Failed to remove rdma_cm module"
        fi
        sleep 2
    fi
    sudo modprobe rdma_cm
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to load rdma_cm module"
        return $status
    fi
    sudo modprobe rdma_ucm
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to load rdma_ucm module"
        return $status
    fi

    sudo modprobe ib_umad
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to load ib_umad module"
        return $status
    fi

    return $status
}

function enable_rdma_mode {
    local_mode=$1
    if [[ -z "$(rdma system | grep $local_mode)" ]]; then
        sudo rdma system set netns "$local_mode"
        let status=status+$?
        if [ "$status" != 0 ]; then
            echo "Failed to set rdma to $local_mode mode"
            return $status
        fi
    fi
}

function deploy_calico {
    sudo rm -rf /etc/cni/net.d/00*

    cp ${SCRIPTS_DIR}/deploy/calico.yaml "$ARTIFACTS"/

    kubectl create -f "$ARTIFACTS"/calico.yaml

    wait_pod_state "calico-node" "Running"

    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to set setup calico!"
        return $status
    fi

    sleep 60
}

function create_macvlan_net {
    local macvlan_file="${ARTIFACTS}/macvlan-net.yaml"

    if [ $SRIOV_INTERFACE == 'auto_detect' ]; then
        export SRIOV_INTERFACE=$(ls -l /sys/class/net/ | grep $(lspci |grep Mellanox | grep -Ev 'MT27500|MT27520' | head -n1 | awk '{print $1}') | awk '{print $9}')
    fi

    if [[ ! -f "$macvlan_file" ]];then
        echo "ERROR: Could not find the macvlan file in ${ARTIFACTS}!"
        exit 1
    fi

    replace_placeholder REPLACE_INTERFACE "$SRIOV_INTERFACE" "$macvlan_file"
    replace_placeholder REPLACE_NETWORK "$NETWORK" "$macvlan_file"

    kubectl create -f "$macvlan_file"
    return $?
}

function restart_multus_pod {
    local multus_pod_name=$(kubectl get pods -A -o name | grep multus | cut -d'/' -f2)

    if [[ -z "$multus_pod_name" ]];then
        return 0
    fi

    local multus_pod_namespace=$(kubectl get pods -A -o wide | grep "$multus_pod_name" | awk '{print $1}')

    kubectl delete pod -n $multus_pod_namespace $multus_pod_name
}

function replace_placeholder {
    local placeholder=$1
    local new_value=$2
    local file=$3

    echo "Changing \"$placeholder\" into \"$new_value\" in $file"
    sed -i "s;$placeholder;$new_value;" $file
}

function yaml_write {
    local key=$1
    local new_value=$2
    local file=$3

    echo "Changing the value of \"$key\" in $file to \"$new_value\""
    yq w -i "$file" "$key" -- "$new_value"
}

function yaml_double_write {
    local key=$1
    local new_value=$2
    local file=$3

    echo "Changing the value of \"$key\" in $file to \"$new_value\""
    yq w -i --style=double "$file" "$key" -- "$new_value"
}

function yaml_read {
    local key=$1
    local file=$2
    
    yq r "$file" "$key"
}

function wait_pod_state {
    pod_name="$1"
    state="$2"
    let stop=$(date '+%s')+$TIMEOUT
    d=$(date '+%s')
    while [ $d -lt $stop ]; do
        echo "Waiting for pod to become $state"
        pod_status=$(kubectl get pods -A | grep "$pod_name" | grep "$state")
        if [ -n "$pod_status" ]; then
            return 0
        fi
        kubectl get pods -A| grep "$pod_name"
        sleep ${POLL_INTERVAL}
        d=$(date '+%s')
    done
    echo "Error $pod_name is not up"
    return 1
}

function check_resource_state {
    local resource_kind="$1"
    local resource_name="$2"
    local state="$3"

    kubectl get $resource_kind -A | grep $resource_name | grep -i $state
}

function deploy_k8s_with_multus {

    network_plugins_install
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to install container networking plugins!!"
        popd
        return $status
    fi

    k8s_build
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to build Kubernetes!!"
        popd
        return $status
    fi

    k8s_run
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to run Kubernetes!!"
        popd
        return $status
    fi

    deploy_multus
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to deploy multus!!"
        popd
        return $status
    fi
}

function deploy_multus {
    multus_install
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to clone multus!!"
        popd
        return $status
    fi

    multus_configuration
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to run multus!!"
        popd
        return $status
    fi
}

function change_k8s_resource {
    local resource_kind="$1"
    local resource_name="$2"
    local resource_key="$3"
    local resource_new_value="$4"
    local resource_file="$5"

    let doc_num=0
    changed="false"
    for kind in $(yq r -d "*" $resource_file kind);do
        if [[ "$kind" == "$resource_kind" ]];then
            name=$(yq r -d "$doc_num" $resource_file metadata.name)
            if [[ "$name" == "$resource_name" ]];then
                echo "changing $resource_key to $resource_new_value"
                yq w -i -d "$doc_num" "$resource_file" "$resource_key" "$resource_new_value"
                changed="true"
                break
            fi
        fi
        let doc_num=$doc_num+1
    done

    if [[ "$changed" == "false" ]];then
        echo "Failed to change $resource_key to $resource_new_value in $resource_file!"
        return 1
   fi

   return 0
}

function deploy_sriov_device_plugin {
    build_github_project "sriov-network-device-plugin" \
        "sed -i 's;^TAG=.*;TAG=$SRIOV_NETWORK_DEVICE_PLUGIN_HARBOR_IMAGE;' Makefile && make image"

    change_k8s_resource "DaemonSet" "kube-sriov-device-plugin-amd64" "spec.template.spec.containers[0].image"\
        "$SRIOV_NETWORK_DEVICE_PLUGIN_HARBOR_IMAGE" "$WORKSPACE/sriov-network-device-plugin/deployments/k8s-v1.16/sriovdp-daemonset.yaml"

    cat > $ARTIFACTS/configMap.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: sriovdp-config
  namespace: kube-system
data:
  config.json: |
    {
      "resourceList": [{
          "resourcePrefix": "mellanox.com",
          "resourceName": "sriov_rdma",
          "selectors": {
                  "vendors": ["15b3"],
                  "devices": ["1018"],
                  "drivers": ["mlx5_core"],
                  "isRdma": true
              }
      }
      ]
    }
EOF
}

function configure_images_specs {
    local key="$1"
    local file="$2"

    local upper_case_key="$(sed 's/[A-Z]/\.\0/g' <<< $key | tr "." "_" | tr '[:lower:]' '[:upper:]')"

    local image_variable="${upper_case_key}_IMAGE"
    local repo_variable="${upper_case_key}_REPO"
    local version_variable="${upper_case_key}_VERSION"

    yaml_write "spec.${key}.image" "${!image_variable}" "$file"
    yaml_write "spec.${key}.repository" "${!repo_variable}" "$file"
    yaml_write "spec.${key}.version" "${!version_variable}" "$file"
}

function create_test_pod {
    local pod_name="${1:-test-pod-$$}"
    local file="${2:-${ARTIFACTS}/${pod_name}.yaml}"
    local pod_image=${3:-'harbor.mellanox.com/cloud-orchestration/rping-test'}
    local pod_network=${4:-'macvlan-net'}

    render_test_pods_common $pod_name $file $pod_image $pod_network

    kubectl create -f $file

    wait_pod_state $pod_name 'Running'
    if [[ "$?" != 0 ]];then
        echo "Error Running $pod_name!!"
        return 1
    fi

    echo "$pod_name is now running."
    sleep 5
    return 0
}

function create_rdma_test_pod {
    local pod_name=$1
    local rdma_resource_name="$2"
    local image="$3"
    local network="$4"

    local test_pod_file=${ARTIFACTS}/${pod_name}.yaml

    render_test_pods_common "$pod_name" "$test_pod_file" "$image" "$network"

    render_test_pod_rdma_resources $rdma_resource_name $test_pod_file

    kubectl create -f "$ARTIFACTS"/"$pod_name".yaml
    wait_pod_state $pod_name 'Running'
    if [[ "$?" != 0 ]];then
        echo "Error Running $pod_name!!"
        return 1
    fi

    echo "$pod_name is now running."
    sleep 5
    return 0
}

function create_gpu_direct_test_pod {
    local pod_name=$1
    local rdma_resource_name=$2
    local image="$3"
    local network="$4"

    local test_pod_file=${ARTIFACTS}/${pod_name}.yaml

    render_test_pods_common "$pod_name" "$test_pod_file" "$image" "$network"

    render_test_pod_rdma_resources "$rdma_resource_name" "$test_pod_file"

    render_test_pod_gpu_resources "$test_pod_file"

    kubectl create -f "$ARTIFACTS"/"$pod_name".yaml
    wait_pod_state $pod_name 'Running'
    if [[ "$?" != 0 ]];then
        echo "Error Running $pod_name!!"
        return 1
    fi

    echo "$pod_name is now running."
    sleep 5
    return 0
}

function render_test_pods_common {
    local pod_name="${1:-test-pod-$$}"
    local file="${2:-${ARTIFACTS}/${pod_name}.yaml}"
    local pod_image=${3:-'harbor.mellanox.com/cloud-orchestration/rping-test:latest'}
    local pod_network=${4:-'macvlan-net'}

    if [[ ! -f "$file" ]];then
        touch "$file"
    fi

    yaml_write "apiVersion" "v1" "$file"
    yaml_write "kind" "Pod" "$file"
    yaml_write "metadata.name" "${pod_name}" "$file"
    yaml_write "metadata.annotations[k8s.v1.cni.cncf.io/networks]" "${pod_network}" "$file"

    yaml_write spec.containers[0].name "test-pod" $file
    yaml_write spec.containers[0].image "$pod_image" $file
    yaml_write spec.containers[0].imagePullPolicy IfNotPresent $file
    yaml_write spec.containers[0].securityContext.capabilities.add[0] "IPC_LOCK" $file
    yaml_write spec.containers[0].command[0] "/bin/bash" $file
    yaml_write spec.containers[0].args[0] "-c" $file
    yaml_write spec.containers[0].args[1] "--" $file
    yaml_write spec.containers[0].args[2] "while true; do sleep 300000; done;" $file 
}

function render_test_pod_rdma_resources {
    # Note(abdallahyas): This needs to be the first resource to be
    # rendered, it will delete the resources.requests and resources.limits
    # sections in the yaml file and create them anew.

    local rdma_resource_name=${1:-rdma/rdma_shared_devices_a}
    local file="$2"

    if [[ ! -f "$file" ]];then
        render_test_pods_common
    fi

    yaml_write spec.containers[0].resources.requests "" $file
    yaml_write spec.containers[0].resources.limits "" $file

    yaml_write spec.containers[0].resources.requests[$rdma_resource_name] 1 $file
    yaml_write spec.containers[0].resources.limits[$rdma_resource_name] 1 $file
}

function render_test_pod_gpu_resources {
    local gpu_resource_name='nvidia.com/gpu'
    local file="$1"

    if [[ ! -f "$file" ]];then
        render_test_pods_common
    fi

    yaml_write spec.containers[0].resources.requests["$gpu_resource_name"] 1 "$file"
    yaml_write spec.containers[0].resources.limits["$gpu_resource_name"] 1 "$file"
}

function test_pods_connectivity {
    local status=0
    local POD_NAME_1=$1
    local POD_NAME_2=$2

    if [[ -z "$(check_resource_state "pod" "$POD_NAME_1" "Running" )" ]]; then
        echo "Error: pod $POD_NAME_1 is not running!"
        return 1
    fi

    if [[ -z "$(check_resource_state "pod" "$POD_NAME_2" "Running" )" ]]; then
        echo "Error: pod $POD_NAME_2 is not running!"
        return 1
    fi

    local ip_1=$(/usr/local/bin/kubectl exec -t ${POD_NAME_1} -- ifconfig net1|grep inet|grep -v inet6|awk '{print $2}')
    /usr/local/bin/kubectl exec -i ${POD_NAME_1} -- ifconfig net1
    echo "${POD_NAME_1} has ip ${ip_1}"

    local ip_2=$(/usr/local/bin/kubectl exec -t ${POD_NAME_2} -- ifconfig net1|grep inet|grep -v inet6|awk '{print $2}')
    /usr/local/bin/kubectl exec -i ${POD_NAME_2} -- ifconfig net1
    echo "${POD_NAME_2} has ip ${ip_2}"

    /usr/local/bin/kubectl exec -t ${POD_NAME_2} -- bash -c "ping $ip_1 -c 1 >/dev/null 2>&1"
    let status=status+$?

    if [ "$status" != 0 ]; then
        echo "Error: There is no connectivity between the pods"
        return $status
    fi

    echo ""
    echo "Connectivity test suceeded!"
    echo ""

    return $status
}

function build_github_project {
    local project_name="$1"
    local image_build_command="${2:-make image}"

    local status=0

    if [[ -z "$project_name" ]];then
        echo "ERROR: No project specified to build!"
        return 1
    fi

    local upper_case_project_name="$(tr "-" "_" <<< $project_name | tr '[:lower:]' '[:upper:]')"

    local repo_variable="${upper_case_project_name}_REPO"
    local branch_variable="${upper_case_project_name}_BRANCH"
    local pr_variable="${upper_case_project_name}_PR"
    local harbor_image_variable="${upper_case_project_name}_HARBOR_IMAGE"

    echo "Downloading ${!repo_variable}"
    sudo rm -rf "$WORKSPACE"/"$project_name"

    git clone "${!repo_variable}" "$WORKSPACE"/"$project_name"

    pushd $WORKSPACE/"$project_name"

    local sed_match_reg='s/(@| |^|=)docker($| )/\1sudo docker\2/'

    # Check if part of Pull Request and
    if test ${!pr_variable}; then
        git fetch --tags --progress ${!repo_variable} +refs/pull/${!pr_variable}/*:refs/remotes/origin/pull-requests/${!pr_variable}/*
        git checkout pull-requests/${!pr_variable}/head
        let status=$status+$?
        if [[ "$status" != "0" ]];then
            echo "ERROR: Failed to checkout the $project_name pull request number ${!pr_variable}!"
            return "$status"
        fi
        
        if [[ -f Makefile ]]; then
            sed -ri "${sed_match_reg}" Makefile
        fi

        eval "$image_build_command"
        let status=$status+$?
    elif test ${!branch_variable}; then
        git checkout ${!branch_variable}
        let status=$status+$?
        if [[ "$status" != "0" ]];then
            echo "ERROR: Failed to checkout the $project_name branch ${!branch_variable}!"
            return "$status"
        fi

        if [[ -f Makefile ]]; then
            sed -ri "${sed_match_reg}" Makefile
        fi

        eval "$image_build_command"
        let status=$status+$?
    else
        sudo docker pull ${!harbor_image_variable}
        let status=$status+$?
    fi

    git log -p -1 > $ARTIFACTS/${project_name}-git.txt

    popd

    if [[ "$status" != "0" ]];then
        echo "ERROR: Failed to build the $project_name Project!"
        return "$status"
    fi

    return $status
}

function change_image_name {
    local old_image_name="$1"
    local new_image_name="$2"

    sudo docker tag $old_image_name $new_image_name
    if [[ "$?" != "0" ]];then
        echo "ERROR: Failed to rename the image $old_image_name to $new_image_name"
        return 1
    fi

    sudo docker rmi $old_image_name
}

function get_net_devices_pcis {
    # Note(abdallahyas): This function returns mellanox pfs pcis, It looks for non CX3 cards
    # and returns the PCIs in a space separated format instead of a newline separated formate

    lspci | grep Mellanox | grep -Ev 'MT27500|MT27520|Virt' | awk '{print $1}' | sed ':a;N;$!ba;s/\n/ /g'
}

function get_auto_net_device {
    # Note(abdallahyas): This function returns non-CX3 Mellanox pfs net names in space separated format,
    # it takes the number of interfaces required as its parameter, if the number provided is less than 1,
    # all available interfaces will be returned. 
    # The default behaviour is to return a single interface name, This is done to not break compatibility
    # for the CIs.

    local number_of_devices=${1:-"1"}

    local interfaces=""

    local pcis=$(get_net_devices_pcis)

    local index=0

    local old_IFS=$IFS
    IFS=' '

    for pci in $pcis;do
        interfaces+="$(ls /sys/bus/pci/devices/"0000:$pci"/net/) "
        ((index++))
        if [[ "$index" == "$number_of_devices" ]];then
            break
        fi
    done

    IFS=$old_IFS

    echo $interfaces
}

function deploy_k8s_bare {
    network_plugins_install
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to install container networking plugins!!"
        popd
        return $status
    fi

    k8s_build
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to build Kubernetes!!"
        popd
        return $status
    fi

    k8s_run
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to run Kubernetes!!"
        popd
        return $status
    fi
}

function deploy_kind_cluster_with_multus {
    local project="$1"
    local workers_number="$2"
    local number_of_interfaces="${3:-"1"}"

    local status=0

    deploy_kind_cluster "$project" "$workers_number" "$number_of_interfaces"
    let status=$status+$?
    if [[ "$status" != "0" ]]; then
        echo "Failed to deploy kind!!"
        popd
        return $status
    fi

    deploy_multus
    let status=$status+$?
    if [[ "$status" != "0" ]]; then
        echo "Failed to deploy multus!!"
        popd
        return $status
    fi
}

function deploy_kind_cluster {
    local project="$1"
    local workers_number="$2"
    local number_of_interfaces="${3:-"1"}"

    local status=0

    ./run_kind_ci.sh --project "$project" --num-workers "$workers_number"\
        --phases deploy-kind,utilities
    let status=$status+$?
    if [[ $status != "0" ]];then
        echo "Error: failed to create kind cluster $project!"
        return 1
    fi

    chmod +r $KUBECONFIG

    local proxy_pod_name=$(kubectl get pods -A -o wide | grep ${project} | grep kube-proxy | awk '{print $2}')

    for pod in $proxy_pod_name;do
        if ! kubectl -n kube-system wait --for=condition=Ready pod/$pod --timeout=60s;then
            return 1
        fi
    done

    if [[ "$workers_number" -ge '1' ]];then
        remount_workers_sys_fs
        let status=$status+$?
        if [[ $status != "0" ]];then
            echo "Error: failed to remount workers sysfs to be rw!"
            return $status
        fi
    fi

    sudo rm -rf /usr/local/bin/kubectl
    sudo docker cp ${project}-control-plane:/usr/bin/kubectl /usr/local/bin/

    return $status
}

function remount_workers_sys_fs {
    local status=0

    local worker_containers=$(sudo docker ps -f name=worker -q)

    if [[ -z "$worker_containers" ]];then
        echo "Error: No worker containers found!"
        return 1
    fi

    for worker_container in $worker_containers; do
        sudo docker exec -t "$worker_container" mount -o remount,rw /sys
        let status=$status+$?
    done

    if [[ "$status" != "0" ]];then
        echo "Error: Failed to remount the sys fs of one or more of the worker containers"
        return $status
    fi
}

function test_rdma_rping {
    pod_name1=$1
    pod_name2=$2
    echo "Testing Rping between $pod_name1 and $pod_name2"

    ip_1=$(/usr/local/bin/kubectl exec -i $pod_name1 -- ifconfig net1 | grep inet | grep -v inet6 | awk '{print $2}')
    /usr/local/bin/kubectl exec -i $pod_name1 -- ifconfig net1
    echo "$pod_name1 has ip ${ip_1}"

    screen -S rping_server -d -m bash -x -c "kubectl exec -t $pod_name1 -- rping -svd"
    sleep 20
    kubectl exec -t $pod_name2 -- rping -cvd -a $ip_1 -C 1

    return $?
}

function test_gpu_write_bandwidth {
    pod_name1=$1
    echo "Testing gpu direct between $pod_name1 and $pod_name2"

    ip_1=$(/usr/local/bin/kubectl exec -i $pod_name1 -- ifconfig net1 | grep inet | awk '{print $2}')
    /usr/local/bin/kubectl exec -i $pod_name1 -- ifconfig net1
    echo "$pod_name1 has ip ${ip_1}"

    if ! rdma_resource=$(kubectl exec -t cuda-test-pod-1 -- ls /sys/class/net/net1/device/infiniband); then
        rdma_resource=${RDMA_RESOURCE}
    fi


    screen -S gpu_server -d -m bash -x -c "kubectl exec -t $pod_name1 -- ib_write_bw -d "${rdma_resource}" -F -R -q 2 --use_cuda=0"
    sleep 20
    kubectl exec -t $pod_name1 -- ib_write_bw -d "${rdma_resource}" -F -R -q 2 --use_cuda=0 "$ip_1"
    return $?
}

function test_rdma_plugin {
    status=0
    local test_pod_1_name='test-pod-1'
    local test_pod_2_name='test-pod-2'
    local image="$1"
    local network="$2"
    local requested_resources="$3"

    echo "Testing RDMA shared mode device plugin."
    echo ""
    echo "Creating testing pods."

    create_rdma_test_pod $test_pod_1_name "$requested_resources" "$image" "$network"
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Error: error in creating $test_pod_1_name!"
        return $status
    fi

    create_rdma_test_pod $test_pod_2_name "$requested_resources" "$image" "$network"
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Error: error in creating $test_pod_2_name!"
        return $status
    fi

    echo "checking if the rdma resources were mounted."

    kubectl exec -it $test_pod_1_name -- ls -l /dev/infiniband
    if [[ "$?" != "0" ]]; then
        echo "pod $test_pod_1_name /dev/infiniband directory is empty! failing the test."
        return 1
    fi

    kubectl exec -it $test_pod_2_name -- ls -l /dev/infiniband
    if [[ "$?" != "0" ]]; then
        echo "pod $test_pod_2_name /dev/infiniband directory is empty! failing the test."
        return 1
    fi

    echo ""
    echo "rdma resources are available inside the testing pods!"
    echo ""

    test_rdma_rping $test_pod_1_name $test_pod_2_name
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Error: error testing the rping between $test_pod_1_name $test_pod_2_name!"
        return $status
    fi

    echo ""
    echo "rdma rping test succeeded!"
    echo ""

    kubectl delete pods --all
    sleep 30

    return $status
}

function test_gpu_direct {
    status=0
    local test_pod_1_name='cuda-test-pod-1'
    local image="$1"
    local network="$2"
    local requested_resource="${3:-rdma/rdma_shared_devices_a}"

    echo "Testing GPU direct."
    echo ""
    echo "Creating testing pods."

    create_gpu_direct_test_pod $test_pod_1_name "$requested_resource" "$image" "$network"
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Error: error in creating $test_pod_1_name!"
        return $status
    fi

    echo "checking if the rdma resources were mounted."

    kubectl exec -it $test_pod_1_name -- ls -l /dev/infiniband
    if [[ "$?" != "0" ]]; then
        echo "pod $test_pod_1_name /dev/infiniband directory is empty! failing the test."
        return 1
    fi

    echo ""
    echo "rdma resources are available inside the testing pods!"
    echo ""

    test_gpu_write_bandwidth $test_pod_1_name
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Error: error testing gpu direct between $test_pod_1_name!"
        return $status
    fi

    echo ""
    echo "GPU direct test succeeded!"
    echo ""

    kubectl delete pods --all
    sleep 30

    return $status
}

function load_core_drivers {
    sudo modprobe mlx5_core
    sudo modprobe ib_core
}

function upload_image_to_kind {
    local image="$1"
    local cluster_name=${2:-"kind"}

    if [[ -z "${image}" ]];then
        echo "Error: No image provided to upload to kind !"
        return 1
    fi

    echo "upload $image to kind...."
    sudo kind load docker-image $image --name $cluster_name
    return $?
}

function read_netdev_from_vf_switcher_confs {
    local netns="$1"
    local vf_switcher_conf=${2:-'/etc/vf-switcher/vf-switcher.yaml'}
    local num_of_pfs=${3:-'0'}

    local pfs=""

    local status=0

    if [[ -z "$netns" ]];then
        yaml_read '[0].pfs[0]' $vf_switcher_conf
        return $?
    fi

    local netns_num=$(yq r $vf_switcher_conf -l)
    ((netns_num-=1))

    for index in $(seq 0 ${netns_num}); do
        if [[ "$(yaml_read [${index}].netns $vf_switcher_conf)" == "$netns" ]];then
            if [[ "$num_of_pfs" -lt "0" ]];then
                num_of_pfs="$(yq r $vf_switcher_conf [${index}].pfs -l)"
                ((num_of_pfs--))
            fi

            for pf_index in $(seq 0 $num_of_pfs);do
                pfs+="$(yaml_read [${index}].pfs[$pf_index] $vf_switcher_conf) "
                let status=$status+$?
            done

            echo ${pfs}
            return $status
        fi
    done
}

function get_pf_device_id {
    local netns="$1"

    if [[ -z "$netns" ]];then
        local pf=$(get_auto_net_device)
        cat /sys/class/net/$pf/device/device | cut -d x -f2
    else
        local pf=$(read_netdev_from_vf_switcher_confs "$netns")
        sudo docker exec $netns cat /sys/class/net/$pf/device/device | cut -d x -f 2
    fi
}

function get_pfs_net_name {
    local netns="$1"

    if [[ -z "$netns" ]];then
        get_auto_net_device 0
    else
        read_netdev_from_vf_switcher_confs "$netns" "" "-1"
    fi
}

function get_interface_rdma_resource_name {
    local interface=${1:-"$SRIOV_INTERFACE"}

    if [[ -z "${interface}" ]];then
        interface=$(get_auto_net_device)
    fi

    if [[ ! -e /sys/class/net/${interface} ]];then
        if [[ -n "${project}" ]];then
            sudo docker exec -t ${project}-worker ls /sys/class/net/${interface}/device/infiniband
            return 0
        fi

        return 1
    fi

    ls /sys/class/net/${interface}/device/infiniband
}
