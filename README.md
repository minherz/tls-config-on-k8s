# Enforce TLS configuration on Kubernetes cluster

Demonstrate a possibility to implement TLS Policy on Kubernetes cluster that enforces TLS protocol version
and cipher suite configuration for all workloads of the cluster including ingress endpoints and pod-to-pod
communications.
The solution uses Istio 1.9 or Google Anthos Service Mesh 1.9.
The solution does not cover workloads that expose HTTPS endpoints themselves and not via Istio/ASM gateways.
