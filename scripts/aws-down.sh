#!/usr/bin/env bash
set -euo pipefail
AWS_REGION=${AWS_REGION:-us-east-1}
ENVIRONMENT=${ENVIRONMENT:-staging}
if [[ $ENVIRONMENT != staging && $ENVIRONMENT != production ]]; then
  echo "ENVIRONMENT must be staging or production" >&2
  exit 2
fi
command -v aws >/dev/null || { echo "Install AWS CLI v2 first." >&2; exit 2; }
command -v terraform >/dev/null || { echo "Install Terraform 1.10 or newer first." >&2; exit 2; }
command -v gh >/dev/null || { echo "Install and authenticate GitHub CLI (gh) first." >&2; exit 2; }
aws sts get-caller-identity >/dev/null
STATE_BUCKET=$(terraform -chdir=terraform/bootstrap output -raw state_bucket_name)
cat > terraform/backend.hcl <<BACKEND
bucket       = "${STATE_BUCKET}"
key          = "$(gh repo view --json nameWithOwner --jq .nameWithOwner | tr '/' '-')/${ENVIRONMENT}.tfstate"
region       = "${AWS_REGION}"
use_lockfile = true
BACKEND

echo "This destroys the ${ENVIRONMENT} EC2 app, IAM roles, security group, log group, state bucket (including versions), and GitHub OIDC provider."
read -r -p 'Type destroy to continue: ' CONFIRM
if [[ $CONFIRM != destroy ]]; then echo "Cancelled."; exit 1; fi
terraform -chdir=terraform init -reconfigure -backend-config=backend.hcl
terraform -chdir=terraform destroy -auto-approve -var-file=assessment.auto.tfvars.json
aws ssm delete-parameter --region "$AWS_REGION" --name "/devops/${ENVIRONMENT}/ghcr-read-token" 2>/dev/null || true
aws ssm delete-parameter --region "$AWS_REGION" --name "/devops/${ENVIRONMENT}/grafana-admin-password" 2>/dev/null || true
terraform -chdir=terraform/bootstrap destroy -auto-approve \
  -var="aws_region=${AWS_REGION}" \
  -var="state_bucket_name=${STATE_BUCKET}"
for VARIABLE in AWS_ROLE_ARN AWS_REGION DEPLOY_INSTANCE_ID GHCR_USERNAME DEPLOY_BUNDLE_BUCKET DEPLOY_ENVIRONMENT; do
  gh variable delete "$VARIABLE" 2>/dev/null || true
done
rm -f terraform/backend.hcl terraform/assessment.auto.tfvars.json
echo "AWS resources destroyed. Local bootstrap state remains so the stack can be recreated; keep it, or remove terraform/bootstrap/terraform.tfstate after you no longer need it."
