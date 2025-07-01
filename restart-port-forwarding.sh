# Kill any existing port forwards on port 2746
sudo lsof -ti:2746 | xargs kill -9 2>/dev/null || true
pkill -f "kubectl.*port-forward.*argo" 2>/dev/null || true

# Wait a moment
sleep 2

# Verify port 2746 is free
lsof -i :2746 || echo "Port 2746 is free"

kubectl port-forward -n argo svc/argo-server 2746:2746 --address=127.0.0.1