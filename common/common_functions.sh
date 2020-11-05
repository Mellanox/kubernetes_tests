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

export MULTUS_CNI_REPO=${MULTUS_CNI_REPO:-https://github.com/intel/multus-cni}
export MULTUS_CNI_BRANCH=${MULTUS_CNI_BRANCH:-master}
# ex MULTUS_CNI_PR=345 will checkout https://github.com/intel/multus-cni/pull/345
export MULTUS_CNI_PR=${MULTUS_CNI_PR:-''}

export PLUGINS_REPO=${PLUGINS_REPO:-https://github.com/containernetworking/plugins.git}
export PLUGINS_BRANCH=${PLUGINS_BRANCH:-master}
export PLUGINS_BRANCH_PR=${PLUGINS_BRANCH_PR:-''}

export GOPATH=${WORKSPACE}
export PATH=/usr/local/go/bin/:$GOPATH/src/k8s.io/kubernetes/third_party/etcd:$PATH

export API_HOST=$(hostname)
export API_HOST_IP=$(hostname -I | awk '{print $1}')
export POD_CIDER=${POD_CIDER:-'192.168.0.0/16'}
export SERVICE_CIDER=${SERVICE_CIDER:-'172.0.0.0/16'}
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}

export SRIOV_INTERFACE=${SRIOV_INTERFACE:-auto_detect}

# generate random network
N=$((1 + RANDOM % 128))
export NETWORK=${NETWORK:-"192.168.$N"}

export SRIOV_INTERFACE=${SRIOV_INTERFACE:-auto_detect}
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
    echo "Get CPU architechture"
    export ARCH="amd"
    if [[ $(uname -a) == *"ppc"* ]]; then
        export ARCH="ppc"
    fi
}

k8s_build(){
    status=0
    echo "Download K8S"
    rm -f /usr/local/bin/kubectl
    if [ ${KUBERNETES_VERSION} == 'latest_stable' ]; then
        export KUBERNETES_VERSION=$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)
    fi
    rm -rf $GOPATH/src/k8s.io/kubernetes

    go get -d k8s.io/kubernetes

    pushd $GOPATH/src/k8s.io/kubernetes
    git checkout ${KUBERNETES_VERSION}
    git log -p -1 > $ARTIFACTS/kubernetes.txt

    make clean

    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to build K8S ${KUBERNETES_VERSION}: Failed to clean k8s dir."
        return $status
    fi

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

    go get -u github.com/tools/godep

    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to clone godep"
        return $status
    fi

    go get -u github.com/cloudflare/cfssl/cmd/...

    let status=status+$?
    if [ "$status" != 0 ]; then
        echo 'Failed to clone github.com/cloudflare/cfssl/cmd/...'
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

configure_firewall(){
    local os_distro=$(get_distro)
    if [[ "$os_distro" == "ubuntu" ]];then
        systemctl stop ufw
        systemctl disable ufw
    elif [[ "$os_distro" == "centos" ]]; then
        systemctl stop firewalld
        systemctl stop iptables
        systemctl disable firewalld
        systemctl disable iptables
    else
        echo "Warning: Unknown Distribution \"$os_distro\", stopping iptables..."
        systemctl stop iptables
        systemctl disable iptables
    fi
}

