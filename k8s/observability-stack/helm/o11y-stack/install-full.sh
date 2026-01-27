#!/usr/bin/sh

helm dependency update || helm dependency build 

helm install --namespace observability-stack --create-namespace o11y .