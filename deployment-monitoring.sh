#!/bin/bash

echo "🚀 TRADING SYSTEM DEPLOYMENT MONITOR"
echo "===================================="

watch_deployment() {
    while true; do
        clear
        echo "📊 Current Status ($(date))"
        echo "=========================="
        
        echo ""
        echo "🔹 Pods Status:"
        kubectl get pods -n trading-system -o wide
        
        echo ""
        echo "🔹 Services:"
        kubectl get services -n trading-system
        
        echo ""
        echo "🔹 Deployments:"
        kubectl get deployments -n trading-system
        
        echo ""
        echo "🔹 Recent Events:"
        kubectl get events -n trading-system --sort-by='.lastTimestamp' | tail -8
        
        echo ""
        echo "🔹 Quick Status Check:"
        
        # Check each service
        MARKET_POD=$(kubectl get pods -n trading-system -l app=market-streamer -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        ALGO_POD=$(kubectl get pods -n trading-system -l app=order-book-algo -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        SIM_POD=$(kubectl get pods -n trading-system -l app=trade-simulator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        
        if [ ! -z "$MARKET_POD" ]; then
            MARKET_STATUS=$(kubectl get pod $MARKET_POD -n trading-system -o jsonpath='{.status.phase}' 2>/dev/null)
            echo "  📈 Market Streamer: $MARKET_STATUS"
        else
            echo "  📈 Market Streamer: Not Found"
        fi
        
        if [ ! -z "$ALGO_POD" ]; then
            ALGO_STATUS=$(kubectl get pod $ALGO_POD -n trading-system -o jsonpath='{.status.phase}' 2>/dev/null)
            echo "  🧮 Order Book Algo: $ALGO_STATUS"
        else
            echo "  🧮 Order Book Algo: Not Found"
        fi
        
        if [ ! -z "$SIM_POD" ]; then
            SIM_STATUS=$(kubectl get pod $SIM_POD -n trading-system -o jsonpath='{.status.phase}' 2>/dev/null)
            echo "  🎯 Trade Simulator: $SIM_STATUS"
        else
            echo "  🎯 Trade Simulator: Not Found"
        fi
        
        echo ""
        echo "Press Ctrl+C to exit monitoring..."
        sleep 5
    done
}

case "${1:-watch}" in
    "watch")
        watch_deployment
        ;;
    "logs")
        echo "📝 Service Logs:"
        echo "==============="
        
        echo ""
        echo "🔹 Market Streamer Logs:"
        kubectl logs -n trading-system deployment/market-streamer --tail=20 2>/dev/null || echo "No logs yet"
        
        echo ""
        echo "🔹 Order Book Algorithm Logs:"
        kubectl logs -n trading-system deployment/order-book-algo --tail=20 2>/dev/null || echo "No logs yet"
        
        echo ""
        echo "🔹 Trade Simulator Logs:"
        kubectl logs -n trading-system deployment/trade-simulator --tail=20 2>/dev/null || echo "No logs yet"
        ;;
    "status")
        echo "📊 Quick Status Check:"
        echo "===================="
        kubectl get all -n trading-system
        echo ""
        echo "Recent events:"
        kubectl get events -n trading-system --sort-by='.lastTimestamp' | tail -10
        ;;
    "external")
        echo "🌐 External Access Information:"
        echo "=============================="
        echo ""
        echo "Your services are accessible externally via:"
        echo ""
        echo "📈 Market Streamer (UDP): localhost:8888"
        echo "   Test with: nc -u localhost 8888"
        echo ""
        echo "🧮 Order Book Algorithm (UDP): localhost:9999" 
        echo "   Test with: nc -u localhost 9999"
        echo ""
        echo "💡 Note: These map to NodePorts 30080 and 30081 respectively"
        echo ""
        echo "To follow logs in real-time:"
        echo "  kubectl logs -f -n trading-system deployment/market-streamer"
        echo "  kubectl logs -f -n trading-system deployment/order-book-algo"
        echo "  kubectl logs -f -n trading-system deployment/trade-simulator"
        ;;
    "help")
        echo "Usage: $0 [watch|logs|status|external|help]"
        echo ""
        echo "Commands:"
        echo "  watch    - Real-time deployment monitoring (default)"
        echo "  logs     - Show recent logs from all services"
        echo "  status   - Quick status overview"
        echo "  external - Show external access information"
        echo "  help     - Show this help message"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Use '$0 help' for available commands"
        ;;
esac