#!/bin/bash

# Log Generator Script
# Sends simulated application logs to Loki for testing
# Generates structured JSON logs with different severity levels

set -e

# Default values
MODE="normal"
DURATION=60  # seconds
TARGET=""
INTERVAL=5   # seconds between sends

# Help message
usage() {
  cat << EOF
Usage: $0 [OPTIONS]

Generate test logs and send to Loki

OPTIONS:
  --mode MODE          Generation mode: normal, alert (default: normal)
  --duration SECONDS   How long to generate data (default: 60)
  --target URL         Loki URL (default: auto-detect loki-write-lb)
  --interval SECONDS   Seconds between log sends (default: 5)
  -h, --help          Show this help

MODES:
  normal: 95% INFO, 5% WARN logs
  alert:  60% ERROR, 30% CRITICAL, 10% INFO logs

EXAMPLES:
  # Normal logs for 2 minutes
  $0 --mode normal --duration 120

  # Alert conditions for 3 minutes (trigger log alerts)
  $0 --mode alert --duration 180

  # Send to specific Loki endpoint
  $0 --mode normal --target http://192.168.1.240:3100
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

# Auto-detect loki if not provided
if [ -z "$TARGET" ]; then
  echo "Auto-detecting Loki LoadBalancer service..."
  
  LOKI_IP=$(kubectl get svc -n observability-stack loki-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  
  if [ -z "$LOKI_IP" ]; then
    echo "ERROR: Cannot find loki-lb service or LoadBalancer IP not assigned"
    echo "Make sure loki-lb service exists and MetalLB assigned an IP"
    echo ""
    echo "Check with: kubectl get svc -n observability-stack loki-lb"
    echo ""
    echo "Or use --target flag to specify Loki URL manually"
    exit 1
  fi
  
  TARGET="http://${LOKI_IP}:3100"
fi

echo "========================================="
echo "Log Generator"
echo "========================================="
echo "Mode:     $MODE"
echo "Duration: ${DURATION}s"
echo "Target:   $TARGET"
echo "Interval: ${INTERVAL}s"
echo "========================================="

# Instance identifier
INSTANCE="log-generator-$$"

# Log level selection based on mode
get_log_level() {
  local rand=$((RANDOM % 100))
  
  case $MODE in
    normal)
      if [ $rand -lt 95 ]; then
        echo "INFO"
      else
        echo "WARN"
      fi
      ;;
    alert)
      if [ $rand -lt 60 ]; then
        echo "ERROR"
      elif [ $rand -lt 90 ]; then
        echo "CRITICAL"
      else
        echo "INFO"
      fi
      ;;
    *)
      echo "INFO"
      ;;
  esac
}

