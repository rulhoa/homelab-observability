# Homelab: Observability Stacks

Homelab deployment of Observability Stacks using different methods and combinations of tools

- **k8s**:
  - **observability-stack**: Grafana + Victoria Metrics (metrics) + Tempo (traces) + Loki (logs) + Alloy (otel collector)
    - **helm**: deployment using helm chart of helm charts
    - **manifest-based**: deployment using individual yaml manifests for each component
