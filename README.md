# Hermes Agent on Amazon EKS with Kata Containers

Deploy [Hermes Agent](https://github.com/nousresearch/hermes-agent) on Amazon EKS with VM-level sandbox isolation via Kata Containers.

Based on the [OpenClaw on EKS](https://github.com/hitsub2/openclaw-on-eks) architecture, adapted for Hermes Agent. Source: [aws-eks-kata](https://github.com/hitsub2/aws-eks-kata).

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                   Amazon EKS                         │
│                                                      │
│  ┌──────────────┐  ┌──────────────────────────────┐ │
│  │  Core Nodes   │  │  Bare Metal Nodes (Karpenter)│ │
│  │  (m5.xlarge)  │  │  (c8i/m8i, nested KVM)      │ │
│  │               │  │                              │ │
│  │  LiteLLM      │  │  ┌────────────────────────┐ │ │
│  │  Prometheus   │  │  │  Kata VM (CLH/QEMU)    │ │ │
│  │  Grafana      │  │  │  ┌──────────────────┐  │ │ │
│  │               │  │  │  │  Hermes Agent    │  │ │ │
│  │               │  │  │  │  Gateway + API   │  │ │ │
│  │               │  │  │  │  Port 8642/9119  │  │ │ │
│  │               │  │  │  └──────────────────┘  │ │ │
│  │               │  │  │  EBS Vol (/opt/data)   │ │ │
│  │               │  │  └────────────────────────┘ │ │
│  └──────────────┘  └──────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
         │                        │
         ▼                        ▼
   Amazon Bedrock          Feishu / Slack /
   (via LiteLLM)           Telegram / Discord
```

## Components

| Component | Purpose |
|---|---|
| **EKS** | Managed Kubernetes control plane |
| **Karpenter** | Auto-provision c8i/m8i nodes with nested KVM for Kata VMs |
| **Kata Containers** | VM-level isolation per sandbox pod (QEMU + CLH) |
| **LiteLLM** | Unified model gateway (Bedrock, SiliconFlow, etc.) |
| **Hermes Agent** | Self-improving AI agent with multi-platform messaging |
| **Prometheus + Grafana** | Observability stack |

## Key Differences from OpenClaw Version

| Aspect | OpenClaw | Hermes Agent |
|---|---|---|
| Agent image | `ghcr.io/openclaw/openclaw` | `nousresearch/hermes-agent` |
| Data path | `/home/node/.openclaw` | `/opt/data` |
| Entry command | `node dist/index.js gateway` | `gateway run` |
| Ports | 18789/18790 | 8642 (API) / 9119 (Dashboard) |
| Health check | None | `/health` on port 8642 |
| RuntimeClass | `kata-qemu` | `kata-clh` (recommended) |
| Operator CRD | OpenClaw Sandbox CRD | Native K8s Pod/Service |
| Model config | JSON in container | `config.yaml` via ConfigMap |
| Messaging | Per-platform containers | Single gateway, multi-platform |
| User ID | 1000 | 10000 |

## Prerequisites

- AWS CLI configured
- kubectl
- Terraform >= 1.3.2
- Helm v3.x

## Quick Start

```bash
git clone https://github.com/hitsub2/aws-eks-kata
cd aws-eks-kata
chmod +x install.sh
./install.sh
```

Custom region/name:

```bash
./install.sh --region ap-southeast-1 --cluster-name my-hermes
```

### Generate LiteLLM API Key

```bash
MASTER_KEY=$(kubectl get secret litellm-masterkey -n litellm \
  -o jsonpath='{.data.masterkey}' | base64 -d)

LITELLM_API_KEY=$(kubectl run -n litellm gen-key --rm -i \
  --restart=Never --image=curlimages/curl -- \
  curl -s -X POST http://litellm:4000/key/generate \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"models": ["claude-opus-4-6"], "duration": "30d"}' \
  | grep -o '"key":"[^"]*"' | cut -d'"' -f4)
```

### Verify Bedrock Connectivity

```bash
kubectl run -n litellm test --rm -i --restart=Never \
  --image=curlimages/curl -- \
  curl -s -X POST http://litellm:4000/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-opus-4-6", "messages": [{"role": "user", "content": "Hi"}], "max_tokens": 20}'
```

### Deploy a Sandbox

**Feishu:**

```bash
cd examples
export FEISHU_APP_ID="cli_..."
export FEISHU_APP_SECRET="..."

sed -i.bak \
  -e "s/YOUR_LITELLM_API_KEY/${LITELLM_API_KEY}/g" \
  -e "s/YOUR_FEISHU_APP_ID/${FEISHU_APP_ID}/g" \
  -e "s/YOUR_FEISHU_APP_SECRET/${FEISHU_APP_SECRET}/g" \
  -e "s/YOUR_API_SERVER_KEY/$(openssl rand -hex 32)/g" \
  hermes-feishu-sandbox.yaml

kubectl apply -f hermes-feishu-sandbox.yaml
```

**Slack:**

```bash
cd examples
export SLACK_BOT_TOKEN="xoxb-..."
export SLACK_APP_TOKEN="xapp-..."

sed -i.bak \
  -e "s/YOUR_LITELLM_API_KEY/${LITELLM_API_KEY}/g" \
  -e "s/YOUR_BOT_TOKEN/${SLACK_BOT_TOKEN}/g" \
  -e "s/YOUR_APP_TOKEN/${SLACK_APP_TOKEN}/g" \
  -e "s/YOUR_API_SERVER_KEY/$(openssl rand -hex 32)/g" \
  hermes-slack-sandbox.yaml

kubectl apply -f hermes-slack-sandbox.yaml
```

**Telegram:**

```bash
cd examples
export TELEGRAM_BOT_TOKEN="..."

sed -i.bak \
  -e "s/YOUR_LITELLM_API_KEY/${LITELLM_API_KEY}/g" \
  -e "s/YOUR_TELEGRAM_BOT_TOKEN/${TELEGRAM_BOT_TOKEN}/g" \
  -e "s/YOUR_API_SERVER_KEY/$(openssl rand -hex 32)/g" \
  hermes-telegram-sandbox.yaml

kubectl apply -f hermes-telegram-sandbox.yaml
```

### Verify

```bash
kubectl get pods -n hermes
kubectl logs -f hermes-feishu-sandbox -n hermes
```

### Access Dashboard

```bash
kubectl port-forward -n hermes pod/hermes-feishu-sandbox 9119:9119
# Open http://localhost:9119
```

## Kata Hypervisor Selection

Default: **Cloud Hypervisor (CLH)** -- best balance of performance and compatibility.

| Feature | QEMU | CLH | Firecracker |
|---|---|---|---|
| virtio-fs | Yes | Yes | No |
| Hotplug | Yes | Yes | No |
| Boot time | ~500ms | ~200ms | ~125ms |
| Memory/VM | ~30-130MB | ~10-20MB | ~5MB |

Switch hypervisor via RuntimeClass in sandbox YAML:

```yaml
spec:
  runtimeClassName: kata-clh    # or kata-qemu
```

Or set default at deploy time:

```bash
./install.sh --region us-west-2 --cluster-name my-hermes
```

See [docs/isolation-backends-analysis.md](docs/isolation-backends-analysis.md) for detailed comparison including Firecracker and gVisor.

## Migrating from OpenClaw

Hermes Agent includes built-in migration tooling:

```bash
kubectl exec -it hermes-feishu-sandbox -n hermes -- hermes claw migrate
```

This imports SOUL.md, memories, skills, messaging config, and API keys from an existing OpenClaw installation.

## Monitoring

```bash
# Grafana password
terraform output -raw grafana_admin_password

# Port forward
kubectl port-forward -n monitoring svc/grafana 3000:80
```

## Cleanup

```bash
kubectl delete -f examples/ --ignore-not-found=true
terraform destroy
```

## File Structure

```
.
├── main.tf                  # Providers and locals
├── variables.tf             # Input variables
├── outputs.tf               # Output values
├── versions.tf              # Terraform/provider versions
├── vpc.tf                   # VPC with public/private subnets
├── eks.tf                   # EKS cluster and core node group
├── karpenter.tf             # Karpenter + nested KVM NodePool (c8i/m8i)
├── kata.tf                  # Namespaces (kata-system, hermes)
├── kata-deploy.tf           # Kata Containers Helm release
├── litellm.tf               # LiteLLM proxy + Bedrock IAM
├── hermes-bedrock.tf        # IRSA for direct Bedrock access
├── hermes-config.tf         # Base ConfigMap + NetworkPolicy
├── ebs-csi-driver.tf        # EBS CSI driver IRSA
├── ebs-storageclass.tf      # gp3 StorageClass
├── efs-csi-driver.tf        # EFS + CSI driver + StorageClass
├── eks-blueprints-addons.tf # AWS LB Controller
├── monitoring.tf            # Prometheus + Grafana
├── install.sh               # Deployment script
├── cleanup.sh               # Teardown script
├── examples/
│   ├── hermes-feishu-sandbox.yaml
│   ├── hermes-slack-sandbox.yaml
│   ├── hermes-telegram-sandbox.yaml
│   └── grafana/
│       └── grafana_dashboard.json
└── docs/
    ├── blog-hermes-agent.md
    ├── blog.md
    └── isolation-backends-analysis.md
```
