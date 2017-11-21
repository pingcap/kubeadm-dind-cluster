#!/bin/bash -e

SOURCE_REGISTRY=uhub.ucloud.cn/pingcap
INIT_DEPLOYS="registry-proxy.yaml"
TIDB_IMAGES="tidb tikv pd"
TIDB_BASE_TAG="v1.0.0"
IMAGES="tidb-tools:latest tidb-dashboard-installer:v1.0.0 grafana:4.2.0 prometheus:v1.5.2 pushgateway:v0.3.1"

# format -> namespace:dind_subnet:apiserver_port:local_registry_port:cloud_manager_port
CLUSTERS=(
e2e-v1.7:10.192.0.0:8080:5000:32333
stability-v1.7:10.193.0.0:8081:5001:32334
e2e-v1.8:10.194.0.0:8082:5002:32335
stability-v1.8:10.195.0.0:8083:5003:32336
)

### change workspace
WORKSPACE=$(cd $(dirname $0)/..; pwd)
cd $WORKSPACE

function rebuild::step {
   local GREEN="\033[0;32m"
   local NC="\033[0m"
   echo -e  ">>> ${GREEN} $@ ${NC}"
}

function rebuild::clean_dind {
    rebuild::step "start to cleaning k8s dind cluster with namespace $1"
    export DIND_NAMESPACE=$1
    local KUBE_VERSION
    KUBE_VERSION=`echo ${DIND_NAMESPACE}|awk -F- '{print $NF}'`
    ./fixed/dind-cluster-${KUBE_VERSION}.sh clean
}

function rebuild::clean_images {
    rebuild::step "start to clean useless images"
    docker images|docker images|grep -v kubeadm-dind-cluster|egrep "tidb-operator|<none>|tidb-cloud-manager"|awk '{print $3}'|xargs -I{} -n1 docker rmi -f {} || true
}

# the input args: $namespace $dind_subnet $apiserver_port $local_registry_port $cloud_manager_port
function rebuild::up_dind {
    rebuild::step "start to bringing up k8s dind cluster with namespace $1"
    export DIND_NAMESPACE=$1
    export DIND_SUBNET=$2
    export APISERVER_PORT=$3
    export REGISTRY_PORT=$4
    export CLOUD_MANAGER_PORT=$5
    local KUBE_VERSION
    KUBE_VERSION=`echo ${DIND_NAMESPACE}|awk -F- '{print $NF}'`
    ./fixed/dind-cluster-${KUBE_VERSION}.sh up
}

function rebuild::start_registry {
    rebuild::step "start to bringing up local registry in k8s dind cluster with namespace $1"
    docker exec $1-kube-master docker run -d --restart=always -v /registry:/var/lib/registry -p5001:5000 --name=registry uhub.ucloud.cn/pingcap/registry:2
}

function rebuild::deploy_apps {
    rebuild::step "start to deploy [${INIT_DEPLOYS}] to k8s dind cluster with namespace $1"
    for deploy in ${INIT_DEPLOYS}
    do
       ./tools/clusters/kubectl.$1 create -f ./manifests/${deploy}
    done
}

function rebuild::push_images_to_local {
    local -a cluster_array_info
    local LOCAL_REGISTRY_PORT
    local LOCAL_REGISTRY
    local index=0
    for cluster in ${CLUSTERS[@]}
    do
        cluster_array_info=(`echo ${cluster}|awk -F: '{print $1,$2,$3,$4,$5}'`)
        [[ ${#cluster_array_info[@]} -ne 5 ]] && echo "Wrong cluster info format: ${cluster}, please check it!!!" 1>&2

        [[ $1 != ${cluster_array_info[$index]} ]] && continue
        LOCAL_REGISTRY_PORT=${cluster_array_info[$index+3]}
        break
    done
    if [[ ! ${LOCAL_REGISTRY_PORT} ]]
    then
        echo "Did not find a matching namespace: $1" 1>&2
        exit 1
    fi
    LOCAL_REGISTRY="localhost:${LOCAL_REGISTRY_PORT}/pingcap"

    rebuild::step "start push images [${IMAGES}] to  ${LOCAL_REGISTRY} registry with namespace $1"
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
        docker tag ${SOURCE_REGISTRY}/${image} ${LOCAL_REGISTRY}/${image}
        docker push ${LOCAL_REGISTRY}/${image}
    done

    rebuild::step "start push TiDB images [${TIDB_IMAGES}] to ${LOCAL_REGISTRY} registry with namespace $1"
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
        docker tag ${SOURCE_REGISTRY}/${image}:${TIDB_BASE_TAG} ${LOCAL_REGISTRY}/${image}:${TIDB_BASE_TAG}
        docker tag ${SOURCE_REGISTRY}/${image}:${TIDB_BASE_TAG} ${LOCAL_REGISTRY}/${image}:master
        docker push ${LOCAL_REGISTRY}/${image}:${TIDB_BASE_TAG}
        docker push ${LOCAL_REGISTRY}/${image}:master
    done
}

function rebuild::get_ns_info {
    local -a ns_array
    local -a cluster_array_info
    local index=0
    for cluster in ${CLUSTERS[@]}
    do
        cluster_array_info=(`echo ${cluster}|awk -F: '{print $1,$2,$3,$4,$5}'`)
        [[ ${#cluster_array_info[@]} -ne 5 ]] && echo "Wrong cluster info format: ${cluster}, please check it!!!" 1>&2

        ns_array+=(${cluster_array_info[$index]})
    done
    echo ${ns_array[@]}|tr ' ' '|'
}

# namespace:dind_subnet:apiserver_port:local_registry_port:cloud_manager_port
function rebuild::launch_cluster {
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
    local -a cluster_array_info

    local index=0
    for cluster in ${CLUSTERS[@]}
    do
        cluster_array_info=(`echo ${cluster}|awk -F: '{print $1,$2,$3,$4,$5}'`)
        [[ ${#cluster_array_info[@]} -ne 5 ]] && echo "Wrong cluster info format: ${cluster}, please check it!!!" 1>&2

        namespace=${cluster_array_info[$index]}
        [[ ${namespace} != ${ns} ]] && continue
        dind_subnet=${cluster_array_info[$index+1]}
        apiserver_port=${cluster_array_info[$index+2]}
        local_registry_port=${cluster_array_info[$index+3]}
        cloud_manager_port=${cluster_array_info[$index+4]}
        break
    done
    if [[ ! ${dind_subnet} ]]
    then
        echo "The input namespace ${ns} does not match the built-in namespaces `rebuild::get_ns_info`" 1>&2
        exit 1
    fi
    rebuild::step "start to launch k8s dind cluster with namespace ${namespace}"
    rebuild::clean_dind ${namespace}
    rebuild::clean_images
    rebuild::up_dind ${namespace} ${dind_subnet} ${apiserver_port} ${local_registry_port} ${cloud_manager_port}
    rebuild::start_registry ${namespace}
    rebuild::deploy_apps ${namespace}
}

case "${1:-}" in
    rebuild)
        rebuild::launch_cluster $2
        ;;
    push)
        rebuild::push_images_to_local $2
        ;;
    *)
        echo "usage:" 1>&2
        echo "  $0 rebuild namespace" 1>&2
        echo "  $0 push namespace" 1>&2
        echo "The possible namespace values are: `rebuild::get_ns_info`" 1>&2
        exit 1
    ;;
esac
