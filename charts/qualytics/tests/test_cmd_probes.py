"""Execute the CMD probe commands rendered by Helm, including image compatibility."""

import contextlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


class CmdProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        chart = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            (fixture / "templates").mkdir()
            (fixture / "Chart.yaml").write_text(
                "apiVersion: v2\nname: cmd-probe-contract\nversion: 0.0.0\n"
            )
            shutil.copyfile(chart / "values.yaml", fixture / "values.yaml")
            shutil.copyfile(chart / "templates/_helpers.tpl", fixture / "templates/_helpers.tpl")
            shutil.copyfile(chart / "templates/controlplane-cmd.yaml", fixture / "cmd.yaml")
            # Helm parses its own rendered YAML so this test needs no Python YAML dependency.
            (fixture / "templates/render.yaml").write_text(
                '{{ tpl (.Files.Get "cmd.yaml") . | fromYaml | toJson }}'
            )
            rendered = subprocess.run(
                ["helm", "template", "probe-test", str(fixture)],
                check=True, capture_output=True, text=True,
            ).stdout
        deployment = json.loads(next(line for line in rendered.splitlines() if line.startswith("{")))
        container = deployment["spec"]["template"]["spec"]["containers"][0]
        cls.commands = {
            name: container[f"{name}Probe"]["exec"]["command"]
            for name in ("startup", "readiness", "liveness")
        }

    def execute(self, probe: str) -> None:
        command = self.commands[probe]
        self.assertEqual(command[:2], ["python3", "-c"])
        with patch.object(sys, "argv", ["-c", *command[3:]]):
            exec(compile(command[2], "<rendered-cmd-probe>", "exec"), {})

    def test_checker_success_and_failure_propagate_for_every_probe(self) -> None:
        for probe, mode in (("startup", "startup"), ("readiness", "ready"), ("liveness", "live")):
            for exit_code in (0, 7):
                with self.subTest(probe=probe, exit_code=exit_code):
                    with (
                        patch("os.path.isfile", return_value=True) as isfile,
                        patch("os.execv", side_effect=SystemExit(exit_code)) as execv,
                        patch("socket.create_connection") as connect,
                    ):
                        with self.assertRaises(SystemExit) as result:
                            self.execute(probe)
                        self.assertEqual(result.exception.code, exit_code)
                        isfile.assert_called_once_with("/app/hub_cmd_health.py")
                        execv.assert_called_once_with(
                            sys.executable, [sys.executable, "/app/hub_cmd_health.py", mode]
                        )
                        connect.assert_not_called()

    def test_legacy_startup_and_liveness_succeed_without_dependencies(self) -> None:
        for probe in ("startup", "liveness"):
            with self.subTest(probe=probe):
                with (
                    patch("os.path.isfile", return_value=False),
                    patch("os.execv") as execv,
                    patch("socket.create_connection") as connect,
                ):
                    self.execute(probe)
                    execv.assert_not_called()
                    connect.assert_not_called()

    def test_legacy_readiness_checks_the_configured_broker(self) -> None:
        for port in (None, "5672"):
            with self.subTest(port=port):
                environment = {"RABBIT_MQ_HOST": "rabbit.example.test"}
                if port is not None:
                    environment["RABBIT_MQ_PORT"] = port
                with (
                    patch("os.path.isfile", return_value=False),
                    patch.dict(os.environ, environment, clear=True),
                    patch("socket.create_connection", return_value=contextlib.nullcontext()) as connect,
                ):
                    self.execute("readiness")
                    connect.assert_called_once_with(
                        ("rabbit.example.test", int(port or "5671")), timeout=5
                    )

    def test_legacy_readiness_does_not_hide_connection_failure(self) -> None:
        with (
            patch("os.path.isfile", return_value=False),
            patch.dict(os.environ, {"RABBIT_MQ_HOST": "rabbit.example.test"}, clear=True),
            patch("socket.create_connection", side_effect=OSError("broker unavailable")),
        ):
            with self.assertRaises(OSError):
                self.execute("readiness")


if __name__ == "__main__":
    unittest.main()
