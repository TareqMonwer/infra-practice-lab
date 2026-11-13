#!/bin/sh
set -eu

service=${1:?usage: deploy.sh SERVICE BUNDLE_URI BUNDLE_ARCHIVE '[IMAGE]' REGISTRY_USER AWS_REGION ENVIRONMENT}
bundle_uri=${2:?usage: deploy.sh SERVICE BUNDLE_URI BUNDLE_ARCHIVE '[IMAGE]' REGISTRY_USER AWS_REGION ENVIRONMENT}
archive=${3:?usage: deploy.sh SERVICE BUNDLE_URI BUNDLE_ARCHIVE '[IMAGE]' REGISTRY_USER AWS_REGION ENVIRONMENT}
new_image=${4-}
registry_user=${5:?usage: deploy.sh SERVICE BUNDLE_URI BUNDLE_ARCHIVE '[IMAGE]' REGISTRY_USER AWS_REGION ENVIRONMENT}
AWS_REGION=${6:?usage: deploy.sh SERVICE BUNDLE_URI BUNDLE_ARCHIVE '[IMAGE]' REGISTRY_USER AWS_REGION ENVIRONMENT}
ENVIRONMENT=${7:?usage: deploy.sh SERVICE BUNDLE_URI BUNDLE_ARCHIVE '[IMAGE]' REGISTRY_USER AWS_REGION ENVIRONMENT}
release_root=/opt/devops/releases
state_root=/opt/devops/state
Supported_services='app prometheus grafana loki alloy node-exporter cadvisor'

case "$ENVIRONMENT" in
    staging|production) ;;
    *) echo "Unsupported deployment environment: $ENVIRONMENT" >&2; exit 2 ;;
esac

case " $Supported_services " in
    *" $service "*) ;;
    *) echo "Unsupported service: $service" >&2; exit 2 ;;
esac

if [ "$service" = app ]; then
    printf '%s' "$new_image" | grep -Eq '^ghcr\.io/[a-z0-9._/-]+:sha-[0-9a-f]{40}$' || {
        echo "Expected a GHCR image tagged with a full commit SHA" >&2
        exit 2
    }
fi
case "$bundle_uri" in
    s3://*/releases/*/deploy-bundle.tar.gz) ;;
    *) echo "Expected a commit-specific deployment bundle S3 URI" >&2; exit 2 ;;
esac

commit_sha=$(basename "$(dirname "$bundle_uri")")
printf '%s' "$commit_sha" | grep -Eq '^[0-9a-f]{40}$' || {
    echo "Bundle path does not contain a full Git commit SHA" >&2
    exit 2
}
if [ "$service" = app ]; then
    image_sha=${new_image##*:sha-}
    [ "$image_sha" = "$commit_sha" ] || {
        echo "Bundle commit SHA and app image SHA do not match" >&2
        exit 2
    }
fi

for _ in $(seq 1 60); do
    if command -v docker >/dev/null && command -v aws >/dev/null \
        && systemctl is-active --quiet docker; then
        break
    fi
    sleep 5
done
command -v docker >/dev/null || { echo "Docker is not installed; bootstrap has not finished" >&2; exit 1; }
command -v aws >/dev/null || { echo "AWS CLI is not installed; bootstrap has not finished" >&2; exit 1; }
if ! docker compose version >/dev/null 2>&1; then
    command -v curl >/dev/null || { echo "curl is required to install Docker Compose" >&2; exit 1; }
    command -v sha256sum >/dev/null || { echo "sha256sum is required to verify Docker Compose" >&2; exit 1; }
    compose_tmp=$(mktemp)
    if ! curl -fsSL \
        https://github.com/docker/compose/releases/download/v2.39.4/docker-compose-linux-x86_64 \
        -o "$compose_tmp"; then
        rm -f "$compose_tmp"
        echo "Could not download Docker Compose v2.39.4" >&2
        exit 1
    fi
    if ! printf '%s  %s\n' \
        7af95166a730b87e172d4fc9aefea8725d3c6c7327d59149267b452114ddb7d4 "$compose_tmp" \
        | sha256sum --check --status; then
        rm -f "$compose_tmp"
        echo "Docker Compose v2.39.4 checksum verification failed" >&2
        exit 1
    fi
    install -D -m 0755 "$compose_tmp" /usr/local/lib/docker/cli-plugins/docker-compose
    rm -f "$compose_tmp"
    docker compose version
fi

mkdir -p "$release_root" "$state_root"
[ -f "$archive" ] || { echo "Downloaded deployment bundle is missing" >&2; exit 1; }
if tar -tzf "$archive" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    echo "Deployment bundle contains an unsafe archive path" >&2
    exit 1
fi

release_dir="$release_root/$commit_sha"
mkdir -p "$release_dir"
tar -xzf "$archive" -C "$release_dir"
compose_file="$release_dir/docker-compose.ec2.yml"
[ -f "$compose_file" ] || { echo "Compose file missing from deployment bundle" >&2; exit 1; }

if [ "$service" = app ]; then
    aws ssm get-parameter --region "$AWS_REGION" --name "/devops/${ENVIRONMENT}/ghcr-read-token" \
        --with-decryption --query Parameter.Value --output text \
        | docker login ghcr.io -u "$registry_user" --password-stdin
    docker pull "$new_image"
    app_image=$new_image
else
    app_container=$(docker ps -q \
        --filter label=com.docker.compose.project=devops \
        --filter label=com.docker.compose.service=app | head -n 1)
    if [ -z "$app_container" ]; then
        echo "Cannot deploy $service before the app service is running" >&2
        exit 1
    fi
    app_image=$(docker inspect --format '{{.Config.Image}}' "$app_container")
fi
grafana_password=
if [ "$service" = grafana ]; then
    grafana_password=$(aws ssm get-parameter --region "$AWS_REGION" \
        --name "/devops/${ENVIRONMENT}/grafana-admin-password" --with-decryption \
        --query Parameter.Value --output text)
fi

umask 077
env_file="$release_dir/.env"
cat >"$env_file" <<EOF
APP_IMAGE=$app_image
APP_VERSION=$commit_sha
ENVIRONMENT=$ENVIRONMENT
GRAFANA_PASSWORD=$grafana_password
EOF

compose() {
    docker compose --project-name devops --project-directory "$release_dir" \
        --env-file "$env_file" -f "$compose_file" "$@"
}
compose config --quiet

previous_release=$(cat "$state_root/${service}.release" 2>/dev/null || true)
previous_container=$(docker ps -aq \
    --filter label=com.docker.compose.project=devops \
    --filter "label=com.docker.compose.service=${service}" | head -n 1)
if [ -z "$previous_container" ] && [ "$service" = app ]; then
    previous_container=$(docker inspect --format '{{.Id}}' devops-app 2>/dev/null || true)
fi
previous_image=
if [ -n "$previous_container" ]; then
    previous_image=$(docker inspect --format '{{.Config.Image}}' "$previous_container")
fi

wait_for_health() {
    for _ in $(seq 1 30); do
        container_id=$(docker ps -q \
            --filter label=com.docker.compose.project=devops \
            --filter "label=com.docker.compose.service=${service}" | head -n 1)
        if [ -n "$container_id" ]; then
            case "$service" in
                app)
                    health=$(docker inspect --format '{{.State.Health.Status}}' "$container_id" 2>/dev/null || true)
                    if [ "$health" = healthy ] && curl --fail --silent --show-error --max-time 5 http://127.0.0.1/health >/dev/null; then
                        return 0
                    fi
                    ;;
                grafana)
                    if curl --fail --silent --show-error --max-time 5 http://127.0.0.1:3000/api/health >/dev/null; then
                        return 0
                    fi
                    ;;
                *)
                    running=$(docker inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null || true)
                    if [ "$running" = true ]; then
                        return 0
                    fi
                    ;;
            esac
        fi
        sleep 2
    done
    return 1
}

