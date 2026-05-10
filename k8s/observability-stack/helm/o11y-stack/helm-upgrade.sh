#!/usr/bin/sh

# Make sure updates are done in values.yaml
helm upgrade --namespace observability-stack o11y .

sleep 1
# To force a reload of the config map
kubectl -n observability-stack rollout restart daemonset/o11y-alloy
