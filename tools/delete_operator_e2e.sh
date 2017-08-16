#!/bin/bash

kubectl delete po/tidb-operator-e2e -n kube-system
kubectl delete tidbcluster/e2e-one -n e2e-ns
kubectl delete ns/e2e-ns
