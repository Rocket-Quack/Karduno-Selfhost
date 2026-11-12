"""Exercise installer safety with real Compose parsing and a fake Docker daemon."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = (
    str(Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe")
    if os.name == "nt"
    else shutil.which("bash")
)
DOCKER = shutil.which("docker")


@unittest.skipUnless(BASH and Path(BASH).exists() and DOCKER, "Bash and Docker Compose required")
class EasyInstallTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="karduno-installer-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in ("easy-install.sh", "easy-install.ps1", ".env.example", "docker-compose.yml", "Caddyfile"):
            shutil.copyfile(ROOT / name, self.root / name)
        shutil.copytree(ROOT / "scripts", self.root / "scripts")
        binary_dir = self.root / "bin"
        binary_dir.mkdir()
        mock = binary_dir / "docker"
        mock.write_text(
            '#!/usr/bin/env bash\nset -eu\n'
            'case "$*" in\n'
            '  info) exit "${MOCK_INFO_STATUS:-0}" ;;\n'
            '  "volume ls "*) printf "%s" "${MOCK_DATABASE:-}"; exit 0 ;;\n'
            '  "compose ps --status running --services") printf "%s" "${MOCK_RUNNING_SERVICES:-}"; exit 0 ;;\n'
            '  "compose pull"*) echo pull >> "$MOCK_LOG"; exit "${MOCK_PULL_STATUS:-0}" ;;\n'
            '  "compose up "*) echo up >> "$MOCK_LOG"; exit "${MOCK_UP_STATUS:-0}" ;;\n'
            '  "compose stop worker") echo stop-worker >> "$MOCK_LOG"; exit 0 ;;\n'
            '  "compose run "*)\n'
            '    if [[ " $* " == *" --service-ports "* ]]; then\n'
            '      echo preflight >> "$MOCK_LOG"; exit "${MOCK_PREFLIGHT_STATUS:-0}"\n'
            '    else echo verify >> "$MOCK_LOG"; exit "${MOCK_VERIFY_STATUS:-0}"; fi ;;\n'
            'esac\nexec "$REAL_DOCKER" "$@"\n',
            encoding="utf-8",
            newline="\n",
        )
        mock.chmod(0o755)
        self.env = os.environ.copy()
        # The tests must not inherit deployment settings from the caller.
        for key in list(self.env):
            if key.startswith(("COMPOSE_", "POSTGRES_", "JWT_", "INITIAL_ADMIN_")):
                self.env.pop(key)
        for key in ("PORTAL_DOMAIN", "ADMIN_DOMAIN", "ACME_EMAIL", "IMAGE_VERSION"):
            self.env.pop(key, None)
        self.env.update(
            PATH=str(binary_dir) + os.pathsep + self.env["PATH"],
            REAL_DOCKER=Path(DOCKER).as_posix(),
            MOCK_LOG=(self.root / "docker-calls").as_posix(),
        )
        self.write_config()

    def write_config(self, extra=""):
        (self.root / ".env").write_text(
            "PORTAL_DOMAIN=points.karduno.test\n"
            "ADMIN_DOMAIN=admin.karduno.test\n"
            "ACME_EMAIL=admin@karduno.test\n"
            "INITIAL_ADMIN_EMAIL=admin@karduno.test\n"
            "INITIAL_ADMIN_PASSWORD='Installer-Test-Only-2026!'\n"
            + extra,
            encoding="utf-8",
        )

    def run_installer(self, *args, success=True, full=False):
        options = [] if full else ["--prepare-only"]
        result = subprocess.run(
            [BASH, (self.root / "easy-install.sh").as_posix(), "--non-interactive", *options, *args],
            env=self.env,
            text=True,
            capture_output=True,
            timeout=60,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / ".easy-install.lock").exists())
        return result

    def secret_values(self):
        return {p.name: p.read_bytes() for p in (self.root / "secrets").iterdir()}

    def test_generates_and_preserves_secrets(self):
        original_env = (self.root / ".env").read_bytes()
        first = self.run_installer("--prepare-only")
        secrets = self.secret_values()
        self.assertEqual(set(secrets), {"postgres_password", "jwt_secret"})
        for value in secrets.values():
            self.assertRegex(value.decode(), r"^[0-9a-f]{64}$")
            self.assertNotIn(value.decode(), first.stdout + first.stderr)
        self.assertNotEqual(secrets["postgres_password"], secrets["jwt_secret"])
        self.run_installer("--prepare-only")
        self.assertEqual(self.secret_values(), secrets)
        self.assertEqual((self.root / ".env").read_bytes(), original_env)
        self.assertFalse((self.root / "docker-calls").exists())

    def test_compose_grants_only_required_secrets(self):
        self.run_installer("--prepare-only")
        result = subprocess.run(
            [DOCKER, "compose", "config", "--format", "json"], cwd=self.root,
            env=self.env, text=True, capture_output=True, check=True,
        )
        services = json.loads(result.stdout)["services"]
        for name in ("api", "worker"):
            self.assertNotIn("JWT_SECRET", services[name]["environment"])
            self.assertNotIn("DATABASE_URL", services[name]["environment"])
            self.assertEqual(len(services[name]["secrets"]), 2)
        self.assertEqual(len(services["postgres"]["secrets"]), 1)
        self.assertNotIn("POSTGRES_PASSWORD", services["postgres"]["environment"])
        for name in ("admin", "portal", "redis", "caddy"):
            self.assertNotIn("secrets", services[name])

    def test_application_images_always_use_latest(self):
        self.write_config('IMAGE_VERSION=v-old-setting\n')
        result = subprocess.run(
            [DOCKER, "compose", "--profile", "setup", "config", "--format", "json"], cwd=self.root,
            env=self.env, text=True, capture_output=True, check=True,
        )
        services = json.loads(result.stdout)["services"]
        for name in ("api", "worker", "admin", "portal", "setup-check"):
            self.assertTrue(services[name]["image"].endswith(":latest"))

    def test_existing_database_without_secrets_is_not_rekeyed(self):
        self.env["MOCK_DATABASE"] = "karduno-self-hosted_postgres_data"
        result = self.run_installer("--prepare-only", success=False)
        self.assertIn("Restore the original values", result.stderr)
        self.assertFalse((self.root / "secrets").exists())

    def test_missing_secret_on_existing_database_is_not_replaced(self):
        self.run_installer("--prepare-only")
        original = (self.root / "secrets/postgres_password").read_bytes()
        (self.root / "secrets/jwt_secret").unlink()
        self.env["MOCK_DATABASE"] = "karduno-self-hosted_postgres_data"
        self.run_installer("--prepare-only", success=False)
        self.assertEqual((self.root / "secrets/postgres_password").read_bytes(), original)
        self.assertFalse((self.root / "secrets/jwt_secret").exists())

    def test_legacy_env_requires_deliberate_migration(self):
        self.write_config("POSTGRES_PASSWORD=old-value\nJWT_SECRET=old-key\n")
        result = self.run_installer("--prepare-only", success=False)
        self.assertIn("Legacy secrets", result.stderr)
        self.assertFalse((self.root / "secrets").exists())

    def test_same_domains_are_rejected(self):
        self.write_config("ADMIN_DOMAIN=points.karduno.test\n")
        result = self.run_installer("--prepare-only", success=False)
        self.assertIn("different domains", result.stderr)

    def test_noninteractive_requires_configuration(self):
        (self.root / ".env").unlink()
        result = self.run_installer("--prepare-only", success=False)
        self.assertIn("No .env found", result.stderr)

    def test_bash_wizard_saves_admin_credentials(self):
        (self.root / ".env").unlink()
        installer = self.root / "easy-install.sh"
        # Feed the wizard through a pipe, replacing only its terminal check.
        installer.write_text(
            installer.read_text().replace("&& -t 0", "&& -p /dev/stdin"),
            encoding="utf-8", newline="\n",
        )
        password = 'Test-Only-$dollar-\\path-"quoted"-\'single'
        answers = [
            "points.karduno.test", "admin.karduno.test", "admin@karduno.test",
            password, password, "",
        ]
        output = subprocess.run(
            [BASH, installer.as_posix(), "--prepare-only"],
            input=("\n".join(answers) + "\n").encode("utf-8"), env=self.env,
            capture_output=True, timeout=60,
        )
        output.stdout = output.stdout.decode("utf-8")
        output.stderr = output.stderr.decode("utf-8")
        self.assertEqual(output.returncode, 0, output.stdout + output.stderr)
        resolved = subprocess.run(
            [DOCKER, "compose", "config", "--environment"], cwd=self.root,
            env=self.env, text=True, capture_output=True, check=True,
        )
        values = dict(line.split("=", 1) for line in resolved.stdout.splitlines() if "=" in line)
        self.assertEqual(values["INITIAL_ADMIN_EMAIL"], "admin@karduno.test")
        self.assertEqual(values["INITIAL_ADMIN_PASSWORD"], password)
        self.assertNotIn(password, output.stdout + output.stderr)
        self.assertFalse((self.root / ".easy-install.lock").exists())

    def test_prepare_only_does_not_start(self):
        self.run_installer()
        values = self.secret_values()
        self.run_installer()
        self.assertEqual(self.secret_values(), values)
        self.assertFalse((self.root / "docker-calls").exists())

    def test_offline_existing_configuration_does_not_generate_secrets(self):
        self.env["MOCK_INFO_STATUS"] = "1"
        result = self.run_installer(success=False)
        self.assertIn("existing .env has missing secrets", result.stderr)
        self.assertFalse((self.root / "secrets").exists())

    def test_offline_existing_secrets_are_kept(self):
        self.run_installer()
        values = self.secret_values()
        self.env["MOCK_INFO_STATUS"] = "1"
        self.run_installer()
        self.assertEqual(self.secret_values(), values)

    def test_dotenv_is_not_executed_as_shell_code(self):
        self.write_config("INITIAL_ADMIN_PASSWORD='$(touch SHOULD_NOT_EXIST) $dollar # literal'\n")
        self.run_installer("--prepare-only")
        self.assertFalse((self.root / "SHOULD_NOT_EXIST").exists())

    def calls(self):
        return (self.root / "docker-calls").read_text().splitlines()

    def test_full_setup_checks_routing_before_start_and_https_after_start(self):
        self.run_installer(full=True)
        self.assertEqual(self.calls(), ["preflight", "pull", "up", "verify"])

    def test_pull_failure_does_not_probe_or_start(self):
        self.env["MOCK_PULL_STATUS"] = "1"
        self.run_installer(full=True, success=False)
        self.assertEqual(self.calls(), ["preflight", "pull"])

    def test_failed_domain_probe_does_not_start_stack(self):
        self.env["MOCK_PREFLIGHT_STATUS"] = "1"
        result = self.run_installer(full=True, success=False)
        self.assertIn("Domain/port checks failed", result.stderr)
        self.assertEqual(self.calls(), ["preflight"])

    def test_failed_start_does_not_claim_success(self):
        self.env["MOCK_UP_STATUS"] = "1"
        result = self.run_installer(full=True, success=False)
        self.assertIn("Startup failed", result.stderr)
        self.assertEqual(self.calls(), ["preflight", "pull", "up"])

    def test_failed_https_check_leaves_stack_for_diagnosis(self):
        self.env["MOCK_VERIFY_STATUS"] = "1"
        result = self.run_installer(full=True, success=False)
        self.assertIn("left running for diagnosis", result.stderr)
        self.assertEqual(self.calls(), ["preflight", "pull", "up", "verify"])

    def test_rerun_preserves_caddy_and_pauses_worker_for_migrations(self):
        self.env["MOCK_RUNNING_SERVICES"] = "api\ncaddy\nworker"
        self.run_installer(full=True)
        self.assertEqual(self.calls(), ["verify", "pull", "stop-worker", "up", "verify"])

    def test_failed_existing_route_check_preserves_running_services(self):
        self.env["MOCK_RUNNING_SERVICES"] = "caddy\nworker"
        self.env["MOCK_VERIFY_STATUS"] = "1"
        self.run_installer(full=True, success=False)
        self.assertEqual(self.calls(), ["verify"])


@unittest.skipUnless(os.name == "nt", "Native Windows PowerShell test")
class WindowsEasyInstallTest(EasyInstallTest):
    def setUp(self):
        super().setUp()
        self.interactive = False
        self.runner = self.root / "invoke.ps1"
        self.runner.write_text(
            """$ErrorActionPreference = 'Stop'
