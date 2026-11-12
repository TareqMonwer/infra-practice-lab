#!/bin/sh
set -eu

new_image=$1
registry_user=$2
container=devops-app
domain='@DOMAIN_NAME@'
AWS_REGION='@AWS_REGION@'
ENVIRONMENT='@ENVIRONMENT@'

# On first boot, wait for cloud-init to finish installing Docker and AWS CLI.
for _ in $(seq 1 36); do
    if command -v docker >/dev/null && command -v aws >/dev/null && systemctl is-active --quiet docker; then
        break
    fi
    sleep 5
done
command -v docker >/dev/null || { echo "Docker is not installed; bootstrap has not finished" >&2; exit 1; }

previous=$(docker inspect --format '{{.Config.Image}}' "$container" 2>/dev/null || true)
aws ssm get-parameter --region "$AWS_REGION" --name /devops/ghcr-read-token \
    --with-decryption --query Parameter.Value --output text \
    | docker login ghcr.io -u "$registry_user" --password-stdin
docker pull "$new_image"
docker rm -f "$container" >/dev/null 2>&1 || true
if [ -n "$domain" ]; then
    docker run -d --name "$container" --restart unless-stopped --network devops \
        -e PORT=8000 -e ENVIRONMENT="$ENVIRONMENT" "$new_image"
else
    docker run -d --name "$container" --restart unless-stopped -p 80:8000 \
        -e PORT=8000 -e ENVIRONMENT="$ENVIRONMENT" "$new_image"
fi
sleep 8
if ! docker exec "$container" python3 -c \
    'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8000/health", timeout=3)'; then
    docker logs --tail 100 "$container" >&2 || true
    docker rm -f "$container" >/dev/null 2>&1 || true
    if [ -n "$previous" ]; then
        if [ -n "$domain" ]; then
            docker run -d --name "$container" --restart unless-stopped --network devops \
                -e PORT=8000 -e ENVIRONMENT="$ENVIRONMENT" "$previous"
        else
            docker run -d --name "$container" --restart unless-stopped -p 80:8000 \
                -e PORT=8000 -e ENVIRONMENT="$ENVIRONMENT" "$previous"
        fi
    fi
    exit 1
fi
