# Create cluster config for UDP port mapping
cat > kind-config.yaml << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: trading-cluster
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 8888
    protocol: UDP
  - containerPort: 30081
    hostPort: 9999
    protocol: UDP
EOF

# Create the cluster
kind create cluster --config kind-config.yaml