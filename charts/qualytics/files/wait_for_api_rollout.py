import json
import os
import ssl
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPSHandler, ProxyHandler, Request, build_opener


TOKEN_DIRECTORY = Path("/var/run/secrets/qualytics-migration-gate")


def read_resource(path: str) -> dict:
    context = ssl.create_default_context(cafile=str(TOKEN_DIRECTORY / "ca.crt"))
    opener = build_opener(ProxyHandler({}), HTTPSHandler(context=context))
    request = Request(
        f"https://kubernetes.default.svc{path}",
        headers={"Authorization": f"Bearer {(TOKEN_DIRECTORY / 'token').read_text().strip()}"},
    )
    with opener.open(request, timeout=10) as response:
        return json.load(response)


def wait_reason(deployment: dict, replica_sets: list[dict], pods: list[dict], expected_image: str) -> str | None:
    spec = deployment["spec"]
    image = next(c["image"] for c in spec["template"]["spec"]["containers"] if c["name"] == "api")
    if image != expected_image:
        return "API Deployment has not received this release's image"
    if spec["strategy"]["type"] != "Recreate":
        return "API Deployment must use Recreate before migrations can start"
    if spec.get("paused", False):
        return "API Deployment rollout is paused"
    status = deployment.get("status", {})
    if status.get("observedGeneration", 0) < deployment["metadata"]["generation"]:
        return "API controller has not observed the updated Deployment"
    replicas = spec.get("replicas", 1)
    # An empty Pod list alone is insufficient while an old ReplicaSet can recreate its pods.
    # New pod counts/readiness cannot be required: they may be waiting for these migrations.
    for replica_set in replica_sets:
        rs_spec = replica_set["spec"]
        image = next(c["image"] for c in rs_spec["template"]["spec"]["containers"] if c["name"] == "api")
        if replicas == 0 or image != expected_image:
            if rs_spec.get("replicas", 1) > 0:
                return f"API ReplicaSet {replica_set['metadata']['name']} has not scaled to zero"
            if replica_set.get("status", {}).get("observedGeneration", 0) < replica_set["metadata"]["generation"]:
                return f"API ReplicaSet {replica_set['metadata']['name']} has not observed its scale-down"
    for pod in pods:
        if pod.get("status", {}).get("phase") in {"Failed", "Succeeded"}:
            continue
        image = next(c["image"] for c in pod["spec"]["containers"] if c["name"] == "api")
        if replicas == 0 or image != expected_image:
            return f"API pod {pod['metadata']['name']} has not exited"
    return None


def wait_for_api_rollout(namespace: str, deployment_name: str, expected_image: str) -> None:
    deployment_path = f"/apis/apps/v1/namespaces/{namespace}/deployments/{deployment_name}"
    selector = urlencode({"labelSelector": f"app={deployment_name}"})
    replica_sets_path = f"/apis/apps/v1/namespaces/{namespace}/replicasets?{selector}"
    pods_path = f"/api/v1/namespaces/{namespace}/pods?{selector}"
    deadline = time.monotonic() + 900
    while True:
        try:
            deployment = read_resource(deployment_path)
            replica_sets = read_resource(replica_sets_path)["items"]
            pods = read_resource(pods_path)["items"]
            reason = wait_reason(deployment, replica_sets, pods, expected_image)
            if reason is None:
                print("API rollout drained; migrations may start", flush=True)
                return
        except HTTPError as exc:
            if exc.code not in {404, 429, 500, 502, 503, 504}:
                raise
            reason = f"Kubernetes API returned HTTP {exc.code}"
        except (URLError, TimeoutError, OSError) as exc:
            reason = f"Kubernetes API unavailable: {exc}"
        if time.monotonic() >= deadline:
            raise TimeoutError(f"Timed out waiting for the API rollout: {reason}")
        print(f"Waiting for the API rollout: {reason}", flush=True)
        time.sleep(2)


if __name__ == "__main__":
    wait_for_api_rollout(os.environ["POD_NAMESPACE"], os.environ["API_DEPLOYMENT"], os.environ["CONTROLPLANE_IMAGE"])