k8s_run(){
    status=0

    prepare_kubelet

    configure_firewall

    kubeadm init --apiserver-advertise-address=$API_HOST_IP --node-name=$API_HOST --pod-network-cidr $POD_CIDER --service-cidr $SERVICE_CIDER
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo 'Failed to run kubeadm!'
        return $status
    fi

    mkdir -p $HOME/.kube
    sudo cp -fi /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
    sudo chmod 644 /etc/kubernetes/*.conf

    kubectl taint nodes $(kubectl get nodes -o name | cut -d'/' -f 2) --all node-role.kubernetes.io/master-
    return $?
}

network_plugins_install(){
    status=0
    echo "Download $PLUGINS_REPO"
    rm -rf $WORKSPACE/plugins
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

    \cp bin/* $CNI_BIN_DIR/
    popd
}

multus_install(){
    status=0
    echo "Download $MULTUS_CNI_REPO"
    rm -rf $WORKSPACE/multus-cni
    git clone $MULTUS_CNI_REPO $WORKSPACE/multus-cni
    pushd $WORKSPACE/multus-cni
    # Check if part of Pull Request and
    if test ${MULTUS_CNI_PR}; then
        git fetch --tags --progress $MULTUS_CNI_REPO +refs/pull/*:refs/remotes/origin/pr/*
        git pull origin pull/${MULTUS_CNI_PR}/head
        let status=status+$?
        if [ "$status" != 0 ]; then
            echo "Failed to fetch multus pull request #${MULTUS_CNI_PR}!!"
            return $status
        fi
    elif test $MULTUS_CNI_BRANCH; then
        git checkout $MULTUS_CNI_BRANCH
        let status=status+$?
        if [ "$status" != 0 ]; then
            echo "Failed to switch to multus branch ${MULTUS_CNI_BRANCH}!!"
            return $status
        fi
    fi

    ./build
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to build multus!!"
        return $status
    fi
    cp bin/multus /opt/cni/bin/

    git log -p -1 > $ARTIFACTS/multus-cni-git.txt
    popd
}

multus_configuration() {
    status=0
    echo "Configure Multus"
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
       ready=$(kubectl -n kube-system get ds |grep kube-multus-ds-${ARCH}|awk '{print $4}')
       rc=$?
       kubectl -n kube-system get ds
       d=$(date '+%s')
       sleep $POLL_INTERVAL
       if [ $ready -eq 1 ]; then
           echo "System is ready"
           break
      fi
    done
    if [ $d -gt $stop ]; then
        kubectl -n kube-system get ds
        echo "kube-multus-ds-${ARCH}64 is not ready in $TIMEOUT sec"
        return 1
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
    if [ $SRIOV_INTERFACE == 'auto_detect' ]; then
        export SRIOV_INTERFACE=$(ls -l /sys/class/net/ | grep $(lspci |grep Mellanox | grep MT27800|head -n1|awk '{print $1}') | awk '{print $9}')
    fi
    echo 0 > /sys/class/net/$SRIOV_INTERFACE/device/sriov_numvfs
    sleep 5

    if [[ -n "$(lsmod | grep rdma_ucm)" ]]; then
        modprobe -r rdma_ucm
        if [ "$?" != "0" ]; then
            echo "Warning: faild to remove the rdma_ucm module"
        fi
        sleep 2
    fi

    if [[ -n "$(lsmod | grep rdma_cm)" ]]; then
        modprobe -r rdma_cm
        if [ "$?" != "0" ]; then
            echo "Warning: Failed to remove rdma_cm module"
        fi
        sleep 2
    fi
    modprobe rdma_cm
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to load rdma_cm module"
        return $status
    fi
    modprobe rdma_ucm
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to load rdma_ucm module"
        return $status
    fi

    return $status
}

function enable_rdma_mode {
    local_mode=$1
    if [[ -z "$(rdma system | grep $local_mode)" ]]; then
        rdma system set netns "$local_mode"
        let status=status+$?
        if [ "$status" != 0 ]; then
            echo "Failed to set rdma to $local_mode mode"
            return $status
        fi
    fi
}

function deploy_calico {
    rm -rf /etc/cni/net.d/00*
    wget https://docs.projectcalico.org/manifests/calico.yaml -P "$ARTIFACTS"/
    kubectl create -f "$ARTIFACTS"/calico.yaml

    wait_pod_state "calico-node" "Running"

    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to set setup calico!"
        return $status
    fi

    sleep 20

    # abdallahyas: Since we know that the calico creates a cni conf file with a name starting 
    # with 10* which should be the first alphabetical file after the deleted 00* file, restarting 
    # the multus pod will make the multus configure the calico as the primary network.
    restart_multus_pod
    return $?
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

    multus_install
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to clone multus!!"
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
    echo "Download ${SRIOV_NETWORK_DEVICE_PLUGIN_REPO}"
    rm -rf $WORKSPACE/sriov-network-device-plugin
    git clone ${SRIOV_NETWORK_DEVICE_PLUGIN_REPO} $WORKSPACE/sriov-network-device-plugin
    pushd $WORKSPACE/sriov-network-device-plugin
    if test ${SRIOV_NETWORK_DEVICE_PLUGIN_PR}; then
        git fetch --tags --progress ${SRIOV_NETWORK_DEVICE_PLUGIN_REPO} +refs/pull/*:refs/remotes/origin/pr/*
        git pull origin pull/${SRIOV_NETWORK_DEVICE_PLUGIN_PR}/head
    elif test ${SRIOV_NETWORK_DEVICE_PLUGIN_BRANCH}; then
        git checkout ${SRIOV_NETWORK_DEVICE_PLUGIN_BRANCH}
    fi
    git log -p -1 > $ARTIFACTS/sriov-network-device-plugin-git.txt
    make build
    let status=status+$?
    make image
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to build ${SRIOV_NETWORK_DEVICE_PLUGIN_REPO} ${SRIOV_NETWORK_DEVICE_PLUGIN_BRANCH} ${SRIOV_NETWORK_DEVICE_PLUGIN_BRANCH}"
        return $status
    fi

    \cp build/* $CNI_BIN_DIR/
    change_k8s_resource "DaemonSet" "kube-sriov-device-plugin-amd64" "spec.template.spec.containers[0].image" "nfvpe/sriov-device-plugin:latest" "./deployments/k8s-v1.16/sriovdp-daemonset.yaml"
    popd
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
    local pod_image=${3:-'mellanox/rping-test'}
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

    local ip_1=$(/usr/local/bin/kubectl exec -t ${POD_NAME_1} -- ifconfig net1|grep inet|awk '{print $2}')
    /usr/local/bin/kubectl exec -i ${POD_NAME_1} -- ifconfig net1
    echo "${POD_NAME_1} has ip ${ip_1}"

    local ip_2=$(/usr/local/bin/kubectl exec -t ${POD_NAME_2} -- ifconfig net1|grep inet|awk '{print $2}')
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
