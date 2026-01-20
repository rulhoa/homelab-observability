#!/bin/bash

# Trace Generator Script
# Sends simulated distributed traces to Tempo for testing
# Generates multi-span traces (frontend → backend → database)

set -e

# Default values
MODE="normal"
DURATION=60  # seconds
TARGET=""
INTERVAL=10  # seconds between sends

# Help message
usage() {
  cat << EOF
Usage: $0 [OPTIONS]

Generate test traces and send to Tempo

OPTIONS:
  --mode MODE          Generation mode: normal, alert (default: normal)
  --duration SECONDS   How long to generate data (default: 60)
  --target URL         Tempo OTLP HTTP endpoint (default: auto-detect tempo-lb)
  --interval SECONDS   Seconds between trace sends (default: 10)
  -h, --help          Show this help

MODES:
  normal: Fast requests (50-200ms), 95% success rate
  alert:  Slow requests (2-10s), 40% error rate

EXAMPLES:
  # Normal traces for 2 minutes
  $0 --mode normal --duration 120

  # Alert conditions (slow traces with errors)
  $0 --mode alert --duration 180

  # Send to specific Tempo endpoint
  $0 --mode normal --target http://192.168.1.240:4318
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

# Auto-detect Tempo if not provided
if [ -z "$TARGET" ]; then
  echo "Auto-detecting Tempo LoadBalancer service..."
  
  TEMPO_IP=$(kubectl get svc -n observability-stack o11y-tempo -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  
  if [ -z "$TEMPO_IP" ]; then
    echo "ERROR: Cannot find o11y-tempo service or LoadBalancer IP not assigned"
    echo "Make sure o11y-tempo service exists and MetalLB assigned an IP"
    echo ""
    echo "Check with: kubectl get svc -n observability-stack o11y-tempo"
    echo ""
    echo "Or use --target flag to specify Tempo URL manually"
    exit 1
  fi
  
  TARGET="http://${TEMPO_IP}:4318"
fi

echo "========================================="
echo "Trace Generator"
echo "========================================="
echo "Mode:     $MODE"
echo "Duration: ${DURATION}s"
echo "Target:   $TARGET"
echo "Interval: ${INTERVAL}s"
echo "========================================="

# Generate random hex string for IDs
random_hex() {
  local length=$1
  cat /dev/urandom | tr -dc '0-9a-f' | fold -w $length | head -n 1
}

# Generate trace timing based on mode
get_trace_timing() {
  case $MODE in
    normal)
      # Fast traces: 50-200ms total
      FRONTEND_MS=$((50 + RANDOM % 50))      # 50-100ms
      BACKEND_MS=$((30 + RANDOM % 50))       # 30-80ms
      DATABASE_MS=$((20 + RANDOM % 40))      # 20-60ms
      HAS_ERROR=false
      
      # 5% error rate
      if [ $((RANDOM % 100)) -lt 5 ]; then
        HAS_ERROR=true
      fi
      ;;
    alert)
      # Slow traces: 2-10s total
      FRONTEND_MS=$((500 + RANDOM % 1000))   # 500-1500ms
      BACKEND_MS=$((1000 + RANDOM % 3000))   # 1-4s
      DATABASE_MS=$((2000 + RANDOM % 5000))  # 2-7s
      HAS_ERROR=false
      
      # 40% error rate
      if [ $((RANDOM % 100)) -lt 40 ]; then
        HAS_ERROR=true
      fi
      ;;
  esac
}

