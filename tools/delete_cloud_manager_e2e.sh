#!/bin/bash

kubectl delete po/tidb-cloud-manager-e2e -n kube-system
cluster=${1:-tidb-cloud-manager-e2e}
docker exec kube-master curl -X DELETE --header 'Accept: application/json' http://127.0.0.1:32333/pingcap.com/api/v1/clusters/$cluster
