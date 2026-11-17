"""Exercise gateway URL validation with and without the chart's JSON schema."""
import shutil
import subprocess
import tempfile
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


    def test_reused_values_without_gateway_url(self):
        # Model the saved pre-feature defaults used by Helm --reuse-values: the
        # new enabled override exists, but no gateway URL is present at all.
        with tempfile.TemporaryDirectory() as directory:
            chart = Path(directory) / "qualytics"
            shutil.copytree(CHART, chart)
            values = chart / "values.yaml"
            lines = values.read_text().splitlines(keepends=True)
            values.write_text("".join(line for line in lines if not line.startswith("    gatewayUrl:")))
            for skip_schema in (False, True):
                for explicit_empty in (False, True):
                    with self.subTest(skip_schema=skip_schema, explicit_empty=explicit_empty):
                        command = ["helm", "template", "reference-reuse", str(chart), "-f",
                                   str(chart / "tests/values/deployment-identifier.yaml"),
                                   "--set", "controlplane.referenceData.enabled=true"]
                        if skip_schema:
                            command.append("--skip-schema-validation")
                        if explicit_empty:
                            command.extend(["--set-string", "controlplane.referenceData.gatewayUrl="])
                        result = subprocess.run(command, capture_output=True, text=True, check=False)
                        self.assertEqual(result.returncode == 0, not explicit_empty, result.stderr)
                        if explicit_empty:
                            self.assertIn("gatewayUrl", result.stderr)
                        else:
                            self.assertEqual(result.stdout.count('value: "https://reference-data.qualytics.io"'), 2)
