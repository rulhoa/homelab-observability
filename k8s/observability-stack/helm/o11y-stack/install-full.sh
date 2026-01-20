#!/usr/bin/sh

helm dependency update || helm dependency build 

helm upgrade --namespace observability-stack o11y .