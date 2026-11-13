import json
import sys
from collections.abc import Iterable
from pathlib import PurePosixPath

SERVICE_ORDER = (
    "app",
    "prometheus",
    "grafana",
    "loki",
    "alloy",
    "node-exporter",
    "cadvisor",
)

SERVICE_PATHS = {
    "app": ("app/", "Dockerfile", ".dockerignore", "requirements.txt"),
    "prometheus": ("monitoring/prometheus/",),
    "grafana": ("monitoring/grafana/",),
    "loki": ("monitoring/loki.yml",),
    "alloy": ("monitoring/alloy.alloy",),
}


def affected_services(paths: Iterable[str]) -> list[str]:
    affected = set()

    for changed_path in paths:
        path = PurePosixPath(changed_path).as_posix().removeprefix("./")

        if path in ("docker-compose.monitoring.yml", "docker-compose.ec2.yml"):
            affected.update(SERVICE_ORDER)
            continue

        if path == "docker-compose.yml":
            affected.add("app")
            continue

        for service, prefixes in SERVICE_PATHS.items():
            if any(path == prefix or path.startswith(prefix) for prefix in prefixes):
                affected.add(service)

    return [service for service in SERVICE_ORDER if service in affected]


if __name__ == "__main__":
    print(json.dumps(affected_services(line.strip() for line in sys.stdin)))
