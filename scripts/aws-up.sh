#!/usr/bin/env bash
set -euo pipefail

AWS_REGION=${AWS_REGION:-ap-southeast-1}
ENVIRONMENT=${ENVIRONMENT:-staging}
if [[ $ENVIRONMENT != staging && $ENVIRONMENT != production ]]; then
  echo "ENVIRONMENT must be staging or production" >&2
  exit 2
fi
command -v aws >/dev/null || { echo "Install AWS CLI v2 first." >&2; exit 2; }
command -v terraform >/dev/null || { echo "Install Terraform 1.10 or newer first." >&2; exit 2; }
command -v gh >/dev/null || { echo "Install and authenticate GitHub CLI (gh) first." >&2; exit 2; }
command -v curl >/dev/null || { echo "curl is required to determine your public IP." >&2; exit 2; }
aws sts get-caller-identity >/dev/null
gh auth status >/dev/null

REPOSITORY=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
GHCR_USER=$(gh api user --jq .login)
CURRENT_BRANCH=$(git branch --show-current)
if [[ $CURRENT_BRANCH != main ]]; then
  echo "Run this from the main branch after pushing the commit and waiting for its Release and deploy workflow." >&2
  exit 2
fi
if [[ -n $(git status --porcelain) ]]; then
  echo "Commit and push all changes before provisioning; the EC2 image must match main." >&2
  exit 2
fi
COMMIT_SHA=$(git rev-parse HEAD)
if ! gh run list --workflow release.yml --branch main --limit 30 --json headSha,conclusion --jq "any(.[]; .headSha == \"${COMMIT_SHA}\" and .conclusion == \"success\")" | grep -qx true; then
  echo "The Release and deploy workflow for this main commit has not succeeded. Wait for its publish job before continuing." >&2
  exit 2
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
STATE_BUCKET="devops-assessment-tfstate-${ACCOUNT_ID}-${AWS_REGION}"
PUBLIC_IP=$(curl -fsS https://checkip.amazonaws.com | tr -d '\n')
ALLOWED_CIDR=${ALLOWED_CIDR:-"${PUBLIC_IP}/32"}
IMAGE="ghcr.io/${REPOSITORY,,}:sha-${COMMIT_SHA}"

printf 'AWS account: %s\nRegion: %s\nGitHub repo: %s\nEnvironment: %s\nImage: %s\nHTTP allowlist: %s\n' "$ACCOUNT_ID" "$AWS_REGION" "$REPOSITORY" "$ENVIRONMENT" "$IMAGE" "$ALLOWED_CIDR"
echo "Enter a read:packages token for ${GHCR_USER}; it will be stored as an encrypted SSM SecureString."
read -r -s -p 'GHCR read token: ' GHCR_READ_TOKEN
echo
if [[ -z $GHCR_READ_TOKEN ]]; then echo "A GHCR read token is required for the EC2 host." >&2; exit 2; fi

# Bootstrap uses local state so that it can create the remote state bucket and OIDC provider.
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply -auto-approve \
  -var="aws_region=${AWS_REGION}" \
  -var="state_bucket_name=${STATE_BUCKET}"
OIDC_PROVIDER_ARN=$(terraform -chdir=terraform/bootstrap output -raw github_oidc_provider_arn)

# GitHub's immutable OIDC subject includes the numeric owner and repository IDs.
OIDC_SUBJECT=$(gh api "repos/${REPOSITORY}" --jq '"repo:\(.owner.login)@\(.owner.id)/\(.name)@\(.id):ref:refs/heads/main"')
aws ssm put-parameter --region "$AWS_REGION" --name /devops/ghcr-read-token \
  --type SecureString --overwrite --value "$GHCR_READ_TOKEN" >/dev/null
unset GHCR_READ_TOKEN

cat > terraform/backend.hcl <<BACKEND
bucket       = "${STATE_BUCKET}"
key          = "${REPOSITORY//\//-}/${ENVIRONMENT}.tfstate"
region       = "${AWS_REGION}"
use_lockfile = true
BACKEND
cat > terraform/assessment.auto.tfvars.json <<VARS
{
  "aws_region": "${AWS_REGION}",
  "environment": "${ENVIRONMENT}",
  "allowed_cidrs": ["${ALLOWED_CIDR}"],
  "image": "${IMAGE}",
  "github_oidc_provider_arn": "${OIDC_PROVIDER_ARN}",
  "github_oidc_subject": "${OIDC_SUBJECT}",
  "ghcr_username": "${GHCR_USER}"
}
VARS
terraform -chdir=terraform init -reconfigure -backend-config=backend.hcl
terraform -chdir=terraform plan -var-file=assessment.auto.tfvars.json
terraform -chdir=terraform apply -auto-approve -var-file=assessment.auto.tfvars.json
ROLE_ARN=$(terraform -chdir=terraform output -raw github_actions_role_arn)
INSTANCE_ID=$(terraform -chdir=terraform output -raw instance_id)
gh variable set AWS_ROLE_ARN --body "$ROLE_ARN"
gh variable set GHCR_USERNAME --body "$GHCR_USER"
gh variable set AWS_REGION --body "$AWS_REGION"
gh variable set DEPLOY_INSTANCE_ID --body "$INSTANCE_ID"

echo "Infrastructure is created. Trigger the release workflow on main to deploy and health-check the app."
gh workflow run release.yml --ref main
echo "Track it with: gh run list --workflow release.yml --branch main --limit 3"
PUBLIC_IP_OUT=$(terraform -chdir=terraform output -raw public_ip)
echo "After a successful run, open http://${PUBLIC_IP_OUT}."
