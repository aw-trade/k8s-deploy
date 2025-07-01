#!/bin/bash

# Complete script to install Argo Events and Argo Workflows for trading cluster
# Fixed version with proper configuration and troubleshooting

set -e

print_status() {
    echo -e "\033[0;34m[INFO]\033[0m $1"
}

print_success() {
    echo -e "\033[0;32m[SUCCESS]\033[0m $1"
}

print_error() {
    echo -e "\033[0;31m[ERROR]\033[0m $1"
}

print_warning() {
    echo -e "\033[0;33m[WARNING]\033[0m $1"
}

# Check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed or not in PATH"
        exit 1
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        print_error "kubectl cannot connect to cluster"
        exit 1
    fi
    
    if ! command -v curl &> /dev/null; then
        print_warning "curl not found - some connectivity tests will be skipped"
    fi
    
    print_success "Prerequisites check passed"
}

# Clean up any existing installations
cleanup_existing() {
    print_status "Cleaning up any existing Argo installations..."
    
    # Clean up existing argo-server deployments that might have config issues
    if kubectl get deployment argo-server -n argo &>/dev/null; then
        print_status "Removing existing argo-server deployment..."
        kubectl delete deployment argo-server -n argo --ignore-not-found=true
    fi
    
    # Force remove any stuck pods
    kubectl delete pods -n argo -l app=argo-server --force --grace-period=0 &>/dev/null || true
    
    # Wait for cleanup
    sleep 5
    
    print_status "Cleanup completed"
}

# Install Argo Events
install_argo_events() {
    print_status "Installing Argo Events..."
    
    # Create namespace
    kubectl create namespace argo-events --dry-run=client -o yaml | kubectl apply -f -
    
    # Install Argo Events CRDs and controllers
    if kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-events/stable/manifests/install.yaml; then
        print_status "Argo Events installed via stable manifests"
    else
        print_status "Trying alternative installation method..."
        kubectl apply -f https://github.com/argoproj/argo-events/releases/download/v1.9.1/install.yaml
    fi
    
    # Wait for CRDs to be established
    print_status "Waiting for Argo Events CRDs to be established..."
    sleep 15
    
    # Wait for deployments to be ready
    print_status "Waiting for Argo Events deployments to be ready..."
    kubectl wait --for=condition=Available deployment --all -n argo-events --timeout=300s
    
    print_success "Argo Events installed successfully!"
}

# Install Argo Workflows with proper configuration
install_argo_workflows() {
    print_status "Installing Argo Workflows..."
    
    # Create namespace
    kubectl create namespace argo --dry-run=client -o yaml | kubectl apply -f -
    
    # Try the complete installation first (includes CRDs, RBAC, and deployments)
    print_status "Installing Argo Workflows complete manifest..."
    if kubectl apply -n argo -f https://github.com/argoproj/argo-workflows/releases/download/v3.5.4/install.yaml; then
        print_status "Complete installation successful, will override deployments with correct config"
        
        # Wait for CRDs to be established
        print_status "Waiting for CRDs to be established..."
        sleep 20
        
        # Remove the problematic argo-server deployment to replace it
        kubectl delete deployment argo-server -n argo --ignore-not-found=true
        
    else
        print_error "Complete installation failed, trying minimal CRD installation..."
        
        # Fallback: Install only the essential CRDs that work
        print_status "Installing essential CRDs only..."
        kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-workflows/v3.5.4/manifests/base/crds/minimal/argoproj.io_workflows.yaml
        kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-workflows/v3.5.4/manifests/base/crds/minimal/argoproj.io_workflowtemplates.yaml
        kubectl apply -f https://raw.githubusercontent.com/argoproj/argo-workflows/v3.5.4/manifests/base/crds/minimal/argoproj.io_cronworkflows.yaml
        
        # Wait for CRDs to be established
        print_status "Waiting for essential CRDs to be established..."
        sleep 15
    fi
    
    # Create service accounts first (if not already created by complete install)
    create_service_accounts
    
    # Create workflow controller deployment (if not already created)
    if ! kubectl get deployment workflow-controller -n argo &>/dev/null; then
        print_status "Creating workflow controller..."
        cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: workflow-controller
  namespace: argo
  labels:
    app: workflow-controller
spec:
  replicas: 1
  selector:
    matchLabels:
      app: workflow-controller
  template:
    metadata:
      labels:
        app: workflow-controller
    spec:
      serviceAccountName: argo
      containers:
      - name: workflow-controller
        image: quay.io/argoproj/workflow-controller:v3.5.4
        args:
        - --configmap=workflow-controller-configmap
        - --executor-image=quay.io/argoproj/argoexec:v3.5.4
        env:
        - name: ARGO_NAMESPACE
          valueFrom:
            fieldRef:
              apiVersion: v1
              fieldPath: metadata.namespace
        - name: LEADER_ELECTION_IDENTITY
          valueFrom:
            fieldRef:
              apiVersion: v1
              fieldPath: metadata.name
        livenessProbe:
          httpGet:
            path: /healthz
            port: 6060
          initialDelaySeconds: 90
          periodSeconds: 60
        resources:
          requests:
            cpu: 100m
            memory: 64Mi
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
          readOnlyRootFilesystem: true
          runAsNonRoot: true
EOF
    else
        print_status "Workflow controller already exists, skipping creation"
    fi
    
    # Create argo-server deployment with CORRECT configuration
    print_status "Creating argo-server with proper HTTP configuration..."
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: argo-server
  namespace: argo
  labels:
    app: argo-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: argo-server
  template:
    metadata:
      labels:
        app: argo-server
    spec:
      serviceAccountName: argo-server
      containers:
      - name: argo-server
        image: quay.io/argoproj/argocli:v3.5.4
        ports:
        - containerPort: 2746
        args:
        - server
        - --auth-mode=server
        - --secure=false
        env:
        - name: ARGO_NAMESPACE
          valueFrom:
            fieldRef:
              apiVersion: v1
              fieldPath: metadata.namespace
        readinessProbe:
          httpGet:
            path: /
            port: 2746
            scheme: HTTP
          initialDelaySeconds: 10
          periodSeconds: 20
        livenessProbe:
          httpGet:
            path: /
            port: 2746
            scheme: HTTP
          initialDelaySeconds: 30
          periodSeconds: 30
EOF
    
    # Create argo-server service (if not already created)
    if ! kubectl get svc argo-server -n argo &>/dev/null; then
        print_status "Creating argo-server service..."
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: argo-server
  namespace: argo
  labels:
    app: argo-server
spec:
  ports:
  - name: web
    port: 2746
    protocol: TCP
    targetPort: 2746
  selector:
    app: argo-server
EOF
    else
        print_status "argo-server service already exists, skipping creation"
    fi
    
    # Wait for workflow-controller to be ready first
    if kubectl get deployment workflow-controller -n argo &>/dev/null; then
        print_status "Waiting for workflow controller to be ready..."
        kubectl wait --for=condition=Available deployment/workflow-controller -n argo --timeout=300s
    fi
    
    # Wait for argo-server to be ready
    print_status "Waiting for argo-server to be ready..."
    kubectl wait --for=condition=Available deployment/argo-server -n argo --timeout=300s
    
    print_success "Argo Workflows installed successfully!"
}

