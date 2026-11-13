"""Check routing identity, TLS failures, and application readiness decisions."""

import importlib.util
from pathlib import Path
import socket
import ssl
import unittest
from unittest.mock import Mock, patch


SPEC = importlib.util.spec_from_file_location("deployment_check", Path(__file__).resolve().parents[1] / "scripts/check-deployment.py")
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)


class DeploymentCheckTest(unittest.TestCase):
    def test_dns_error_has_domain_context(self):
        with patch.object(check.socket, "getaddrinfo", side_effect=socket.gaierror("not found")):
            with self.assertRaisesRegex(check.CheckError, "DNS lookup failed for points.test"):
                check.addresses("points.test")

    def test_dns_keeps_ipv4_and_ipv6_without_duplicates(self):
        ipv4 = (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("192.0.2.1", 0))
        ipv6 = (socket.AF_INET6, socket.SOCK_STREAM, 6, "", ("2001:db8::1", 0, 0, 0))
        with patch.object(check.socket, "getaddrinfo", return_value=[ipv4, ipv6, ipv4]):
            self.assertEqual(check.addresses("points.test"), ["192.0.2.1", "2001:db8::1"])

    def test_preflight_checks_both_ports_for_every_address(self):
        with (
            patch.object(check, "ThreadingHTTPServer") as server,
            patch.object(check.threading, "Thread"),
            patch.object(check.secrets, "token_urlsafe", return_value="test-probe-token"),
            patch.object(check, "addresses", return_value=["192.0.2.1", "2001:db8::1"]),
            patch.object(check, "request", return_value=(200, b"test-probe-token")) as request,
        ):
            check.preflight(["points.test", "admin.test"])
            self.assertEqual(request.call_count, 8)
            self.assertEqual({call.args[2] for call in request.call_args_list}, {80, 443})
            self.assertEqual(server.return_value.shutdown.call_count, 2)
            self.assertEqual(server.return_value.server_close.call_count, 2)

    def test_wrong_server_is_rejected_even_with_http_200(self):
        with (
            patch.object(check, "ThreadingHTTPServer") as server,
            patch.object(check.threading, "Thread"),
            patch.object(check, "addresses", return_value=["192.0.2.1"]),
            patch.object(check, "request", return_value=(200, b"another server")),
        ):
            with self.assertRaisesRegex(check.CheckError, "probe did not answer"):
                check.preflight(["points.test"])
            self.assertEqual(server.return_value.server_close.call_count, 2)

    def test_port_bind_error_closes_already_started_listener(self):
        first_server = Mock()
        with (
            patch.object(check, "ThreadingHTTPServer", side_effect=[first_server, OSError("port in use")]),
            patch.object(check.threading, "Thread"),
        ):
            with self.assertRaisesRegex(OSError, "port in use"):
                check.preflight(["points.test"])
            first_server.shutdown.assert_called_once()
            first_server.server_close.assert_called_once()

    def test_tls_verification_error_is_not_ignored(self):
        with (
            patch.object(check.socket, "create_connection"),
            patch.object(check.ssl, "create_default_context") as context,
        ):
            context.return_value.wrap_socket.side_effect = ssl.SSLCertVerificationError("invalid certificate")
            with self.assertRaisesRegex(check.CheckError, "invalid certificate"):
                check.request("points.test", "192.0.2.1", 443, "/api/health", tls=True)
            self.assertEqual(context.return_value.wrap_socket.call_args.kwargs["server_hostname"], "points.test")

    def test_http_200_with_degraded_health_fails(self):
        with (
            patch.object(check, "addresses", return_value=["192.0.2.1"]),
            patch.object(check, "request", return_value=(200, b'{"status":"degraded","db":"ok","redis":"error"}')),
        ):
            with self.assertRaisesRegex(check.CheckError, "not healthy"):
                check.verify_once(["points.test"], frontend_domains=("points.test",))

    def test_missing_frontend_fails_even_with_healthy_api(self):
        with (
            patch.object(check, "addresses", return_value=["192.0.2.1"]),
            patch.object(check, "request", side_effect=[(200, b'{"status":"ok","db":"ok","redis":"ok"}'), (502, b"bad gateway")]),
        ):
            with self.assertRaisesRegex(check.CheckError, "frontend returned HTTP 502"):
                check.verify_once(["points.test"], frontend_domains=("points.test",))

    def test_https_readiness_includes_http_redirect(self):
        with (
            patch.object(check, "addresses", return_value=["192.0.2.1"]),
            patch.object(check, "request", side_effect=[(200, b'{"status":"ok","db":"ok","redis":"ok"}'), (200, b"login"), (200, b"wrong redirect")]),
        ):
            with self.assertRaisesRegex(check.CheckError, "does not redirect"):
                check.verify_once(["points.test"], frontend_domains=("points.test",))

    def test_api_only_domain_skips_frontend_probe(self):
        with (
            patch.object(check, "addresses", return_value=["192.0.2.1"]),
            patch.object(
                check,
                "request",
                side_effect=[(200, b'{"status":"ok","db":"ok","redis":"ok"}'), (301, b"")],
            ) as request,
        ):
            check.verify_once(["api.test"], frontend_domains=())
            self.assertEqual(request.call_count, 2)
            self.assertEqual([call.args[3] for call in request.call_args_list], ["/api/health", "/"])

    def test_main_existing_verifies_all_three_domains(self):
        env = {"PORTAL_DOMAIN": "p.test", "ADMIN_DOMAIN": "a.test", "API_DOMAIN": "api.test"}
        with (
            patch.object(check.sys, "argv", ["check-deployment.py", "verify", "--existing"]),
            patch.object(check.os, "environ", env),
            patch.object(check, "verify") as verify,
        ):
            check.main()
            verify.assert_called_once_with(("p.test", "a.test", "api.test"), 180, frontend_domains=("p.test", "a.test"))

    def test_main_fresh_install_skips_api_domain(self):
        env = {"PORTAL_DOMAIN": "p.test", "ADMIN_DOMAIN": "a.test", "API_DOMAIN": "api.test"}
        with (
            patch.object(check.sys, "argv", ["check-deployment.py", "preflight"]),
            patch.object(check.os, "environ", env),
            patch.object(check, "preflight") as preflight,
        ):
            check.main()
            preflight.assert_called_once_with(("p.test", "a.test"))

    def test_main_requires_api_domain(self):
        env = {"PORTAL_DOMAIN": "p.test", "ADMIN_DOMAIN": "a.test"}
        with (
            patch.object(check.sys, "argv", ["check-deployment.py", "verify"]),
            patch.object(check.os, "environ", env),
        ):
            with self.assertRaisesRegex(check.CheckError, "API_DOMAIN are required"):
                check.main()

    def test_readiness_retries_transient_certificate_failure(self):
        with (
            patch.object(check, "verify_once", side_effect=[check.CheckError("certificate pending"), None]) as verify,
            patch.object(check.time, "sleep"),
        ):
            check.verify(["points.test"], 10)
            self.assertEqual(verify.call_count, 2)

    def test_zero_timeout_returns_failure_without_sleep(self):
        with (
            patch.object(check, "verify_once", side_effect=check.CheckError("unreachable")),
            patch.object(check.time, "sleep") as sleep,
        ):
            with self.assertRaisesRegex(check.CheckError, "unreachable"):
                check.verify(["points.test"], 0)
            sleep.assert_not_called()


if __name__ == "__main__":
    unittest.main()
