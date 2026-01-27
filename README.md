# Homelab: Observability Stacks

Homelab deployment of Observability Stacks using different methods and combinations of tools

- **k8s**:
  - **observability-stack**: Grafana + Victoria Metrics (metrics) + Tempo (traces) + Loki (logs) + Alloy (otel collector)
    - **helm**: deployment using helm chart of helm charts
    - **manifest-based**: deployment using individual yaml manifests for each component


## Requirements

1. kubectl

2. helm

Installing on debian/ubuntu:

```shell
sudo apt-get install curl gpg apt-transport-https --yes
curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
sudo apt-get update
sudo apt-get install helm
```

source: <https://helm.sh/docs/intro/install/>