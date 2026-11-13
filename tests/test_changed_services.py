import json
import subprocess
import sys
from pathlib import Path

import pytest

from scripts.changed_services import SERVICE_ORDER, affected_services


@pytest.mark.parametrize(
    ("paths", "expected"),
    [
        (["app/main.py", "Dockerfile", "requirements.txt"], ["app"]),
        (["scripts/deploy.sh"], ["app"]),
        (["monitoring/grafana/dashboards/application.json"], ["grafana"]),
        (["monitoring/prometheus/alerts.yml"], ["prometheus"]),
        (["monitoring/loki.yml"], ["loki"]),
        (["monitoring/alloy.alloy"], ["alloy"]),
        (["docker-compose.yml"], ["app"]),
        (["docker-compose.monitoring.yml"], list(SERVICE_ORDER)),
        (["docker-compose.ec2.yml"], list(SERVICE_ORDER)),
        (["README.md", ".github/workflows/release.yml"], []),
        (
            ["monitoring/grafana/dashboards/host.json", "monitoring/prometheus/alerts.yml"],
            ["prometheus", "grafana"],
        ),
    ],
)
def test_affected_services(paths, expected):
    assert affected_services(paths) == expected


def test_cli_reads_changed_paths_from_stdin():
    script = Path(__file__).parents[1] / "scripts" / "changed_services.py"
    result = subprocess.run(
        [sys.executable, str(script)],
        input="app/main.py\nmonitoring/grafana/dashboards/application.json\n",
        capture_output=True,
        check=True,
        text=True,
    )

    assert json.loads(result.stdout) == ["app", "grafana"]


@pytest.mark.parametrize(
    ("arguments", "expected_error"),
    [
        (
            ["unknown-service", "s3://bucket/releases/" + "a" * 40 + "/deploy-bundle.tar.gz",
             "/tmp/deploy-bundle.tar.gz", "ghcr.io/example/app:sha-" + "a" * 40, "reader",
             "us-east-1", "staging"],
            "Unsupported service",
        ),
        (
            ["app", "s3://bucket/releases/short/deploy-bundle.tar.gz",
             "/tmp/deploy-bundle.tar.gz", "ghcr.io/example/app:sha-" + "a" * 40, "reader",
             "us-east-1", "staging"],
            "full Git commit SHA",
        ),
        (
            ["app", "s3://bucket/releases/" + "a" * 40 + "/deploy-bundle.tar.gz",
             "/tmp/deploy-bundle.tar.gz", "ghcr.io/example/app:sha-" + "b" * 40, "reader",
             "us-east-1", "staging"],
            "do not match",
        ),
    ],
)
def test_deploy_script_rejects_invalid_target_or_release(arguments, expected_error):
    script = Path(__file__).parents[1] / "scripts" / "deploy.sh"
    result = subprocess.run(
        ["sh", str(script), *arguments],
        capture_output=True,
        check=False,
        text=True,
    )

    assert result.returncode == 2
    assert expected_error in result.stderr
