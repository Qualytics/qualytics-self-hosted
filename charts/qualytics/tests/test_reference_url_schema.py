"""Exercise gateway URL validation with and without the chart's JSON schema."""
import subprocess
import unittest
from pathlib import Path

CHART = Path(__file__).resolve().parents[1]


class ReferenceGatewayPortTests(unittest.TestCase):
    def test_ports_in_schema_and_template_validation(self):
        for skip_schema in (False, True):
            for port, valid in (("443", True), ("65535", True), ("000443", True), ("0", False), ("65536", False), ("99999", False)):
                with self.subTest(skip_schema=skip_schema, port=port):
                    command = ["helm", "template", "reference-ports", str(CHART), "-f", str(CHART / "tests/values/deployment-identifier.yaml"),
                               "--set", "controlplane.referenceData.enabled=true", "--set-string",
                               f"controlplane.referenceData.gatewayUrl=https://reference.example.com:{port}"]
                    if skip_schema:
                        command.append("--skip-schema-validation")
                    result = subprocess.run(command, capture_output=True, text=True, check=False)
                    self.assertEqual(result.returncode == 0, valid, result.stderr)
                    if not valid:
                        self.assertIn("gatewayUrl", result.stderr)