function global:docker {
    if ($args[0] -eq 'info') {
        $global:LASTEXITCODE = if ($env:MOCK_INFO_STATUS) { [int]$env:MOCK_INFO_STATUS } else { 0 }
        return
    }
    if ($args[0] -eq 'volume' -and $args[1] -eq 'ls') {
        $global:LASTEXITCODE = 0
        if ($env:MOCK_DATABASE) { Write-Output $env:MOCK_DATABASE }
        return
    }
    if ($args[0] -eq 'compose' -and $args[1] -eq 'ps') {
        $global:LASTEXITCODE = 0
        if ($env:MOCK_RUNNING_SERVICES) { $env:MOCK_RUNNING_SERVICES -split "`n" }
        return
    }
    if ($args[0] -eq 'compose' -and $args[1] -in @('pull', 'up', 'run', 'stop')) {
        $label = $args[1]
        $statusName = 'MOCK_' + $label.ToUpper() + '_STATUS'
        if ($label -eq 'run') {
            $label = if ($args -contains '--service-ports') { 'preflight' } else { 'verify' }
            $statusName = 'MOCK_' + $label.ToUpper() + '_STATUS'
        }
        if ($label -eq 'stop') { $label = 'stop-worker' }
        Add-Content -LiteralPath $env:MOCK_LOG -Value $label
        $status = [Environment]::GetEnvironmentVariable($statusName)
        $global:LASTEXITCODE = if ($status) { [int]$status } else { 0 }
        return
    }
    & $env:REAL_DOCKER @args
    $global:LASTEXITCODE = $LASTEXITCODE
}
if ($env:MOCK_ANSWERS_FILE) {
    $global:answers = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($answer in (Get-Content -LiteralPath $env:MOCK_ANSWERS_FILE -Raw | ConvertFrom-Json)) {
        $global:answers.Enqueue($answer)
    }
    function global:Read-Host {
        param([string]$Prompt, [switch]$AsSecureString)
        if ($global:answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }
        $answer = $global:answers.Dequeue()
        if ($AsSecureString) { return ConvertTo-SecureString -String $answer -AsPlainText -Force }
        return $answer
    }
}
try {
    $options = @{ SkipDependencies = $true }
    if (-not $env:MOCK_FULL_INSTALL) { $options.PrepareOnly = $true }
    if (-not $env:MOCK_ANSWERS_FILE) { $options.NonInteractive = $true }
    & (Join-Path $PSScriptRoot 'easy-install.ps1') @options
    exit 0
} catch {
    [Console]::Error.WriteLine($_.ToString())
    [Console]::Error.WriteLine($_.ScriptStackTrace)
    exit 1
}
""",
            encoding="utf-8",
        )

    def run_installer(self, *args, success=True, full=False):
        self.env["MOCK_FULL_INSTALL"] = "1" if full else ""
        result = subprocess.run(
            [shutil.which("powershell"), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(self.runner)],
            env=self.env, text=True, capture_output=True, timeout=60,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / ".easy-install.lock").exists())
        return result

    def prepare_wizard(self):
        (self.root / ".env").unlink()
        self.admin_password = 'Test-Only-$dollar-\\path-\"quoted\"-\'single'
        answers = [
            "points.karduno.test", "admin.karduno.test", "admin@karduno.test",
            self.admin_password, self.admin_password, "",
        ]
        answer_path = self.root / "answers.json"
        answer_path.write_text(json.dumps(answers), encoding="utf-8")
        self.env["MOCK_ANSWERS_FILE"] = str(answer_path)

    def test_wizard_preserves_special_characters_and_template_settings(self):
        self.prepare_wizard()
        with (self.root / ".env.example").open("a", encoding="utf-8") as template:
            template.write("\nINSTANCE_NAME='Custom test instance'\n")
        output = self.run_installer()
        result = subprocess.run(
            [DOCKER, "compose", "config", "--format", "json"], cwd=self.root,
            env=self.env, text=True, capture_output=True, check=True,
        )
        app = json.loads(result.stdout)["services"]["api"]["environment"]
        # Serialized Compose config escapes dollars; inspect resolved dotenv values.
        resolved = subprocess.run(
            [DOCKER, "compose", "config", "--environment"], cwd=self.root,
            env=self.env, text=True, capture_output=True, check=True,
        )
        values = dict(line.split("=", 1) for line in resolved.stdout.splitlines() if "=" in line)
        self.assertEqual(values["INITIAL_ADMIN_PASSWORD"], self.admin_password)
        self.assertEqual(app["INSTANCE_NAME"], "Custom test instance")
        self.assertNotIn(self.admin_password, output.stdout + output.stderr)

    def test_new_wizard_can_prepare_without_running_docker_daemon(self):
        self.prepare_wizard()
        self.env["MOCK_INFO_STATUS"] = "1"
        self.run_installer()
        self.assertEqual(set(self.secret_values()), {"postgres_password", "jwt_secret"})
        self.assertFalse((self.root / "docker-calls").exists())


if __name__ == "__main__":
    unittest.main()
