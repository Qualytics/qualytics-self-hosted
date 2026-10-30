import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError, URLError


spec = importlib.util.spec_from_file_location(
    "migration_gate", Path(__file__).resolve().parents[1] / "files" / "wait_for_api_rollout.py"
)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class MigrationGateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.deployment = {
            "metadata": {"generation": 2},
            "spec": {
                "replicas": 4,
                "strategy": {"type": "Recreate"},
                "template": {"spec": {"containers": [{"name": "api", "image": "controlplane:new"}]}},
            },
            "status": {"observedGeneration": 2, "updatedReplicas": 3, "readyReplicas": 0},
        }
        self.replica_sets = [
            self.replica_set("controlplane:new", 3),
            self.replica_set("controlplane:old", 0),
        ]

    def replica_set(self, image: str, replicas: int) -> dict:
        return {
            "metadata": {"name": f"api-{image.rsplit(':', 1)[-1]}", "generation": 2},
            "spec": {
                "replicas": replicas,
                "template": {"spec": {"containers": [{"name": "api", "image": image}]}},
            },
            "status": {"observedGeneration": 2},
        }

    def pod(self, image: str, phase: str = "Running") -> dict:
        return {
            "metadata": {"name": "api-pod"},
            "spec": {"containers": [{"name": "api", "image": image}]},
            "status": {"phase": phase},
        }

    def test_waits_for_api_deployment_image_update(self) -> None:
        self.deployment["spec"]["template"]["spec"]["containers"][0]["image"] = "controlplane:old"
        self.assertIsNotNone(gate.wait_reason(self.deployment, self.replica_sets, [], "controlplane:new"))

    def test_rejects_rolling_update(self) -> None:
        self.deployment["spec"]["strategy"]["type"] = "RollingUpdate"
        self.assertIsNotNone(gate.wait_reason(self.deployment, self.replica_sets, [], "controlplane:new"))

    def test_paused_deployment_cannot_release_gate(self) -> None:
        self.deployment["spec"]["paused"] = True
        self.assertIsNotNone(gate.wait_reason(self.deployment, self.replica_sets, [], "controlplane:new"))

    def test_waits_for_controller_to_observe_new_generation(self) -> None:
        self.deployment["status"]["observedGeneration"] = 1
        self.assertIsNotNone(gate.wait_reason(self.deployment, self.replica_sets, [], "controlplane:new"))

    def test_old_replica_set_can_recreate_pods_despite_empty_pod_list(self) -> None:
        self.replica_sets[1]["spec"]["replicas"] = 1
        self.assertIsNotNone(gate.wait_reason(self.deployment, self.replica_sets, [], "controlplane:new"))

    def test_old_replica_set_must_observe_scale_down_before_empty_pod_list_releases_gate(self) -> None:
        self.replica_sets[1]["status"]["observedGeneration"] = 1
        self.assertIsNotNone(gate.wait_reason(self.deployment, self.replica_sets, [], "controlplane:new"))

    def test_adopting_stalled_rollout_allows_three_new_init_pods_after_old_rs_drains(self) -> None:
        pods = [self.pod("controlplane:new", "Pending") for _ in range(3)]
        self.assertIsNone(gate.wait_reason(self.deployment, self.replica_sets, pods, "controlplane:new"))

    def test_old_api_blocks_even_while_terminating_or_not_ready(self) -> None:
        for phase in ("Running", "Pending", "Unknown"):
            with self.subTest(phase=phase):
                pod = self.pod("controlplane:old", phase)
                pod["metadata"]["deletionTimestamp"] = "2026-01-01T00:00:00Z"
                self.assertIsNotNone(gate.wait_reason(self.deployment, self.replica_sets, [pod], "controlplane:new"))

    def test_new_api_waiting_in_migration_init_does_not_block_cmd(self) -> None:
        pod = self.pod("controlplane:new", "Pending")
        self.assertIsNone(gate.wait_reason(self.deployment, self.replica_sets, [pod], "controlplane:new"))

    def test_terminal_old_pods_have_no_processes_to_drain(self) -> None:
        for phase in ("Succeeded", "Failed"):
            with self.subTest(phase=phase):
                self.assertIsNone(
                    gate.wait_reason(
                        self.deployment, self.replica_sets, [self.pod("controlplane:old", phase)], "controlplane:new"
                    )
                )

    def test_scaled_to_zero_requires_every_api_pod_to_exit(self) -> None:
        self.deployment["spec"]["replicas"] = 0
        self.deployment["status"]["updatedReplicas"] = 0
        self.assertIsNotNone(gate.wait_reason(self.deployment, self.replica_sets, [], "controlplane:new"))
        self.replica_sets[0]["spec"]["replicas"] = 0
        self.assertIsNotNone(
            gate.wait_reason(self.deployment, self.replica_sets, [self.pod("controlplane:new")], "controlplane:new")
        )
        self.assertIsNone(gate.wait_reason(self.deployment, self.replica_sets, [], "controlplane:new"))

    def test_fresh_install_waits_for_deployment_then_allows_unready_new_pods(self) -> None:
        missing = HTTPError("https://kubernetes.default.svc", 404, "Not Found", {}, None)
        with (
            patch.object(
                gate,
                "read_resource",
                side_effect=[
                    missing,
                    self.deployment,
                    {"items": self.replica_sets},
                    {"items": [self.pod("controlplane:new", "Pending")]},
                ],
            ) as read,
            patch.object(gate.time, "sleep") as sleep,
            patch.object(gate.time, "monotonic", return_value=0),
        ):
            gate.wait_for_api_rollout("tenant", "test-api", "controlplane:new")
        sleep.assert_called_once_with(2)
        self.assertEqual(read.call_args.args[0], "/api/v1/namespaces/tenant/pods?labelSelector=app%3Dtest-api")

    def test_kubernetes_outage_cannot_start_migrations_after_deadline(self) -> None:
        with (
            patch.object(gate, "read_resource", side_effect=URLError("unavailable")),
            patch.object(gate.time, "monotonic", side_effect=[0, 901]),
        ):
            with self.assertRaisesRegex(TimeoutError, "Timed out"):
                gate.wait_for_api_rollout("tenant", "test-api", "controlplane:new")

    def test_rbac_denial_fails_closed(self) -> None:
        denied = HTTPError("https://kubernetes.default.svc", 403, "Forbidden", {}, None)
        with patch.object(gate, "read_resource", side_effect=denied):
            with self.assertRaises(HTTPError):
                gate.wait_for_api_rollout("tenant", "test-api", "controlplane:new")


if __name__ == "__main__":
    unittest.main()
