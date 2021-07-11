#!/bin/bash -x

export LOGDIR=$WORKSPACE/logs
export ARTIFACTS=$WORKSPACE/artifacts

export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}

source ./common/common_functions.sh
source ./common/nic_operator_common.sh

function delete_pods {
    for pod in "$(kubectl get pod -o name | cut -d/ -f2)";do
        if [[ "$pod" =~ .*test-pod.* ]];then
            kubectl delete pod "$pod"
        fi
    done
}

function stop_system_deployments {
    kubectl delete deployment -n kube-system --all
}

function stop_system_daemonset {
    for ds in $(kubectl -n kube-system get ds |grep kube|awk '{print $1}'); do
        kubectl -n kube-system delete ds $ds
    done
}

function stop_k8s {
    sudo kubeadm reset -f
}

function stop_kind_cluster {
    local project="$1"

    ./run_kind_ci.sh --project "$project" --phases undeploy-kind
}

function asure_all_stoped {
    kill $(ps -ef |grep local-up-cluster.sh|grep $WORKSPACE|awk '{print $2}')
    kill $(pgrep sriovdp)
    kill $(ps -ef |grep kube |awk '{print $2}')
    kill -9 $(ps -ef |grep etcd|grep http|awk '{print $2}')
    ps -ef |egrep "kube|local-up-cluster|etcd"
}

function delete_all_docker_container {
    sudo docker stop $(sudo docker ps -q)
    sudo docker rm $(sudo docker ps -a -q)
}

function delete_all_docker_images {
    sudo docker rmi $(sudo docker images -q)
}

