#!/usr/bin/env python3
"""Exercise an already-built image without third-party Python dependencies."""

import argparse
import contextlib
import json
import pathlib
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET


def docker(*args):
    return subprocess.check_output(["docker", *args], text=True).strip()


def request(port, path, key=None):
    headers = {"X-Api-Key": key} if key else {}
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", headers=headers)
    with urllib.request.urlopen(req, timeout=5) as response:
        return json.load(response)


@contextlib.contextmanager
def running(image, *args):
    container = docker(
        "run", "-d", "--read-only", "--cap-drop=ALL",
        "--security-opt=no-new-privileges:true", "--tmpfs", "/tmp:rw,nosuid,nodev",
        "-p", "127.0.0.1::8989", *args, image,
    )
    try:
        port = docker("port", container, "8989/tcp").rsplit(":", 1)[1]
        for _ in range(120):
            try:
                assert request(port, "/ping")["status"] == "OK"
                break
            except (urllib.error.URLError, TimeoutError, ConnectionError):
                if docker("inspect", "-f", "{{.State.Running}}", container) != "true":
                    raise AssertionError(docker("logs", container)) from None
                time.sleep(1)
        else:
            raise AssertionError(docker("logs", container))
        yield container, port
        docker("stop", "--time", "30", container)
        assert docker("inspect", "-f", "{{.State.ExitCode}}", container) == "0"
    except BaseException:
        print(docker("logs", container))
        raise
    finally:
        docker("rm", "-f", container)


def test(image, version):
    assert docker("image", "inspect", "-f", "{{.Config.User}}", image) == "1000:1000"
    with tempfile.TemporaryDirectory(prefix="sonarr-runtime-") as directory:
        config = pathlib.Path(directory) / "config"
        data = pathlib.Path(directory) / "data"
        config.mkdir()
        data.mkdir()
        mounts = (
            "--mount", f"type=bind,src={config},dst=/config",
            "--mount", f"type=bind,src={data},dst=/data",
        )
        # Reuse the same bind mount to check configuration and SQLite persistence.
        original_key = None
        for _ in range(2):
            with running(image, *mounts) as (container, port):
                key = ET.parse(config / "config.xml").findtext("ApiKey")
                assert key
                if original_key:
                    assert key == original_key
                original_key = key
                status = request(port, "/api/v3/system/status", key)
                assert status["version"] == version, status
                assert status["appData"] == "/config", status
                assert request(port, "/api/v3/qualityprofile", key)
                assert docker("exec", container, "id", "-u") == "1000"
                docker("exec", container, "touch", "/data/write-test")
                assert (data / "write-test").is_file()
                assert (config / "sonarr.db").is_file()
        assert (config / "sonarr.db").stat().st_uid == 1000

    # No passwd entry, root entrypoint, chown, or elevated capabilities required.
    with running(
        image, "--user", "12345:12345", "--tmpfs",
        "/config:rw,nosuid,nodev,uid=12345,gid=12345,mode=0700",
    ) as (container, _):
        assert docker("exec", container, "id", "-u") == "12345"
    print(f"PASS {image}: {version}, non-root, arbitrary UID, read-only rootfs, API, persistence, SIGTERM")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    parser.add_argument("version")
    args = parser.parse_args()
    test(args.image, args.version)
