#!/usr/bin/sh

helm dependency update || helm dependency build 

helm install --namespace observability-stack --create-namespace o11y .
# Helm will complain if it has already been deployed with: Error: INSTALLATION FAILED: cannot re-use a name that is still in use
# if that happens, use helm upgrade