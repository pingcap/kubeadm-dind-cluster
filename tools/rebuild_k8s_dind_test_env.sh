#!/bin/bash -e


REGISTRY=localhost:5000/pingcap
SOURCE_REGISTRY=uhub.service.ucloud.cn/pingcap
INIT_DEPLOYS="registry-proxy.yaml"
TIDB_IMAGES="tidb tikv pd"
IMAGES="tidb-tools:latest tidb-dashboard-installer:v0.1.0 grafana:4.2.0 prometheus:v1.5.2 pushgateway:v0.3.1"

### change workspace
WORKSPACE=$(cd $(dirname $0)/..; pwd)
cd $WORKSPACE

function rebuild::step {
   local GREEN="\033[0;32m"
   local NC="\033[0m"
   echo -e  ">>> ${GREEN} $@ ${NC}"
}

function rebuild::clean_dind {
    rebuild::step "start to cleaning k8s dind cluster"
    ./fixed/dind-cluster-v1.7.sh clean
}

function rebuild::clean_images {
    rebuild::step "start to clean useless images"
    docker images|docker images|grep -v kubeadm-dind-cluster|egrep "tidb-operator|<none>|tidb-cloud-manager"|awk '{print $3}'|xargs -I{} -n1 docker rmi -f {} || true
}

function rebuild::up_dind {
    rebuild::step "start to bringing up k8s dind cluster"
    ./fixed/dind-cluster-v1.7.sh up
}

function rebuild::start_registry {
    rebuild::step "start to bringing up local registry in k8s cluster"
    docker exec kube-master docker run -d --restart=always -v /registry:/var/lib/registry -p5001:5000 --name=registry uhub.service.ucloud.cn/pingcap/registry:2
}

function rebuild::deploy_apps {
    rebuild::step "start to deploy [${INIT_DEPLOYS}] to k8s cluster"
    for deploy in ${INIT_DEPLOYS}
    do
       kubectl create -f ./manifests/${deploy}
    done
}

function rebuild::push_images_to_local {
    rebuild::step "start push images [${IMAGES}] to ${REGISTRY} registry"
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
        docker tag ${SOURCE_REGISTRY}/${image} ${REGISTRY}/${image}
        docker push ${REGISTRY}/${image}
    done

    rebuild::step "start push TiDB images [${TIDB_IMAGES}] to ${REGISTRY} registry"
    for image in ${TIDB_IMAGES}
    do
        flag=0
        docker pull ${SOURCE_REGISTRY}/${image}:latest || flag=1
        while [[ $flag -eq 1 ]]
        do
            flag=0
            sleep 5
            docker pull ${SOURCE_REGISTRY}/${image}:latest || flag=1
            continue
        done
        docker tag ${SOURCE_REGISTRY}/${image}:latest ${REGISTRY}/${image}:latest
        docker tag ${SOURCE_REGISTRY}/${image}:latest ${REGISTRY}/${image}:master
        docker push ${REGISTRY}/${image}:latest
        docker push ${REGISTRY}/${image}:master
    done
}

case "${1:-rebuild}" in
    rebuild)
        rebuild::clean_dind
        rebuild::clean_images
        rebuild::up_dind
        rebuild::start_registry
        rebuild::deploy_apps
        rebuild::push_images_to_local
        ;;
    push)
        rebuild::push_images_to_local
        ;;
    *)
        echo "usage:" >&2
        echo "  $0 rebuild" >&2
        echo "  $0 push" >&2
        exit 1
    ;;
esac
