#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Migrate to AgentGateway OSS on Kind
# This script sets up a kind cluster and deploys AgentGateway with LLM + MCP
# =============================================================================

CLUSTER_NAME="agentgateway-demo"
AGENTGATEWAY_IMAGE="cr.agentgateway.dev/agentgateway:latest"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# -----------------------------------------------------------------------------
# Prerequisites check
# -----------------------------------------------------------------------------
check_prereqs() {
  info "Checking prerequisites..."

  for cmd in kind kubectl docker; do
    if ! command -v "$cmd" &>/dev/null; then
      err "$cmd is required but not installed. Install it first."
    fi
  done

  if ! docker info &>/dev/null; then
    err "Docker is not running. Start Docker first."
  fi

  if [ -z "${OPENAI_API_KEY:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    warn "Neither OPENAI_API_KEY nor ANTHROPIC_API_KEY is set."
    warn "Set at least one: export OPENAI_API_KEY=sk-..."
    warn "Continuing anyway (you can update the secret later)."
  fi

  ok "Prerequisites met"
}

# -----------------------------------------------------------------------------
# Create kind cluster
# -----------------------------------------------------------------------------
create_cluster() {
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    warn "Kind cluster '${CLUSTER_NAME}' already exists"
    read -rp "Delete and recreate? [y/N] " answer
    if [[ "${answer}" =~ ^[Yy]$ ]]; then
      info "Deleting existing cluster..."
      kind delete cluster --name "${CLUSTER_NAME}"
    else
      info "Reusing existing cluster"
      kubectl cluster-info --context "kind-${CLUSTER_NAME}" &>/dev/null || err "Cannot connect to existing cluster"
      ok "Connected to existing cluster"
      return
    fi
  fi

  info "Creating kind cluster '${CLUSTER_NAME}'..."

  cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  # AgentGateway LLM port
  - containerPort: 30400
    hostPort: 4000
    protocol: TCP
  # AgentGateway MCP port
  - containerPort: 30300
    hostPort: 3000
    protocol: TCP
  # AgentGateway Admin UI
  - containerPort: 31500
    hostPort: 15000
    protocol: TCP
EOF

  ok "Kind cluster created"
}

# -----------------------------------------------------------------------------
# Deploy AgentGateway
# -----------------------------------------------------------------------------
deploy_agentgateway() {
  info "Deploying AgentGateway..."

  # Create namespace
  kubectl create namespace agentgateway --dry-run=client -o yaml | kubectl apply -f -

  # Create secrets
  kubectl -n agentgateway create secret generic agentgateway-secrets \
    --from-literal=OPENAI_API_KEY="${OPENAI_API_KEY:-not-set}" \
    --from-literal=ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-not-set}" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Create ConfigMap with combined LLM + MCP config
  kubectl -n agentgateway apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: agentgateway-config
  namespace: agentgateway
data:
  config.yaml: |
    binds:
    # LLM Gateway on port 4000
    - port: 4000
      listeners:
      - name: llm
        protocol: HTTP
        routes:
        - name: models
          backends:
          - ai:
              groups:
              - providers:
                - name: gpt-4o
                  provider:
                    openAI:
                      model: gpt-4o
                      apiKey: "$OPENAI_API_KEY"
                - name: gpt-4o-mini
                  provider:
                    openAI:
                      model: gpt-4o-mini
                      apiKey: "$OPENAI_API_KEY"
              - providers:
                - name: claude-sonnet
                  provider:
                    anthropic:
                      model: claude-sonnet-4-20250514
                      apiKey: "$ANTHROPIC_API_KEY"
                - name: claude-haiku
                  provider:
                    anthropic:
                      model: claude-haiku-4-5-20251001
                      apiKey: "$ANTHROPIC_API_KEY"

    # MCP Gateway on port 3000
    - port: 3000
      listeners:
      - name: mcp
        protocol: HTTP
        routes:
        - name: tools
          backends:
          - mcp:
              targets:
              - name: everything
                stdio:
                  cmd: npx
                  args: ["-y", "@modelcontextprotocol/server-everything"]
EOF

  # Create Deployment
  kubectl -n agentgateway apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agentgateway
  namespace: agentgateway
  labels:
    app: agentgateway
spec:
  replicas: 1
  selector:
    matchLabels:
      app: agentgateway
  template:
    metadata:
      labels:
        app: agentgateway
    spec:
      containers:
      - name: agentgateway
        image: ${AGENTGATEWAY_IMAGE}
        args: ["-f", "/config/config.yaml"]
        ports:
        - containerPort: 4000
          name: llm
        - containerPort: 3000
          name: mcp
        - containerPort: 15000
          name: admin
        envFrom:
        - secretRef:
            name: agentgateway-secrets
        env:
        - name: ADMIN_ADDR
          value: "0.0.0.0:15000"
        volumeMounts:
        - name: config
          mountPath: /config
        livenessProbe:
          httpGet:
            path: /healthz
            port: 15000
          initialDelaySeconds: 5
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /healthz
            port: 15000
          initialDelaySeconds: 5
          periodSeconds: 10
        resources:
          requests:
            cpu: "250m"
            memory: 128Mi
          limits:
            cpu: "1"
            memory: 512Mi
      volumes:
      - name: config
        configMap:
          name: agentgateway-config
EOF

  # Create Services (NodePort for kind access)
  kubectl -n agentgateway apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: agentgateway
  namespace: agentgateway
spec:
  selector:
    app: agentgateway
  type: NodePort
  ports:
  - name: llm
    port: 4000
    targetPort: 4000
    nodePort: 30400
  - name: mcp
    port: 3000
    targetPort: 3000
    nodePort: 30300
  - name: admin
    port: 15000
    targetPort: 15000
    nodePort: 31500
EOF

  ok "AgentGateway manifests applied"
}

# -----------------------------------------------------------------------------
# Wait for rollout
# -----------------------------------------------------------------------------
wait_for_ready() {
  info "Waiting for AgentGateway to be ready..."
  if kubectl -n agentgateway rollout status deployment/agentgateway --timeout=120s; then
    ok "AgentGateway is running"
  else
    err "AgentGateway failed to start. Check logs: kubectl -n agentgateway logs -l app=agentgateway"
  fi
}

# -----------------------------------------------------------------------------
# Verify
# -----------------------------------------------------------------------------
verify() {
  echo ""
  echo "============================================="
  echo -e "${GREEN}  AgentGateway is running on Kind!${NC}"
  echo "============================================="
  echo ""
  echo "  LLM Gateway:  http://localhost:4000"
  echo "  MCP Gateway:  http://localhost:3000"
  echo "  Admin UI:     http://localhost:15000/ui"
  echo ""
  echo "  Test it:"
  echo ""
  echo "  curl http://localhost:4000/v1/chat/completions \\"
  echo "    -H 'Content-Type: application/json' \\"
  echo "    -d '{\"model\": \"gpt-4o\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}]}'"
  echo ""
  echo "  Useful commands:"
  echo ""
  echo "  kubectl -n agentgateway get pods"
  echo "  kubectl -n agentgateway logs -l app=agentgateway -f"
  echo "  kind delete cluster --name ${CLUSTER_NAME}"
  echo ""
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  echo ""
  echo "==================================================="
  echo "  Migrate to AgentGateway OSS — Kind Cluster Setup"
  echo "==================================================="
  echo ""

  check_prereqs
  create_cluster
  deploy_agentgateway
  wait_for_ready
  verify
}

main "$@"