# Generate a distributed trace with 3 spans
generate_trace() {
  # Get timing parameters
  get_trace_timing
  
  # Generate IDs
  local trace_id=$(random_hex 32)
  local frontend_span_id=$(random_hex 16)
  local backend_span_id=$(random_hex 16)
  local database_span_id=$(random_hex 16)
  
  # Base timestamp in nanoseconds
  local start_time_ns=$(date +%s)000000000
  
  # Calculate span timestamps
  local frontend_start=$start_time_ns
  local frontend_end=$((frontend_start + FRONTEND_MS * 1000000))
  
  local backend_start=$((frontend_start + 5000000))  # Start 5ms after frontend
  local backend_end=$((backend_start + BACKEND_MS * 1000000))
  
  local database_start=$((backend_start + 5000000))  # Start 5ms after backend
  local database_end=$((database_start + DATABASE_MS * 1000000))
  
  # Status code
  local status_code=0  # OK
  local status_message="OK"
  if [ "$HAS_ERROR" = true ]; then
    status_code=2  # ERROR
    status_message="Internal Server Error"
  fi
  
  # Build OTLP JSON payload
  cat <<EOF
{
  "resourceSpans": [
    {
      "resource": {
        "attributes": [
          {"key": "service.name", "value": {"stringValue": "frontend"}},
          {"key": "service.instance.id", "value": {"stringValue": "frontend-1"}},
          {"key": "mode", "value": {"stringValue": "$MODE"}}
        ]
      },
      "scopeSpans": [
        {
          "scope": {
            "name": "trace-generator",
            "version": "1.0.0"
          },
          "spans": [
            {
              "traceId": "$trace_id",
              "spanId": "$frontend_span_id",
              "name": "GET /api/users",
              "kind": 1,
              "startTimeUnixNano": "$frontend_start",
              "endTimeUnixNano": "$frontend_end",
              "attributes": [
                {"key": "http.method", "value": {"stringValue": "GET"}},
                {"key": "http.url", "value": {"stringValue": "/api/users"}},
                {"key": "http.status_code", "value": {"intValue": "$( [ "$HAS_ERROR" = true ] && echo 500 || echo 200 )"}}
              ],
              "status": {
                "code": $status_code,
                "message": "$status_message"
              }
            }
          ]
        }
      ]
    },
    {
      "resource": {
        "attributes": [
          {"key": "service.name", "value": {"stringValue": "backend"}},
          {"key": "service.instance.id", "value": {"stringValue": "backend-1"}},
          {"key": "mode", "value": {"stringValue": "$MODE"}}
        ]
      },
      "scopeSpans": [
        {
          "scope": {
            "name": "trace-generator",
            "version": "1.0.0"
          },
          "spans": [
            {
              "traceId": "$trace_id",
              "spanId": "$backend_span_id",
              "parentSpanId": "$frontend_span_id",
              "name": "getUserData",
              "kind": 2,
              "startTimeUnixNano": "$backend_start",
              "endTimeUnixNano": "$backend_end",
              "attributes": [
                {"key": "component", "value": {"stringValue": "user-service"}},
                {"key": "user.count", "value": {"intValue": "$((10 + RANDOM % 100))"}}
              ],
              "status": {
                "code": $status_code
              }
            }
          ]
        }
      ]
    },
    {
      "resource": {
        "attributes": [
          {"key": "service.name", "value": {"stringValue": "database"}},
          {"key": "service.instance.id", "value": {"stringValue": "postgres-1"}},
          {"key": "mode", "value": {"stringValue": "$MODE"}}
        ]
      },
      "scopeSpans": [
        {
          "scope": {
            "name": "trace-generator",
            "version": "1.0.0"
          },
          "spans": [
            {
              "traceId": "$trace_id",
              "spanId": "$database_span_id",
              "parentSpanId": "$backend_span_id",
              "name": "SELECT users",
              "kind": 3,
              "startTimeUnixNano": "$database_start",
              "endTimeUnixNano": "$database_end",
              "attributes": [
                {"key": "db.system", "value": {"stringValue": "postgresql"}},
                {"key": "db.statement", "value": {"stringValue": "SELECT * FROM users WHERE active = true"}},
                {"key": "db.rows_affected", "value": {"intValue": "$((50 + RANDOM % 100))"}}
              ],
              "status": {
                "code": $status_code
              }
            }
          ]
        }
      ]
    }
  ]
}
EOF
}

# Send trace to Tempo
send_trace() {
  local trace_json="$1"
  
  # Tempo OTLP HTTP endpoint
  local url="${TARGET}/v1/traces"
  
  # Send with curl
  local response=$(curl -s -w "\n%{http_code}" -X POST "$url" \
    -H "Content-Type: application/json" \
    -d "$trace_json")
  
  local http_code=$(echo "$response" | tail -n1)
  
  if [ "$http_code" = "200" ] || [ "$http_code" = "202" ]; then
    return 0
  else
    echo "ERROR: Failed to send trace (HTTP $http_code)"
    echo "Response: $(echo "$response" | head -n-1)"
    return 1
  fi
}

# Main loop
echo "Starting trace generation..."
echo "Press Ctrl+C to stop early"
echo ""

START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION))
ITERATION=0
ERROR_COUNT=0

while [ $(date +%s) -lt $END_TIME ]; do
  ITERATION=$((ITERATION + 1))
  
  # Generate trace
  TRACE=$(generate_trace)
  
  # Send to Tempo
  if send_trace "$TRACE"; then
    REMAINING=$((END_TIME - $(date +%s)))
    TOTAL_MS=$((FRONTEND_MS + BACKEND_MS + DATABASE_MS))
    echo "[$(date '+%H:%M:%S')] Iteration $ITERATION: Sent trace (${TOTAL_MS}ms, ${REMAINING}s remaining)"
    
    # Show details in alert mode
    if [ "$MODE" = "alert" ]; then
      if [ "$HAS_ERROR" = true ]; then
        ERROR_COUNT=$((ERROR_COUNT + 1))
        echo "  └─ ⚠️  ERROR trace | Duration: ${TOTAL_MS}ms"
      else
        echo "  └─ ✓ OK trace | Duration: ${TOTAL_MS}ms"
      fi
    fi
  fi
  
  # Sleep until next interval
  sleep $INTERVAL
done

echo ""
echo "========================================="
echo "Generation complete!"
echo "Total iterations: $ITERATION"
if [ "$MODE" = "alert" ]; then
  echo "Error traces: $ERROR_COUNT"
  echo "Error rate: $(( (ERROR_COUNT * 100) / ITERATION ))%"
fi
echo "========================================="
echo ""
echo "Query your traces in Grafana:"
echo "  1. Open Grafana Explore"
echo "  2. Select 'Tempo' datasource"
echo "  3. Click 'Search' tab"
echo "  4. Filter by: service.name = frontend"
echo ""
echo "Or query directly:"
TEMPO_IP=$(kubectl get svc -n observability-stack o11y-tempo -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "  curl -s \"http://${TEMPO_IP}:3200/api/search?tags=service.name%3Dfrontend\" | jq ."