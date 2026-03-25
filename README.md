# Migrate to AgentGateway OSS

A complete migration guide for moving from LiteLLM to [AgentGateway OSS](https://agentgateway.dev) -- covering LLM gateway, MCP gateway, Kubernetes, and binary deployments.

## Pages

- **[index.html](index.html)** - Landing page with overview and comparison
- **[llm-gateway.html](llm-gateway.html)** - LLM Gateway migration (OpenAI/Anthropic config translation)
- **[mcp-gateway.html](mcp-gateway.html)** - MCP Gateway migration (stdio, remote, OpenAPI-to-MCP)
- **[kubernetes.html](kubernetes.html)** - Kubernetes deployment (raw manifests + Helm/Gateway API)
- **[binary.html](binary.html)** - Binary and Docker deployment with quick-start demo

## Config Examples

- `configs/litellm-config.yaml` - Typical LiteLLM LLM proxy config
- `configs/agentgateway-llm.yaml` - Equivalent AgentGateway LLM config
- `configs/agentgateway-llm-advanced.yaml` - Advanced config with failover groups
- `configs/litellm-mcp.yaml` - LiteLLM MCP server config
- `configs/agentgateway-mcp.yaml` - Equivalent AgentGateway MCP config
- `configs/k8s/litellm-deployment.yaml` - LiteLLM K8s manifests
- `configs/k8s/agentgateway-deployment.yaml` - AgentGateway K8s manifests

## Run Locally

Open `index.html` in a browser, or serve with any static file server:

```bash
python3 -m http.server 8080
# then open http://localhost:8080
```
