#!/usr/bin/sh

#helm dependency update || helm dependency build 

helm upgrade --namespace observability-stack o11y .

sleep 1
# To force a reload of the config map
kubectl rollout restart ds/o11y-alloy