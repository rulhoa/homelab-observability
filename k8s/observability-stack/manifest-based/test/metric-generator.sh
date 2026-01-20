#!/bin/bash

# Metric Generator Script
# Sends simulated metrics to VictoriaMetrics for testing
# Generates: CPU usage, memory, request duration, error count

set -e

# Default values
MODE="normal"
DURATION=60  # seconds
TARGET=""
INTERVAL=15  # seconds between sends

# Help message
usage() {
  cat << EOF
Usage: $0 [OPTIONS]

Generate test metrics and send to VictoriaMetrics

OPTIONS:
  --mode MODE          Generation mode: normal, alert, spike (default: normal)
  --duration SECONDS   How long to generate data (default: 60)
  --target URL         VictoriaMetrics URL (default: auto-detect vminsert)
  --interval SECONDS   Seconds between metric sends (default: 15)
  -h, --help          Show this help

MODES:
  normal: CPU 20-60%, errors 0-2%, latency 50-200ms
  alert:  CPU 85-99%, errors 10-30%, latency 500-2000ms  
  spike:  Random spikes to 90%+ CPU

EXAMPLES:
  # Normal traffic for 2 minutes
  $0 --mode normal --duration 120

  # Alert conditions for 3 minutes
  $0 --mode alert --duration 180

  # Send to specific vminsert endpoint
  $0 --mode normal --target http://192.168.1.240:8480
EOF
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --mode)
      MODE="$2"
      shift 2
      ;;
    --duration)
      DURATION="$2"
      shift 2
      ;;
    --target)
      TARGET="$2"
      shift 2
      ;;
    --interval)
      INTERVAL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

# Auto-detect vminsert if not provided
if [ -z "$TARGET" ]; then
  echo "Auto-detecting vminsert LoadBalancer service..."
  
  # Try to get external IP from LoadBalancer service
  VMINSERT_IP=$(kubectl get svc -n observability-stack vminsert-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  
  if [ -z "$VMINSERT_IP" ]; then
    echo "ERROR: Cannot find vminsert-lb service or LoadBalancer IP not assigned"
    echo "Make sure vminsert-lb service exists and MetalLB assigned an IP"
    echo ""
    echo "Check with: kubectl get svc -n observability-stack vminsert-lb"
    echo ""
    echo "Or use --target flag to specify vminsert URL manually"
    exit 1
  fi
  
  TARGET="http://${VMINSERT_IP}:8480"
fi

echo "========================================="
echo "Metric Generator"
echo "========================================="
echo "Mode:     $MODE"
echo "Duration: ${DURATION}s"
echo "Target:   $TARGET"
echo "Interval: ${INTERVAL}s"
echo "========================================="

# Instance identifier
#INSTANCE="test-generator-$$"
INSTANCE="test-generator"

# Generate random value in range
random_range() {
  local min=$1
  local max=$2
  echo $((min + RANDOM % (max - min + 1)))
}

# Generate metrics based on mode
generate_metrics() {
  local timestamp=$(date +%s)000  # milliseconds
  
  # Set ranges based on mode
  case $MODE in
    normal)
      #CPU=$(random_range 20 60)
      #MEMORY=$(random_range 500000000 800000000)  # 500-800MB
      #LATENCY=$(random_range 50 200)  # 50-200ms
      #ERRORS=$(random_range 0 2)

      CPU=$(shuf -i 20-60 -n 1)
      MEMORY=$(shuf -i 500000000-800000000 -n 1)  # 500-800MB
      LATENCY=$(shuf -i 50-200 -n 1)  # 50-200ms
      ERRORS=$(shuf -i 0-2 -n 1)
      ;;
    alert)
      #CPU=$(random_range 85 99)
      #MEMORY=$(random_range 1500000000 1900000000)  # 1.5-1.9GB
      #LATENCY=$(random_range 500 2000)  # 500-2000ms
      #ERRORS=$(random_range 10 30)

      CPU=$(shuf -i 85-99 -n 1)
      MEMORY=$(shuf -i 1500000000-1900000000 -n 1)  # 500-800MB
      LATENCY=$(shuf -i 500-2000 -n 1)  # 50-200ms
      ERRORS=$(shuf -i 10-30 -n 1)
      ;;
    spike)
      # Random spikes
      if [ $((RANDOM % 3)) -eq 0 ]; then
        #CPU=$(random_range 90 99)
        CPU=$(shuf -i 90-99 -n 1)
      else
        #CPU=$(random_range 20 60)
        CPU=$(shuf -i 20-60 -n 1)
      fi
      #MEMORY=$(random_range 500000000 1000000000)
      #LATENCY=$(random_range 50 500)
      #ERRORS=$(random_range 0 5)

      MEMORY=$(shuf -i 500000000-1000000000 -n 1)  # 500-800MB
      LATENCY=$(shuf -i 50-500 -n 1)  # 50-200ms
      ERRORS=$(shuf -i 0-5 -n 1)
      ;;
    *)
      echo "Unknown mode: $MODE"
      exit 1
      ;;
  esac
  
  # Build Prometheus format metrics
  # Format: metric_name{labels} value timestamp
  cat << EOF