# Sample log messages by level
get_log_message() {
  local level=$1
  
  case $level in
    INFO)
      local messages=(
        "User authentication successful"
        "Request processed successfully"
        "Cache hit for key"
        "Configuration loaded"
        "Health check passed"
        "Background job completed"
        "API request received"
        "Session created"
      )
      ;;
    WARN)
      local messages=(
        "High memory usage detected"
        "Slow database query"
        "Retry attempt"
        "Deprecated API called"
        "Rate limit approaching"
        "Cache miss"
      )
      ;;
    ERROR)
      local messages=(
        "Database connection timeout"
        "Failed to process request"
        "Invalid input data"
        "External service unavailable"
        "Authentication failed"
        "File not found"
        "Network error"
      )
      ;;
    CRITICAL)
      local messages=(
        "System out of memory"
        "Database connection pool exhausted"
        "Critical service unavailable"
        "Data corruption detected"
        "Security breach attempt"
        "System crash imminent"
      )
      ;;
  esac
  
  # Select random message
  local index=$((RANDOM % ${#messages[@]}))
  echo "${messages[$index]}"
}

# Generate structured log entries
generate_logs() {
  local nano_timestamp=$(date +%s)000000000  # Current time in nanoseconds
  
  # Generate 5-10 log lines per batch
  local batch_size=$((5 + RANDOM % 6))
  local entries=""
  
  for ((i=0; i<batch_size; i++)); do
    local level=$(get_log_level)
    local message=$(get_log_message "$level")
    local user_id=$((1000 + RANDOM % 9000))
    local request_id="req-$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1 2>/dev/null || echo $RANDOM)"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S")
    
    # Adjust timestamp for each entry (add milliseconds)
    local entry_nano=$((nano_timestamp + i * 1000000))
    
    # Create simple log line (not nested JSON)
    # Format: timestamp level message [key=value ...]
    local log_line="$timestamp $level $message user_id=user_$user_id request_id=$request_id instance=$INSTANCE mode=$MODE"
    
    # Add to entries array (Loki format: ["timestamp_nano", "log_line"])
    if [ -z "$entries" ]; then
      entries="[\"$entry_nano\",\"$log_line\"]"
    else
      entries="$entries,[\"$entry_nano\",\"$log_line\"]"
    fi
  done
  
  echo "$entries"
}

# Send logs to Loki
send_logs() {
  local entries="$1"
  
  # Loki push API endpoint
  local url="${TARGET}/loki/api/v1/push"
  
  # Build Loki push payload
  local payload=$(cat <<EOF
{
  "streams": [
    {
      "stream": {
        "job": "log-generator",
        "instance": "$INSTANCE",
        "mode": "$MODE",
        "app": "demo"
      },
      "values": [$entries]
    }
  ]
}
EOF
)
  
  # Send with curl
  local response=$(curl -s -w "\n%{http_code}" -X POST "$url" \
    -H "Content-Type: application/json" \
    -d "$payload")
  
  local http_code=$(echo "$response" | tail -n1)
  
  if [ "$http_code" = "204" ]; then
    return 0
  else
    echo "ERROR: Failed to send logs (HTTP $http_code)"
    echo "Response: $(echo "$response" | head -n-1)"
    return 1
  fi
}

# Main loop
echo "Starting log generation..."
echo "Press Ctrl+C to stop early"
echo ""

START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION))
ITERATION=0
TOTAL_LINES=0

while [ $(date +%s) -lt $END_TIME ]; do
  ITERATION=$((ITERATION + 1))
  
  # Generate log entries
  ENTRIES=$(generate_logs)
  LINES=$(echo "$ENTRIES" | grep -o '\[' | wc -l)
  TOTAL_LINES=$((TOTAL_LINES + LINES))
  
  # Send to Loki
  if send_logs "$ENTRIES"; then
    REMAINING=$((END_TIME - $(date +%s)))
    echo "[$(date '+%H:%M:%S')] Iteration $ITERATION: Sent $LINES log lines (${REMAINING}s remaining)"
    
    # Show level distribution in alert mode
    if [ "$MODE" = "alert" ]; then
      ERROR_COUNT=$(echo "$ENTRIES" | grep -o '"level":"ERROR"' | wc -l)
      CRITICAL_COUNT=$(echo "$ENTRIES" | grep -o '"level":"CRITICAL"' | wc -l)
      echo "  └─ Errors: $ERROR_COUNT | Critical: $CRITICAL_COUNT"
    fi
  fi
  
  # Sleep until next interval
  sleep $INTERVAL
done

echo ""
echo "========================================="
echo "Generation complete!"
echo "Total iterations: $ITERATION"
echo "Total log lines: $TOTAL_LINES"
echo "========================================="
echo ""
echo "Query your logs in Grafana:"
echo "  1. Open Grafana Explore"
echo "  2. Select 'Loki' datasource"
echo "  3. Query: {job=\"log-generator\"}"
echo ""
echo "Or query directly:"
LOKI_IP=$(kubectl get svc -n observability-stack loki-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "  curl -G -s \"http://${LOKI_IP}:3100/loki/api/v1/query\" --data-urlencode 'query={job=\"log-generator\"}'"