function delete_chache_files {
    #delete network cache
    sudo rm -rf /var/lib/cni/networks

    [ -d /var/lib/cni/sriov ] && rm -rf /var/lib/cni/sriov/*
}

function clean_tmp_workspaces {
    number_of_all_logs=$(ls -tr /tmp/ | grep k8s | wc -l)
    number_of_logs_to_keep=10
    let number_of_logs_to_clean="$number_of_all_logs"-"$number_of_logs_to_keep"
    echo "number of all logs $number_of_all_logs"
    echo "number of logs to clean $number_of_logs_to_clean"
    
    if [ "$number_of_logs_to_clean" -le 0 ]; then
            echo "no logs to clean"
    else
        logs_to_clean=$(ls -tr /tmp/ | grep k8s | head -n "$number_of_logs_to_clean")
        echo "Cleaning $number_of_logs_to_clean logs, it is these dirs:"
        echo "$logs_to_clean"
        for log in $logs_to_clean; do
            echo "Removing /tmp/$log dir"
            sudo rm -rf /tmp/"$log"
        done
    fi
}

function reset_vfs_guids {
    let status=0

    if [[ -z "$(lspci |grep Mellanox | grep MT27800|head -n1|grep -i infini)" ]];then
        return 0
    fi

    unload_module mlx5_ib
    let status=$status+$?

    unload_module mlx5_core
    let status=$status+$?

    if [[ "$status" != "0" ]]; then
        return "$status"
    fi

    load_core_drivers
    sleep 10

    sudo ip l set ib0 up
    sleep 5
    sudo ip l set ib1 up
    sleep 5
    sudo systemctl restart opensm

    return 0
}

function unload_module {
    local module=$1
    sudo modprobe -r $module
    if [[ "$?" != "0" ]];then
       echo "ERROR: Failed to unload $module module!"
       return 1
    fi
}

function general_cleaning {
    stop_system_deployments

    stop_system_daemonset

    stop_k8s

    asure_all_stoped

    delete_chache_files

    delete_all_docker_container

    delete_all_docker_images

    clean_tmp_workspaces

    collect_services_logs

    delete_cnis_bins_and_confs

    clear_mlnx_vfs
}

function collect_pods_logs {
    local pods_log_dir="${LOGDIR}/pods-logs"
    local pods_info_dir="${LOGDIR}/pods-infos"

    if [[ -f "${LOGDIR}/start-time.log" ]];then

        if [[ -d "$pods_log_dir" ]];then
            sudo rm -rf $pods_log_dir
        fi

        if [[ -d "$pods_info_dir" ]];then
            sudo rm -rf $pods_info_dir
        fi

        mkdir -p $pods_log_dir
        mkdir -p $pods_info_dir

        echo "Collecting all pods logs..."
        kubectl get pods -A -o wide > ${LOGDIR}/pods-last-state.log
        kubectl get daemonsets -A > ${LOGDIR}/daemonsets-last-state.log
	old_IFS=$IFS
	IFS=$'\n'
	for pod in $(kubectl get pods -A -o custom-columns=NAMESACE:.metadata.namespace,NAME:.metadata.name);do
            get_pod_log "$pod" "$pods_log_dir"
            get_pod_info "$pod" "$pods_info_dir"
        done
    else
        echo ""
        echo "No \"${LOGDIR}/start-time.log\", Assuming job did not start."
        echo ""
    fi
    IFS=$old_IFS
}

function collect_nodes_info {
    local nodes_info_dir="${LOGDIR}/nodes-infos"

    if [[ -f "${LOGDIR}/start-time.log" ]];then

        if [[ -d "$nodes_info_dir" ]];then
            sudo rm -rf $nodes_info_dir
        fi

        mkdir -p $nodes_info_dir

        echo "Collecting all nodes info..."
        kubectl get nodes -o wide > ${LOGDIR}/nodes-last-state.log
        old_IFS=$IFS
        IFS=$'\n'
        for node in $(kubectl get nodes -o custom-columns=NAME:.metadata.name);do
            get_node_info "$node" "$nodes_info_dir"
        done
    else
        echo ""
        echo "No \"${LOGDIR}/start-time.log\", Assuming job did not start."
        echo ""
    fi
    IFS=$old_IFS
}

function collect_services_logs {
    if [[ -f "${LOGDIR}/start-time.log" ]];then
        echo "Collecting Services Logs..."
        get_service_log "kubelet"
        get_service_log "docker"
    else
        echo ""
        echo "No \"${LOGDIR}/start-time.log\", Assuming job did not start."
        echo ""
    fi
}

function collect_vf_switcher_logs {
    if [[ -f "${LOGDIR}/start-time.log" ]];then
        echo "Collecting the vf-switcher Logs..."
        get_service_log "vf-switcher"
    else
        echo ""
        echo "No \"${LOGDIR}/start-time.log\", Assuming job did not start."
        echo ""
    fi
}

function get_pod_log {
    pod_line="$1"
    local log_dir="$2"

    pod_namespace="$(awk '{print $1}' <<< ${pod_line})"
    pod_name="$(awk '{print $2}' <<< ${pod_line})"

    echo "Collecting $pod_name logs..."

    kubectl logs -n "$pod_namespace" "$pod_name" > ${log_dir}/${pod_name}.log

    if [[ -f ${log_dir}/${pod_name}.log ]];then
        echo "Logs wrote to ${log_dir}/${pod_name}.log!"
        echo ""
    else
        echo "${log_dir}/${pod_name}.log was not found, writting logs failed!"
        echo ""
    fi
}

function get_pod_info {
    local pod_line="$1"
    local info_dir="$2"

    local pod_namespace="$(awk '{print $1}' <<< ${pod_line})"
    local pod_name="$(awk '{print $2}' <<< ${pod_line})"

    echo "Collecting $pod_name info..."

    kubectl describe pod -n "$pod_namespace" "$pod_name" > ${info_dir}/${pod_name}.log

    if [[ -f ${info_dir}/${pod_name}.log ]];then
        echo "Info wrote to ${info_dir}/${pod_name}.log!"
        echo ""
    else
        echo "${info_dir}/${pod_name}.log was not found, writting info failed!"
        echo ""
    fi
}

function get_node_info {
    local node_line="$1"
    local info_dir="$2"

    local node_name="$(awk '{print $1}' <<< ${node_line})"

    echo "Collecting $node_name info..."

    kubectl describe node "$node_name" > ${info_dir}/${node_name}.log

    if [[ -f ${info_dir}/${node_name}.log ]];then
        echo "Info wrote to ${info_dir}/${node_name}.log!"
        echo ""
    else
        echo "${info_dir}/${node_name}.log was not found, writting info failed!"
        echo ""
    fi
}

function get_service_log {
    service_name="$1"

    echo "Collecting $service_name logs..."

    sudo journalctl -o short-precise --since "$(cat ${LOGDIR}/start-time.log)" --unit $service_name > "${LOGDIR}/${service_name}.log"

    if [[ -f ${LOGDIR}/${service_name}.log ]];then
        echo "Logs wrote to ${LOGDIR}/${service_name}.log!"
        echo ""
    else
        echo "${LOGDIR}/${service_name}.log was not found, writting logs failed!"
        echo ""
    fi
}

function delete_nic_operator_namespace {
    let status=0

    kubectl delete namespace "$(get_nic_operator_resources_namespace)"
    let status=$status+$?

    kubectl delete namespace --wait=false "$(get_nic_operator_namespace)"
    let status=$status+$?

    return $status
}

function delete_nic_cluster_policies {

    local nic_cluster_policy_name="$NIC_OPERATOR_CRD_NAME"

    if [[ -z "$(kubectl get crds | grep $nic_cluster_policy_name)" ]];then
        echo "No CRD named $nic_cluster_policy_name found, assuming  CI did not start!"
        return 0
    fi

    kubectl delete $nic_cluster_policy_name --all --wait=true

    asure_resource_deleted "pods" "$(get_nic_operator_resources_namespace)"

    load_core_drivers
    sleep 5
}

function undeploy_gpu_operator {
    helm uninstall gpu-operator

    asure_resource_deleted "pod" "nvidia-device-plugin-daemonset"
    let status=$status+$?

    asure_resource_deleted "pod" "gpu-operator"
    let status=$status+$?

    asure_resource_deleted "pod" "nvidia-driver-daemonset"
    let status=$status+$?

    return $status
}

function asure_resource_deleted {
    local resource_type="$1"
    local resource_name="$2"

    echo "Waiting for $resource_name to be deleted ...."
    let stop=$(date '+%s')+$TIMEOUT
    d=$(date '+%s')
    while [ $d -lt $stop ]; do
       resource_state=$(kubectl get $resource_type -A | grep $resource_name)
       if [[ -z "$resource_state" ]];then
           echo "$resource_name was deleted successfuly!!"
           sleep 10
           return 0
       fi
       echo "$resource_name is not yet deleted, waiting..."
       sleep $POLL_INTERVAL
       d=$(date '+%s')
    done

    if [ $d -gt $stop ]; then
        echo "ERROR: $resource_name was not deleted after $TIMEOUT seconds!!"
        return 1
    fi
}

function delete_nic_operator {
    echo "Deleting the network operator..."
    local local_status=0

    delete_nic_cluster_policies
    let local_status=$local_status+$?

    delete_nic_operator_namespace
    let local_status=$local_status+$?
    
    return $local_status
}

function delete_cnis_bins_and_confs {
    sudo rm -rf ${CNI_CONF_DIR}/*
    sudo rm -rf ${CNI_BIN_DIR}/*
}

function clear_mlnx_vfs {
    local mlnx_interfaces=$(get_auto_net_device 0)

    local old_IFS=$IFS
    IFS=' '

    for interface in $mlnx_interfaces;do
        sudo create_vfs.sh -i "$interface" -v "0"
    done

    IFS=$old_IFS
}
