#!/bin/bash

# Kubernetes Troubleshooting Script for Trading Services
# This script helps diagnose deployment issues

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "\n${BLUE}$1${NC}"
    echo "$(printf '=%.0s' {1..50})"
}

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check cluster status
check_cluster() {
    print_header "🔍 Checking Cluster Status"
    
    echo -e "${BLUE}Cluster Info:${NC}"
    kubectl cluster-info
    
    echo -e "\n${BLUE}Node Status:${NC}"
    kubectl get nodes -o wide
    
    echo -e "\n${BLUE}Cluster Resources:${NC}"
    kubectl top nodes 2>/dev/null || echo "Metrics server not available"
}

# Check namespace and basic resources
check_namespace() {
    print_header "📦 Checking Trading System Namespace"
    
    if kubectl get namespace trading-system &>/dev/null; then
        print_status "Namespace 'trading-system' exists"
        
        echo -e "\n${BLUE}All resources in trading-system:${NC}"
        kubectl get all -n trading-system
        
        echo -e "\n${BLUE}ConfigMaps:${NC}"
        kubectl get configmaps -n trading-system
        
        echo -e "\n${BLUE}Network Policies:${NC}"
        kubectl get networkpolicies -n trading-system 2>/dev/null || echo "No network policies found"
    else
        print_error "Namespace 'trading-system' does not exist"
        return 1
    fi
}

# Check Docker images
check_images() {
    print_header "🐳 Checking Docker Images"
    
    IMAGES=("market-streamer:latest" "trading-algorithm:latest" "trading-simulator:latest")
    
    echo -e "${BLUE}Available Docker images:${NC}"
    docker images | grep -E "(market-streamer|trading-algorithm|trading-simulator|REPOSITORY)"
    
    echo -e "\n${BLUE}Checking required images:${NC}"
    for image in "${IMAGES[@]}"; do
        if docker images --format "table {{.Repository}}:{{.Tag}}" | grep -q "$image"; then
            print_status "✅ Found: $image"
        else
            print_error "❌ Missing: $image"
        fi
    done
    
    # Check if images are loaded in kind
    if kubectl config current-context | grep -q "kind"; then
        echo -e "\n${BLUE}Images in kind cluster:${NC}"
        for image in "${IMAGES[@]}"; do
            if docker exec -it kind-control-plane crictl images | grep -q "${image%:*}"; then
                print_status "✅ Loaded in kind: $image"
            else
                print_error "❌ Not loaded in kind: $image"
                echo "  Run: kind load docker-image $image"
            fi
        done
    fi
}

# Detailed pod diagnostics
check_pods() {
    print_header "🔍 Detailed Pod Diagnostics"
    
    echo -e "${BLUE}Pod Status:${NC}"
    kubectl get pods -n trading-system -o wide
    
    echo -e "\n${BLUE}Pod Events:${NC}"
    kubectl get events -n trading-system --sort-by='.lastTimestamp'
    
    # Check each deployment specifically
    for deployment in market-streamer trading-algorithm trading-simulator; do
        echo -e "\n${BLUE}=== $deployment Diagnostics ===${NC}"
        
        if kubectl get deployment $deployment -n trading-system &>/dev/null; then
            echo -e "\n${YELLOW}Deployment Status:${NC}"
            kubectl get deployment $deployment -n trading-system -o wide
            
            echo -e "\n${YELLOW}ReplicaSet Status:${NC}"
            kubectl get replicaset -n trading-system -l app=$deployment
            
            echo -e "\n${YELLOW}Pod Details:${NC}"
            kubectl get pods -n trading-system -l app=$deployment -o wide
            
            # Get pod logs if pod exists
            POD_NAME=$(kubectl get pods -n trading-system -l app=$deployment -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
            if [ ! -z "$POD_NAME" ] && [ "$POD_NAME" != "" ]; then
                echo -e "\n${YELLOW}Pod Logs (last 20 lines):${NC}"
                kubectl logs $POD_NAME -n trading-system --tail=20 || echo "No logs available yet"
                
                echo -e "\n${YELLOW}Pod Description:${NC}"
                kubectl describe pod $POD_NAME -n trading-system
            else
                echo -e "\n${YELLOW}No pods found for $deployment${NC}"
                echo -e "\n${YELLOW}Deployment Description:${NC}"
                kubectl describe deployment $deployment -n trading-system
            fi
        else
            print_error "Deployment $deployment not found"
        fi
    done
}

# Check services and networking
check_networking() {
    print_header "🌐 Checking Services and Networking"
    
    echo -e "${BLUE}Services:${NC}"
    kubectl get services -n trading-system -o wide
    
    echo -e "\n${BLUE}Endpoints:${NC}"
    kubectl get endpoints -n trading-system
    
    # Check if services are reachable
    echo -e "\n${BLUE}Service Connectivity Test:${NC}"
    
    # Test from within cluster using a temporary pod
    cat << 'EOF' > /tmp/netshoot-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: netshoot
  namespace: trading-system
spec:
  containers:
  - name: netshoot
    image: nicolaka/netshoot
    command: ["sleep", "3600"]
  restartPolicy: Never
EOF

    if ! kubectl get pod netshoot -n trading-system &>/dev/null; then
        kubectl apply -f /tmp/netshoot-pod.yaml
        kubectl wait --for=condition=Ready pod/netshoot -n trading-system --timeout=60s || true
    fi
    
    if kubectl get pod netshoot -n trading-system &>/dev/null; then
        echo "Testing DNS resolution from within cluster:"
        kubectl exec netshoot -n trading-system -- nslookup market-streamer-service.trading-system.svc.cluster.local || true
        kubectl exec netshoot -n trading-system -- nslookup trading-algorithm-service.trading-system.svc.cluster.local || true
    fi
}

# Check resource usage and limits
check_resources() {
    print_header "📊 Checking Resource Usage"
    
    echo -e "${BLUE}Node Resources:${NC}"
    kubectl describe nodes | grep -A 5 "Allocated resources" || true
    
    echo -e "\n${BLUE}Pod Resource Requests/Limits:${NC}"
    kubectl get pods -n trading-system -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].resources}{"\n"}{end}' | column -t
    
    echo -e "\n${BLUE}Current Resource Usage:${NC}"
    kubectl top pods -n trading-system 2>/dev/null || echo "Metrics server not available"
}

