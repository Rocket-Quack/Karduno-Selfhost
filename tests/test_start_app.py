"""Check that unsafe migration URLs fail before starting the application."""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = str(Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe") if os.name == "nt" else shutil.which("bash")


@unittest.skipUnless(BASH and Path(BASH).exists(), "Bash required")
class StartAppTest(unittest.TestCase):
    def test_percent_encoded_database_url_is_rejected_without_exposing_it(self):
        # Use the actual API branch, after the independently tested secret loader.
        source = (ROOT / "scripts/start-app.sh").read_text(encoding="utf-8")
        branch = source[source.index('case "${1:-}" in'):]
        value = "postgresql+asyncpg://user:private%24password@postgres:5432/db"
        with tempfile.TemporaryDirectory(prefix="karduno-start-guard-") as directory:
            script = Path(directory) / "guard.sh"
            script.write_text("#!/bin/sh\nset -eu\n" + branch, encoding="utf-8", newline="\n")
            environment = dict(os.environ, DATABASE_URL=value)
            result = subprocess.run([BASH, script.as_posix(), "api"], env=environment, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("URL-unreserved database credentials", result.stderr)
            self.assertNotIn(value, result.stdout + result.stderr)
            self.assertNotIn("private%24password", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
