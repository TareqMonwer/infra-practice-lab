#!/bin/sh
set -eu
# Repo copy of /opt/devops/deploy.sh (created by terraform/user_data.sh.tftpl).
new_image=$1 user=$2
container=devops-app
# On a freshly bootstrapped host cloud-init may still be installing Docker.
for _ in $(seq 1 36); do
    if command -v docker >/dev/null && command -v aws >/dev/null && systemctl is-active --quiet docker; then break; fi
    sleep 5
done
command -v docker >/dev/null || { echo "docker is not installed yet" >&2; exit 1; }
previous=$(docker inspect --format '{{.Config.Image}}' "$container" 2>/dev/null || true)
aws ssm get-parameter --region "${AWS_REGION:-ap-southeast-1}" --name /devops/ghcr-read-token --with-decryption --query Parameter.Value --output text | docker login ghcr.io -u "$user" --password-stdin
docker pull "$new_image"
docker rm -f "$container" >/dev/null 2>&1 || true
docker run -d --name "$container" --restart unless-stopped -p 80:8000 -e PORT=8000 -e ENVIRONMENT="${ENVIRONMENT:-production}" "$new_image"
sleep 8
if ! curl -fsS http://127.0.0.1/health >/dev/null; then
    docker rm -f "$container" >/dev/null 2>&1 || true
    if [ -n "$previous" ]; then docker run -d --name "$container" --restart unless-stopped -p 80:8000 -e PORT=8000 -e ENVIRONMENT="${ENVIRONMENT:-production}" "$previous"; fi
    exit 1
fi
