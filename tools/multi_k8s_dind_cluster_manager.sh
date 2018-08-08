#!/bin/bash

SOURCE_REGISTRY=uhub.ucloud.cn/pingcap
INIT_DEPLOYS="registry-proxy.yaml nfs-deployment.yaml nfs-storageclass.yaml"
TIDB_IMAGES="tidb tikv pd"
TILLER_VERSION="v2.8.2"
TIDB_BASE_TAG="v2.0.4"
IMAGES="tidb-tools:latest tidb-dashboard-installer:v1.0.7 grafana:4.2.0 prometheus:v2.0.0 pushgateway:v0.3.1"

REGISTRY_PORT=${REGISTRY_PORT:-5000}
# use nfs provisioner in dind
DIND_USE_NFS_STORAGE="${DIND_USE_NFS_STORAGE:-true}"
# format -> namespace:dind_subnet:apiserver_port:local_registry_port:cloud_manager_port
CLUSTERS=(
e2e-v1.7:10.192.0.0:8080:${REGISTRY_PORT}:32333
stability-v1.7:10.193.0.0:8081:${REGISTRY_PORT}:32334
e2e-v1.8:10.194.0.0:8082:${REGISTRY_PORT}:32335
stability-v1.8:10.195.0.0:8083:${REGISTRY_PORT}:32336
e2e-v1.9:10.196.0.0:8084:${REGISTRY_PORT}:32337
stability-v1.9:10.197.0.0:8085:${REGISTRY_PORT}:32338
e2e-v1.10:10.198.0.0:8085:${REGISTRY_PORT}:32339
stability-v1.10:10.199.0.0:8086:${REGISTRY_PORT}:32340
)

### change workspace
WORKSPACE=$(cd $(dirname $0)/..; pwd)
cd $WORKSPACE

function rebuild::step {
   local green="\033[0;32m"
   local nc="\033[0m"
   echo -e  ">>> ${green} $@ ${nc}"
}

function rebuild::clean_images {
    rebuild::step "start to remove useless images"
    docker images|grep -v kubeadm-dind-cluster|egrep "tidb-operator|<none>|tidb-cloud-manager"|awk '{print $3}'|xargs -I{} -n1 docker rmi -f {} || true
}

function rebuild::start_registry {
    rebuild::step "start to bringing up local registry in k8s dind cluster with namespace $1"
    docker exec $1-kube-master docker run -d --restart=always -v /registry:/var/lib/registry -p5001:5000 --name=registry uhub.ucloud.cn/pingcap/registry:2
}