# Create service accounts and RBAC
create_service_accounts() {
    print_status "Creating service accounts and RBAC..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argo
  namespace: argo
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argo-server
  namespace: argo
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argo-workflow-sa
  namespace: trading-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argo-events-sa
  namespace: trading-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argo-workflow-cluster-role
rules:
- apiGroups: ["argoproj.io"]
  resources: ["workflows", "workflowtemplates", "cronworkflows", "clusterworkflowtemplates"]
  verbs: ["create", "get", "list", "watch", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["pods", "pods/log", "services", "endpoints"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["secrets", "configmaps"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argo-workflow-cluster-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: argo-workflow-cluster-role
subjects:
- kind: ServiceAccount
  name: argo-workflow-sa
  namespace: trading-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argo-events-cluster-role
rules:
- apiGroups: ["argoproj.io"]
  resources: ["workflows", "workflowtemplates"]
  verbs: ["create", "get", "list", "watch", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argo-events-cluster-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: argo-events-cluster-role
subjects:
- kind: ServiceAccount
  name: argo-events-sa
  namespace: trading-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argo-server-cluster-role
rules:
- apiGroups: [""]
  resources: ["configmaps", "events"]
  verbs: ["get", "watch", "list"]
- apiGroups: [""]
  resources: ["pods", "pods/exec", "pods/log"]
  verbs: ["get", "list", "watch", "delete"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["argoproj.io"]
  resources: ["workflows", "workflowtemplates", "workflowtasksets", "cronworkflows", "clusterworkflowtemplates"]
  verbs: ["create", "get", "list", "watch", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argo-server-cluster-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: argo-server-cluster-role
subjects:
- kind: ServiceAccount
  name: argo-server
  namespace: argo
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argo-cluster-role
rules:
- apiGroups: [""]
  resources: ["pods", "pods/exec"]
  verbs: ["create", "get", "list", "watch", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "watch", "list"]
- apiGroups: [""]
  resources: ["persistentvolumeclaims"]
  verbs: ["create", "delete", "get"]
- apiGroups: ["argoproj.io"]
  resources: ["workflows", "workflows/finalizers"]
  verbs: ["get", "list", "watch", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argo-cluster-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: argo-cluster-role
subjects:
- kind: ServiceAccount
  name: argo
  namespace: argo
EOF

    print_success "Service accounts and RBAC configured!"
}

# Create external access services
create_external_access() {
    print_status "Creating external access services..."
    
    # NodePort service for Argo UI (as fallback)
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: argo-server-nodeport
  namespace: argo
  labels:
    app: argo-server
spec:
  type: NodePort
  ports:
  - port: 2746
    targetPort: 2746
    nodePort: 30746
    name: web
  selector:
    app: argo-server
EOF

    print_success "External access services created!"
}

# Create a test workflow
create_test_workflow() {
    print_status "Creating test workflow..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: hello-trading-
  namespace: argo
  labels:
    app: trading-system-test
spec:
  entrypoint: hello
  templates:
  - name: hello
    container:
      image: alpine:latest
      command: [sh, -c]
      args: ["echo 'Trading system test workflow completed successfully! $(date)'"]
EOF

    print_success "Test workflow created!"
}

# Test internal connectivity
test_internal_connectivity() {
    print_status "Testing internal connectivity to argo-server..."
    
    # Wait a moment for the server to be fully ready
    sleep 10
    
    # Test internal connectivity
    if kubectl run connectivity-test --image=curlimages/curl -i --rm --restart=Never --timeout=30s -- curl -s -o /dev/null -w "%{http_code}" http://argo-server.argo.svc.cluster.local:2746/ | grep -q "200"; then
        print_success "Internal connectivity test passed - argo-server is responding correctly!"
        return 0
    else
        print_warning "Internal connectivity test failed - checking server logs..."
        kubectl logs -n argo -l app=argo-server --tail=10
        return 1
    fi
}

# Setup port forwarding helper
setup_port_forward() {
    print_status "Setting up port forwarding helper..."
    
    # Kill any existing port forwards
    pkill -f "kubectl.*port-forward.*argo" 2>/dev/null || true
    sleep 2
    
    print_status "To access the Argo UI, run one of these commands:"
    echo ""
    echo "  # Method 1: Standard port forward"
    echo "  kubectl port-forward -n argo svc/argo-server 2746:2746"
    echo "  # Then open: http://localhost:2746"
    echo ""
    echo "  # Method 2: Alternative port"
    echo "  kubectl port-forward -n argo svc/argo-server 8080:2746"
    echo "  # Then open: http://localhost:8080"
    echo ""
    echo "  # Method 3: NodePort (if kind port mapping configured)"
    echo "  # Open: http://localhost:30746"
    echo ""
}

# Verify installation
verify_installation() {
    print_status "Verifying installation..."
    
    print_status "Argo Events pods:"
    kubectl get pods -n argo-events
    
    print_status "Argo Workflows pods:"
    kubectl get pods -n argo
    
    print_status "Argo services:"
    kubectl get svc -n argo
    
    # Verify argo-server configuration
    print_status "Verifying argo-server configuration..."
    local server_args=$(kubectl get deployment argo-server -n argo -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null || echo "[]")
    print_status "argo-server args: $server_args"
    
    # Check logs for proper startup
    print_status "Recent argo-server logs:"
    kubectl logs -n argo -l app=argo-server --tail=5
    
    # Test connectivity
    if test_internal_connectivity; then
        print_success "✅ Installation verification completed successfully!"
        return 0
    else
        print_error "❌ Installation verification failed - check logs above"
        return 1
    fi
}

# Troubleshooting function
print_troubleshooting_info() {
    echo ""
    print_status "=== TROUBLESHOOTING INFORMATION ==="
    echo ""
    
    print_status "If you encounter 'ERR_CONNECTION_REFUSED':"
    echo "1. Kill existing port forwards: pkill -f 'kubectl.*port-forward'"
    echo "2. Try a different port: kubectl port-forward -n argo svc/argo-server 8080:2746"
    echo "3. Check if port is in use: lsof -i :2746"
    echo ""
    
    print_status "Check installation status:"
    echo "kubectl get pods -n argo"
    echo "kubectl get pods -n argo-events" 
    echo "kubectl logs -n argo -l app=argo-server"
    echo ""
    
    print_status "Test internal connectivity:"
    echo "kubectl run test --image=curlimages/curl -i --rm --restart=Never -- curl -v http://argo-server.argo.svc.cluster.local:2746/"
    echo ""
    
    print_status "Manual argo-server restart:"
    echo "kubectl delete pod -n argo -l app=argo-server"
    echo ""
}

# Main installation flow
main() {
    print_status "=== COMPLETE ARGO TRADING CLUSTER SETUP ==="
    print_status "This script will install Argo Events and Argo Workflows with proper configuration"
    echo ""
    
    # Run installation steps
    check_prerequisites
    
    # Create trading-system namespace
    kubectl create namespace trading-system --dry-run=client -o yaml | kubectl apply -f -
    
    cleanup_existing
    install_argo_events
    install_argo_workflows
    create_external_access
    create_test_workflow
    
    # Verify everything works
    if verify_installation; then
        print_success "🎉 TRADING CLUSTER SETUP COMPLETE!"
        echo ""
        print_status "=== NEXT STEPS ==="
        setup_port_forward
        echo ""
        print_status "To deploy your trading manifests:"
        echo "kubectl apply -f k8s-argo-trading-manifests.yaml"
        echo ""
        print_status "To test webhook triggers:"
        echo "curl -X POST http://localhost:30090/start-algorithm"
        echo "curl -X POST http://localhost:30091/start-simulator"
        echo ""
    else
        print_error "Installation completed but verification failed"
        print_troubleshooting_info
        exit 1
    fi
    
    print_troubleshooting_info
}

# Run the complete setup
main "$@"