app_cpu_usage{instance="$INSTANCE",job="test-generator",mode="$MODE"} $CPU $timestamp
app_memory_bytes{instance="$INSTANCE",job="test-generator",mode="$MODE"} $MEMORY $timestamp
app_request_duration_milliseconds{instance="$INSTANCE",job="test-generator",mode="$MODE"} $LATENCY $timestamp
app_error_count{instance="$INSTANCE",job="test-generator",mode="$MODE"} $ERRORS $timestamp
app_request_total{instance="$INSTANCE",job="test-generator",mode="$MODE"} $((100 + ERRORS)) $timestamp
EOF
}

# Send metrics to VictoriaMetrics
send_metrics() {
  local metrics="$1"
  
  # VictoriaMetrics import endpoint
  # vminsert uses /insert/0/prometheus path (not /select)
  local url="${TARGET}/insert/0/prometheus/api/v1/import/prometheus"
  
  # Send with curl

  echo "curl -s -X POST \"$url\" \
    -H \"Content-Type: text/plain\" \
    -d \"$metrics\""

  curl -s -X POST "$url" \
    -H "Content-Type: text/plain" \
    -d "$metrics"
  
  if [ $? -eq 0 ]; then
    return 0
  else
    echo "ERROR: Failed to send metrics"
    return 1
  fi
}

# Main loop
echo "Starting metric generation..."
echo "Press Ctrl+C to stop early"
echo ""

START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION))
ITERATION=0

while [ $(date +%s) -lt $END_TIME ]; do
  ITERATION=$((ITERATION + 1))
  
  # Generate and send metrics
  METRICS=$(generate_metrics)
  
  if send_metrics "$METRICS"; then
    REMAINING=$((END_TIME - $(date +%s)))
    echo "[$(date '+%H:%M:%S')] Iteration $ITERATION: Sent metrics (${REMAINING}s remaining)"
    
    # Show current values in alert mode
    if [ "$MODE" = "alert" ]; then
      echo "  └─ CPU: ${CPU}% | Memory: $((MEMORY / 1000000))MB | Latency: ${LATENCY}ms | Errors: ${ERRORS}"
    fi
  fi
  
  # Sleep until next interval
  sleep $INTERVAL
done

echo ""
echo "========================================="
echo "Generation complete!"
echo "Total iterations: $ITERATION"
echo "========================================="
echo ""
echo "Query your metrics (use vmselect, not vminsert):"
echo "  VMSELECT_IP=\$(kubectl get svc -n observability-stack vmselect-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "  curl \"http://\${VMSELECT_IP}:8481/select/0/prometheus/api/v1/query?query=app_cpu_usage\""
echo ""
echo "Or view in vmalert UI to see if alerts fired"