# the input args: $namespace $field_index
function rebuild::get_info_by_ns {
    local -a results
    local -a cluster_array_info
    for cluster in ${CLUSTERS[@]}
    do
        cluster_array_info=(`echo ${cluster}|awk -F: '{print $1,$2,$3,$4,$5}'`)
        if [[ ${#cluster_array_info[@]} -ne 5 ]]
        then
            echo "Wrong cluster info format: ${cluster}, please check it!!!" 1>&2
            exit 1
        fi
        if [[ $1 == all ]]
        then
            ## collect field infos of all namespace
            results+=(${cluster_array_info[$1]})
        else
            [[ $1 != ${cluster_array_info[0]} ]] && continue
            results+=(${cluster_array_info[$2]})
            break
        fi
    done
    if [[ ${#results[@]} -eq 0 ]]
    then
        echo "Did not find a matching namespace: $1" 1>&2
        exit 1
    fi
    echo ${results[@]}
}

function rebuild::deploy_apps {
    rebuild::step "start to deploy [${INIT_DEPLOYS}] to k8s dind cluster with namespace $1"
    local dind_subnet
    local master_ip

    dind_subnet=$(rebuild::get_info_by_ns $1 1)
    master_ip=$(echo ${dind_subnet}|cut -d. -f1-3).2
    for deploy in ${INIT_DEPLOYS}
    do
        if [[ ${deploy} == "registry-proxy.yaml" ]]
        then
            rebuild::step "start to apply ${deploy}"
            sed "s/10.192.0.2/${master_ip}/g" ./manifests/${deploy}|kubectl apply -f -
            continue
        fi
        if [[ ${deploy} == "nfs-deployment.yaml" || ${deploy} == "nfs-storageclass.yaml" ]]
        then
            if [[ ${DIND_USE_NFS_STORAGE} == "true" ]]
            then
                rebuild::step "start to apply ${deploy}"
                kubectl apply -f ./manifests/${deploy}
            fi
            continue
        fi
        kubectl apply -f ./manifests/${deploy}
    done
    hash helm 2>/dev/null
    if [[ $? -eq 0 ]]
    then
       helm init --tiller-image uhub.ucloud.cn/pingcap/tiller:${TILLER_VERSION}
    fi
}

function rebuild::push_images_to_local {
    local -a cluster_array_info
    local local_registry_port
    local local_registry

    local_registry_port=$(rebuild::get_info_by_ns $1 3)
    local_registry="localhost:${local_registry_port}/pingcap"

    rebuild::step "start push images [${IMAGES}] to  ${local_registry} registry with namespace $1"
    local flag
    for image in ${IMAGES}
    do
        flag=0
        docker pull ${SOURCE_REGISTRY}/${image} || flag=1
        while [[ $flag -eq 1 ]]
        do
            flag=0
            sleep 5
            docker pull ${SOURCE_REGISTRY}/${image} || flag=1
            continue
        done
        docker tag ${SOURCE_REGISTRY}/${image} ${local_registry}/${image}
        docker push ${local_registry}/${image}
    done

    rebuild::step "start push TiDB images [${TIDB_IMAGES}] to ${local_registry} registry with namespace $1"
    for image in ${TIDB_IMAGES}
    do
        flag=0
        docker pull ${SOURCE_REGISTRY}/${image}:${TIDB_BASE_TAG} || flag=1
        while [[ $flag -eq 1 ]]
        do
            flag=0
            sleep 5
            docker pull ${SOURCE_REGISTRY}/${image}:${TIDB_BASE_TAG} || flag=1
            continue
        done
        docker tag ${SOURCE_REGISTRY}/${image}:${TIDB_BASE_TAG} ${local_registry}/${image}:${TIDB_BASE_TAG}
        docker tag ${SOURCE_REGISTRY}/${image}:${TIDB_BASE_TAG} ${local_registry}/${image}:master
        docker push ${local_registry}/${image}:${TIDB_BASE_TAG}
        docker push ${local_registry}/${image}:master
    done
}

function rebuild::get_all_ns_info {
    echo $(rebuild::get_info_by_ns all 0)|tr ' ' '|'
}

function rebuild::down_cluster {
    rebuild::step "start to down k8s dind cluster with namespace $1"
    local kube_version
    kube_version=`echo $1|awk -F- '{print $NF}'`
    docker ps -a -q --filter=label=$1.kubeadm_dind_cluster|xargs -I {} -n1 docker stop {}
}

function rebuild::clean_cluster {
    rebuild::step "start to clean k8s dind cluster with namespace $1"
    export DIND_NAMESPACE=$1
    local kube_version
    kube_version=`echo ${DIND_NAMESPACE}|awk -F- '{print $NF}'`
    ./fixed/dind-cluster-${kube_version}.sh clean
}

# the input args: $namespace $dind_subnet $apiserver_port $local_registry_port $cloud_manager_port
function rebuild::up_dind {
    rebuild::step "start to bringing up k8s dind cluster with namespace $1"
    docker ps -a -q --filter=label=$1.kubeadm_dind_cluster|xargs -I {} -n1 docker start {}
}

function rebuild::up_cluster {
    local ns=${1:-}
    if [[ ! ${ns} ]]
    then
        echo "You should specify the cluster's namespace" 1>&2
        exit 1
    fi
    local namespace
    local dind_subnet
    local apiserver_port
    local local_registry_port
    local cloud_manager_port
    local kube_version
    local -a cluster_array_info

    for cluster in ${CLUSTERS[@]}
    do
        cluster_array_info=(`echo ${cluster}|awk -F: '{print $1,$2,$3,$4,$5}'`)
        [[ ${#cluster_array_info[@]} -ne 5 ]] && echo "Wrong cluster info format: ${cluster}, please check it!!!" 1>&2

        namespace=${cluster_array_info[0]}
        [[ ${namespace} != ${ns} ]] && continue
        dind_subnet=${cluster_array_info[1]}
        apiserver_port=${cluster_array_info[2]}
        local_registry_port=${cluster_array_info[3]}
        cloud_manager_port=${cluster_array_info[4]}
        break
    done
    if [[ ! ${dind_subnet} ]]
    then
        echo "The input namespace ${ns} does not match the built-in namespaces $(rebuild::get_all_ns_info)" 1>&2
        exit 1
    fi
    rebuild::step "start to up k8s dind cluster with namespace ${namespace}"
    export DIND_NAMESPACE=${namespace}
    export DIND_SUBNET=${dind_subnet}
    export APISERVER_PORT=${apiserver_port}
    export REGISTRY_PORT=${local_registry_port}
    export CLOUD_MANAGER_PORT=${cloud_manager_port}
    kube_version=`echo ${namespace}|awk -F- '{print $NF}'`
    ./fixed/dind-cluster-${kube_version}.sh up
}

function rebuild::rebuild_cluster {
    rebuild::step "start to rebuild k8s dind cluster with namespace $1"
    rebuild::clean_cluster $1
    rebuild::clean_images
    rebuild::up_cluster $1
    rebuild::start_registry $1
    rebuild::deploy_apps $1
}

function rebuild::help {
    echo "usage:" 1>&2
    echo "  $0 rebuild namespace" 1>&2
    echo "  $0 clean namespace" 1>&2
    echo "  $0 up namespace" 1>&2
    echo "  $0 down namespace" 1>&2
    echo "  $0 push namespace" 1>&2
    echo "The possible namespace values are: $(rebuild::get_all_ns_info)" 1>&2
    exit 1
}

[[ $# -ne 2 ]] && rebuild::help

case "${1:-}" in
    rebuild)
        rebuild::rebuild_cluster $2
        ;;
    clean)
        rebuild::clean_cluster $2
        ;;
    up)
        rebuild::up_dind $2
        ;;
    down)
        rebuild::down_cluster $2
        ;;
    push)
        rebuild::push_images_to_local $2
        ;;
    *)
        rebuild::help
    ;;
esac
