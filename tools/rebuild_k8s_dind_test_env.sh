#!/bin/bash -ex


REGISTRY=localhost:5000/pingcap
SOURCE_REGISTRY=uhub.service.ucloud.cn/pingcap
INIT_DEPLOYS="registry-proxy.yaml tidb-operator.yaml tidb-cloud-manager.yaml tidb-volume.yaml"
IMAGES="tidb-tools:latest tidb:latest tikv:latest pd:latest tidb-dashboard-installer:v0.1.0 grafana:4.2.0 prometheus:v1.5.2 pushgateway:v0.3.1"

### change workspace
WORKSPACE=$(cd $(dirname $0)/..; pwd)
cd $WORKSPACE

function rebuild::step {
   local GREEN="\033[0;32m"
   local NC="\033[0m"
   echo -e  ">>> ${GREEN} $@ ${NC}"
}

rebuild::step "start to cleaning k8s dind cluster"

./fixed/dind-cluster-v1.7.sh clean

rebuild::step "start to clean useless images"
docker images|docker images|grep -v kubeadm-dind-cluster|grep -P "tidb-operator|<none>|tidb-cloud-manager"|awk '{print $3}'|xargs -I{} -n1 docker rmi -f {} || true


rebuild::step "start to bringing up k8s dind cluster"

./fixed/dind-cluster-v1.7.sh up

rebuild::step "start to bringing up local registry in k8s cluster"
docker exec kube-master docker run -d --restart=always -v /registry:/var/lib/registry -p5001:5000 --name=registry uhub.service.ucloud.cn/pingcap/registry:2

rebuild::step "start to deploy [${INIT_DEPLOYS}] to k8s cluster"
for deploy in ${INIT_DEPLOYS}
do
	kubectl create -f ./manifests/${deploy}
done

rebuild::step "start push images [${IMAGES}] to ${REGISTRY} registry"
for image in ${IMAGES}
do
    docker pull ${SOURCE_REGISTRY}/${image}
    docker tag ${SOURCE_REGISTRY}/${image} ${REGISTRY}/${image}
    docker push ${REGISTRY}/${image}
done