restore_previous() {
    if [ -z "$previous_image" ]; then
        echo "There was no previous $service image to restore" >&2
        return 1
    fi

    rollback_release=$release_dir
    if [ -n "$previous_release" ] && [ -f "$previous_release/docker-compose.ec2.yml" ]; then
        rollback_release=$previous_release
    fi
    rollback_env="$rollback_release/.env"
    if [ ! -f "$rollback_env" ]; then
        rollback_app_image=$app_image
        if [ "$service" = app ]; then
            rollback_app_image=$previous_image
        fi
        cat >"$rollback_env" <<EOF
APP_IMAGE=$rollback_app_image
APP_VERSION=$(basename "$rollback_release")
ENVIRONMENT=$ENVIRONMENT
GRAFANA_PASSWORD=$grafana_password
EOF
        chmod 600 "$rollback_env"
    elif [ "$service" = app ]; then
        sed "s|^APP_IMAGE=.*$|APP_IMAGE=$previous_image|" "$rollback_env" >"$rollback_env.tmp"
        mv "$rollback_env.tmp" "$rollback_env"
    fi
    if ! docker compose --project-name devops --project-directory "$rollback_release" \
        --env-file "$rollback_env" -f "$rollback_release/docker-compose.ec2.yml" \
        up -d --no-deps "$service"; then
        echo "Rollback could not start previous $service image: $previous_image" >&2
        return 1
    fi
    if ! wait_for_health; then
        echo "Rollback started $previous_image, but its health check failed" >&2
        return 1
    fi
    echo "Restored healthy $service image: $previous_image" >&2
}

# Remove the legacy standalone container if it still owns host port 80.
if [ "$service" = app ]; then
    docker rm -f devops-app >/dev/null 2>&1 || true
fi

if ! compose up -d --no-deps "$service"; then
    echo "Compose failed to start $service; collecting diagnostics." >&2
    compose ps >&2 || true
    compose logs --tail 100 "$service" >&2 || true
    if ! restore_previous; then
        echo "$service deployment failed and rollback was unsuccessful" >&2
    fi
    exit 1
fi

if ! wait_for_health; then
    echo "$service health check failed; collecting diagnostics and rolling back." >&2
    compose ps >&2 || true
    compose logs --tail 100 "$service" >&2 || true
    compose rm --stop --force "$service" >/dev/null 2>&1 || true
    if ! restore_previous; then
        echo "$service health check failed and rollback was unsuccessful" >&2
    fi
    exit 1
fi

printf '%s\n' "$release_dir" >"$state_root/${service}.release"
chmod 600 "$state_root/${service}.release"
echo "Deployed $service image ${new_image:-$service} from release $commit_sha"
