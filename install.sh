#!/bin/bash

set -e

REGION="us-west-2"
CLUSTER_NAME="hermes-kata-eks"

while [[ $# -gt 0 ]]; do
  case $1 in
    --region)
      REGION="$2"
      shift 2
      ;;
    --cluster-name)
      CLUSTER_NAME="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--region REGION] [--cluster-name CLUSTER_NAME]"
      exit 1
      ;;
  esac
done

echo "============================================"
echo "  Hermes Agent on EKS - Deployment Script"
echo "============================================"
echo "Region:       $REGION"
echo "Cluster Name: $CLUSTER_NAME"
echo "============================================"

# Check prerequisites
for cmd in aws kubectl terraform helm; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "ERROR: $cmd is required but not installed."
    exit 1
  fi
done

echo "All prerequisites satisfied."

# Terraform init
echo ""
echo ">>> Initializing Terraform..."
terraform init

# Terraform plan
echo ""
echo ">>> Planning infrastructure..."
terraform plan \
  -var="region=$REGION" \
  -var="name=$CLUSTER_NAME" \
  -out=tfplan

# Confirm
echo ""
read -p "Proceed with deployment? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Deployment cancelled."
  exit 0
fi

# Terraform apply
echo ""
echo ">>> Deploying infrastructure (this takes ~15-20 minutes)..."
terraform apply tfplan

# Configure kubectl
echo ""
echo ">>> Configuring kubectl..."
aws eks --region "$REGION" update-kubeconfig --name "$CLUSTER_NAME"

echo ""
echo "============================================"
echo "  Deployment Complete!"
echo "============================================"
echo ""
echo "Next steps:"
echo ""
echo "1. Generate LiteLLM API Key:"
echo "   MASTER_KEY=\$(kubectl get secret litellm-masterkey -n litellm \\"
echo "     -o jsonpath='{.data.masterkey}' | base64 -d)"
echo ""
echo "   LITELLM_API_KEY=\$(kubectl run -n litellm gen-key --rm -i \\"
echo "     --restart=Never --image=curlimages/curl -- \\"
echo "     curl -s -X POST http://litellm:4000/key/generate \\"
echo "     -H \"Authorization: Bearer \$MASTER_KEY\" \\"
echo "     -H \"Content-Type: application/json\" \\"
echo "     -d '{\"models\": [\"claude-opus-4-6\"], \"duration\": \"30d\"}' \\"
echo "     | grep -o '\"key\":\"[^\"]*\"' | cut -d'\"' -f4)"
echo ""
echo "2. Deploy a Hermes Agent sandbox:"
echo "   cd examples"
echo "   # Edit hermes-feishu-sandbox.yaml with your credentials"
echo "   sed -i.bak \\"
echo "     -e \"s/YOUR_LITELLM_API_KEY/\${LITELLM_API_KEY}/g\" \\"
echo "     -e \"s/YOUR_FEISHU_APP_ID/\${FEISHU_APP_ID}/g\" \\"
echo "     -e \"s/YOUR_FEISHU_APP_SECRET/\${FEISHU_APP_SECRET}/g\" \\"
echo "     hermes-feishu-sandbox.yaml"
echo "   kubectl apply -f hermes-feishu-sandbox.yaml"
echo ""
echo "3. Verify:"
echo "   kubectl get pods -n hermes"
echo "   kubectl logs -f hermes-feishu-sandbox -n hermes"
echo ""
echo "4. Grafana dashboard:"
echo "   terraform output -raw grafana_admin_password"
echo "   kubectl port-forward -n monitoring svc/grafana 3000:80"
echo ""