# Provide troubleshooting suggestions
suggest_fixes() {
    print_header "💡 Troubleshooting Suggestions"
    
    echo -e "${YELLOW}Common Issues and Solutions:${NC}"
    echo ""
    echo "1. ${BLUE}Image Pull Issues:${NC}"
    echo "   - Ensure Docker images are built: docker build -t market-streamer:latest ."
    echo "   - For kind clusters: kind load docker-image market-streamer:latest"
    echo "   - Check image names match exactly in manifests"
    echo ""
    echo "2. ${BLUE}Resource Constraints:${NC}"
    echo "   - Check if cluster has enough CPU/memory"
    echo "   - Reduce resource requests in manifests if needed"
    echo ""
    echo "3. ${BLUE}Application Startup Issues:${NC}"
    echo "   - Check application logs for errors"
    echo "   - Verify environment variables are correct"
    echo "   - Test application locally first"
    echo ""
    echo "4. ${BLUE}Networking Issues:${NC}"
    echo "   - Verify UDP port configurations"
    echo "   - Check if services can resolve each other"
    echo "   - Disable network policies temporarily if needed"
    echo ""
    echo "5. ${BLUE}Quick Fixes to Try:${NC}"
    echo "   - kubectl rollout restart deployment/market-streamer -n trading-system"
    echo "   - kubectl delete pod -l app=market-streamer -n trading-system"
    echo "   - Check kubectl describe deployment market-streamer -n trading-system"
}

# Interactive mode for step-by-step troubleshooting
interactive_debug() {
    print_header "🔧 Interactive Debugging"
    
    echo "Select what you want to check:"
    echo "1) Cluster status"
    echo "2) Docker images"
    echo "3) Namespace and resources"
    echo "4) Pod diagnostics"
    echo "5) Networking"
    echo "6) Resource usage"
    echo "7) All checks"
    echo "8) Cleanup test resources"
    echo "9) Exit"
    
    read -p "Enter your choice (1-9): " choice
    
    case $choice in
        1) check_cluster ;;
        2) check_images ;;
        3) check_namespace ;;
        4) check_pods ;;
        5) check_networking ;;
        6) check_resources ;;
        7) 
            check_cluster
            check_images
            check_namespace
            check_pods
            check_networking
            check_resources
            suggest_fixes
            ;;
        8)
            kubectl delete pod netshoot -n trading-system 2>/dev/null || true
            rm -f /tmp/netshoot-pod.yaml
            print_status "Cleanup completed"
            ;;
        9) exit 0 ;;
        *) print_error "Invalid choice" ;;
    esac
}

# Main execution
main() {
    case "${1:-interactive}" in
        "cluster")
            check_cluster
            ;;
        "images")
            check_images
            ;;
        "namespace")
            check_namespace
            ;;
        "pods")
            check_pods
            ;;
        "networking")
            check_networking
            ;;
        "resources")
            check_resources
            ;;
        "all")
            check_cluster
            check_images
            check_namespace
            check_pods
            check_networking
            check_resources
            suggest_fixes
            ;;
        "interactive")
            interactive_debug
            ;;
        "help")
            echo "Usage: $0 [cluster|images|namespace|pods|networking|resources|all|interactive|help]"
            echo ""
            echo "Commands:"
            echo "  cluster     - Check cluster status and nodes"
            echo "  images      - Check Docker images availability"
            echo "  namespace   - Check namespace and basic resources"
            echo "  pods        - Detailed pod diagnostics"
            echo "  networking  - Check services and networking"
            echo "  resources   - Check resource usage and limits"
            echo "  all         - Run all checks"
            echo "  interactive - Interactive debugging mode (default)"
            echo "  help        - Show this help message"
            ;;
        *)
            print_error "Unknown command: $1"
            echo "Use '$0 help' for available commands"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"