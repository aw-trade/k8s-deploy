#!/bin/bash

# Kubernetes Deployment Script for Rust Trading Services
# This script deploys the 3 trading services to a local Kubernetes cluster

set -e

echo "🚀 Deploying Rust Trading Services to Kubernetes"
echo "=================================================="

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "\n${BLUE}$1${NC}"
    echo "$(printf '=%.0s' {1..50})"
}

# Check if kubectl is installed and configured
check_kubectl() {
    print_header "🔍 Checking kubectl installation"
    
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed. Please install kubectl first."
        exit 1
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        print_error "kubectl is not configured or cluster is not accessible."
        exit 1
    fi
    
    print_status "kubectl is configured and cluster is accessible"
    kubectl cluster-info
}

# Check if Docker images exist
check_docker_images() {
    print_header "🐳 Checking Docker images"
    
    IMAGES=("market-streamer:latest" "order-book-algo:latest" "trade-simulator:latest")
    
    for image in "${IMAGES[@]}"; do
        if docker images --format "table {{.Repository}}:{{.Tag}}" | grep -q "$image"; then
            print_status "Found image: $image"
        else
            print_warning "Image not found: $image"
            print_warning "Make sure to build and tag your Docker images:"
            echo "  docker build -t $image ."
        fi
    done
}

# Load Docker images to kind cluster (if using kind)
load_images_to_kind() {
    if kubectl config current-context | grep -q "trading-cluster-control-plane"; then
        print_header "📦 Loading images to kind cluster"
        
        IMAGES=("market-streamer:latest" "order-book-algo:latest" "trading-simulator:latest")
        
        for image in "${IMAGES[@]}"; do
            if docker images --format "table {{.Repository}}:{{.Tag}}" | grep -q "$image"; then
                print_status "Loading $image to kind cluster..."
                kind load docker-image "$image"
            fi
        done
    fi
}

# Deploy the services
deploy_services() {
    print_header "🚀 Deploying services to Kubernetes"
    
    # Apply the Kubernetes manifests
    print_status "Creating namespace and deploying services..."
    kubectl apply -f k8s-trading-manifests.yaml
    
    # Wait for deployments to be ready
    print_status "Waiting for deployments to be ready..."
    
    kubectl wait --for=condition=available --timeout=100s deployment/market-streamer -n trading-system
    kubectl wait --for=condition=available --timeout=100s deployment/order-book-algo -n trading-system  
    kubectl wait --for=condition=available --timeout=100s deployment/trade-simulator -n trading-system
    
    print_status "All deployments are ready!"
}

# Show deployment status
show_status() {
    print_header "📊 Deployment Status"
    
    echo -e "\n${BLUE}Pods:${NC}"
    kubectl get pods -n trading-system -o wide
    
    echo -e "\n${BLUE}Services:${NC}"
    kubectl get services -n trading-system
    
    echo -e "\n${BLUE}Deployments:${NC}"
    kubectl get deployments -n trading-system
}

# Show logs
show_logs() {
    print_header "📝 Service Logs"
    
    echo -e "\n${BLUE}Crypto Streamer Logs:${NC}"
    kubectl logs -n trading-system deployment/market-streamer --tail=10
    
    echo -e "\n${BLUE}Trading Algorithm Logs:${NC}"
    kubectl logs -n trading-system deployment/order-book-algo --tail=10
    
    echo -e "\n${BLUE}Trading Simulator Logs:${NC}"
    kubectl logs -n trading-system deployment/trade-simulator --tail=10
}

# Port forwarding for external access
setup_port_forwarding() {
    print_header "🌐 Setting up port forwarding"
    
    print_status "You can access services locally using port forwarding:"
    echo ""
    echo "🔹 Crypto Streamer (UDP 8888):"
    echo "  kubectl port-forward -n trading-system service/market-streamer-service 8888:8888"
    echo ""
    echo "🔹 Trading Algorithm (UDP 9999):"
    echo "  kubectl port-forward -n trading-system service/order-book-algo-service 9999:9999"
    echo ""
    echo "🔹 To follow logs in real-time:"
    echo "  kubectl logs -n trading-system -f deployment/market-streamer"
    echo "  kubectl logs -n trading-system -f deployment/order-book-algo"
    echo "  kubectl logs -n trading-system -f deployment/trading-simulator"
}

# Cleanup function
cleanup() {
    print_header "🧹 Cleaning up resources"
    
    read -p "Are you sure you want to delete all trading services? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        kubectl delete namespace trading-system
        print_status "All resources have been deleted"
    else
        print_status "Cleanup cancelled"
    fi
}

# Main execution
main() {


    # Then load the retagged images
    kind load docker-image market-streamer:latest --name trading-cluster
    kind load docker-image order-book-algo:latest --name trading-cluster
    kind load docker-image trade-simulator:latest --name trading-cluster

    case "${1:-deploy}" in
        "deploy")
            check_kubectl
            check_docker_images
            load_images_to_kind
            deploy_services
            show_status
            setup_port_forwarding
            ;;
        "status")
            show_status
            ;;
        "logs")
            show_logs
            ;;
        "cleanup")
            cleanup
            ;;
        "help")
            echo "Usage: $0 [deploy|status|logs|cleanup|help]"
            echo ""
            echo "Commands:"
            echo "  deploy   - Deploy all services (default)"
            echo "  status   - Show deployment status"
            echo "  logs     - Show service logs"
            echo "  cleanup  - Delete all resources"
            echo "  help     - Show this help message"
            ;;
        *)
            print_error "Unknown command: $1"
            echo "Use '$0 help' for available commands"
            exit 1
            ;;
    esac
}

# Trap cleanup on script exit
trap 'echo -e "\n${YELLOW}Script interrupted${NC}"' INT

# Run main function
main "$@"