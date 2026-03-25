#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Deploy LiteLLM on Kind (for comparison / before migration)
# =============================================================================

CLUSTER_NAME="agentgateway-demo"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Check cluster exists
if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  err "Kind cluster '${CLUSTER_NAME}' not found. Run ./setup-kind.sh first (it creates the cluster)."
fi

info "Deploying LiteLLM to kind cluster '${CLUSTER_NAME}' for comparison..."

# Create namespace
kubectl create namespace litellm --dry-run=client -o yaml | kubectl apply -f -

# Create secrets
kubectl -n litellm create secret generic litellm-secrets \
  --from-literal=OPENAI_API_KEY="${OPENAI_API_KEY:-not-set}" \
  --from-literal=ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-not-set}" \
  --from-literal=LITELLM_MASTER_KEY="sk-1234" \
  --dry-run=client -o yaml | kubectl apply -f -

# Create ConfigMap
kubectl -n litellm apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: litellm-config
  namespace: litellm
data:
  config.yaml: |
    model_list:
      - model_name: gpt-4o
        litellm_params:
          model: openai/gpt-4o
          api_key: os.environ/OPENAI_API_KEY

      - model_name: gpt-4o-mini
        litellm_params:
          model: openai/gpt-4o-mini
          api_key: os.environ/OPENAI_API_KEY

      - model_name: claude-sonnet
        litellm_params:
          model: anthropic/claude-sonnet-4-20250514
          api_key: os.environ/ANTHROPIC_API_KEY

      - model_name: claude-haiku
        litellm_params:
          model: anthropic/claude-haiku-4-5-20251001
          api_key: os.environ/ANTHROPIC_API_KEY

    general_settings:
      master_key: os.environ/LITELLM_MASTER_KEY

    litellm_settings:
      num_retries: 3
      request_timeout: 30
      fallbacks:
        - claude-sonnet: [gpt-4o]
        - gpt-4o: [claude-sonnet]
      drop_params: true

    router_settings:
      routing_strategy: simple-shuffle
EOF

# Create Deployment
kubectl -n litellm apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: litellm
  namespace: litellm
  labels:
    app: litellm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: litellm
  template:
    metadata:
      labels:
        app: litellm
    spec:
      containers:
      - name: litellm
        image: docker.litellm.ai/berriai/litellm:main-stable
        args: ["--config", "/app/proxy_server_config.yaml", "--port", "4000"]
        ports:
        - containerPort: 4000
        envFrom:
        - secretRef:
            name: litellm-secrets
        volumeMounts:
        - name: config
          mountPath: /app/proxy_server_config.yaml
          subPath: config.yaml
        livenessProbe:
          httpGet:
            path: /health/liveliness
            port: 4000
          initialDelaySeconds: 120
          periodSeconds: 15
        readinessProbe:
          httpGet:
            path: /health/readiness
            port: 4000
          initialDelaySeconds: 120
          periodSeconds: 15
        resources:
          requests:
            cpu: "2"
            memory: 4Gi
          limits:
            cpu: "4"
            memory: 8Gi
      volumes:
      - name: config
        configMap:
          name: litellm-config
EOF

# Create Service
kubectl -n litellm apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: litellm
  namespace: litellm
spec:
  selector:
    app: litellm
  type: ClusterIP
  ports:
  - name: http
    port: 4000
    targetPort: 4000
EOF

info "Waiting for LiteLLM to be ready (this takes ~2 minutes due to Python startup)..."
if kubectl -n litellm rollout status deployment/litellm --timeout=300s; then
  ok "LiteLLM is running"
else
  warn "LiteLLM may still be starting. Check: kubectl -n litellm get pods"
fi

echo ""
echo "============================================="
echo -e "${GREEN}  LiteLLM is running on Kind!${NC}"
echo "============================================="
echo ""
echo "  Access via port-forward:"
echo ""
echo "  kubectl -n litellm port-forward svc/litellm 4001:4000 &"
echo ""
echo "  Test it:"
echo ""
echo "  curl http://localhost:4001/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -H 'Authorization: Bearer sk-1234' \\"
echo "    -d '{\"model\": \"gpt-4o\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}]}'"
echo ""
echo "  Compare resource usage:"
echo ""
echo "  kubectl top pods -n litellm"
echo "  kubectl top pods -n agentgateway"
echo ""
