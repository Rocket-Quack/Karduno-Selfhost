"""Check Karduno domain routing and HTTPS using only the API image's stdlib."""

import argparse
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import secrets
import socket
import ssl
import sys
import threading
import time


class CheckError(Exception):
    pass


def addresses(domain):
    try:
        result = sorted({entry[4][0] for entry in socket.getaddrinfo(domain, None, type=socket.SOCK_STREAM)})
    except OSError as error:
        raise CheckError(f"DNS lookup failed for {domain}: {error}") from error
    if not result:
        raise CheckError(f"No A/AAAA addresses found for {domain}.")
    return result


def request(domain, address, port, path, *, tls=False):
    connection = http.client.HTTPConnection(domain, port, timeout=5)
    try:
        connection.sock = socket.create_connection((address, port), timeout=5)
        if tls:
            connection.sock = ssl.create_default_context().wrap_socket(connection.sock, server_hostname=domain)
        connection.request("GET", path, headers={"Connection": "close"})
        response = connection.getresponse()
        return response.status, response.read(65536)
    except (OSError, http.client.HTTPException) as error:
        raise CheckError(f"{domain} ({address}), TCP {port}: {error}") from error
    finally:
        connection.close()


def challenge_handler(path, token):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != path:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(token)))
            self.end_headers()
            self.wfile.write(token)

        def log_message(self, *_args):
            pass

    return Handler


def preflight(domains):
    token = secrets.token_urlsafe(32).encode()
    path = "/.well-known/karduno-setup/" + secrets.token_hex(16)
    servers = []
    try:
        for port in (8080, 8443):
            server = ThreadingHTTPServer(("0.0.0.0", port), challenge_handler(path, token))
            server.daemon_threads = True
            servers.append(server)
            threading.Thread(target=server.serve_forever, daemon=True).start()
        for domain in domains:
            for address in addresses(domain):
                for port in (80, 443):
                    status, body = request(domain, address, port, path)
                    if status != 200 or body != token:
                        raise CheckError(f"{domain} ({address}), TCP {port}: the setup probe did not answer. Check DNS, port forwarding, and other web servers.")
                    print(f"Routing OK: {domain} ({address}), TCP {port}", flush=True)
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()


def verify_once(domains):
    for domain in domains:
        for address in addresses(domain):
            status, body = request(domain, address, 443, "/api/health", tls=True)
            try:
                health = json.loads(body)
            except (ValueError, UnicodeError) as error:
                raise CheckError(f"{domain}: the API health response is not JSON.") from error
            if status != 200 or not isinstance(health, dict) or any(health.get(key) != "ok" for key in ("status", "db", "redis")):
                raise CheckError(f"{domain}: API, database, or Redis is not healthy.")
            status, _body = request(domain, address, 443, "/login", tls=True)
            if not 200 <= status < 400:
                raise CheckError(f"{domain}: the frontend returned HTTP {status}.")
            status, _body = request(domain, address, 80, "/")
            if status not in (301, 302, 307, 308):
                raise CheckError(f"{domain}: HTTP does not redirect to HTTPS (HTTP {status}).")


def verify(domains, timeout):
    deadline = time.monotonic() + timeout
    while True:
        try:
            verify_once(domains)
            for domain in domains:
                print(f"HTTPS, frontend, HTTP redirect, and API health OK: {domain}", flush=True)
            return
        except CheckError as error:
            if time.monotonic() >= deadline:
                raise
            print(f"Waiting for HTTPS readiness: {error}", flush=True)
            time.sleep(min(3, max(0, deadline - time.monotonic())))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("preflight", "verify"))
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    domains = [os.environ.get("PORTAL_DOMAIN", ""), os.environ.get("ADMIN_DOMAIN", "")]
    if not all(domains):
        raise CheckError("PORTAL_DOMAIN and ADMIN_DOMAIN are required.")
    if args.mode == "preflight":
        preflight(domains)
    else:
        verify(domains, max(0, args.timeout))


if __name__ == "__main__":
    try:
        main()
    except (CheckError, OSError) as error:
        print(f"Deployment check failed: {error}\nCheck A/AAAA records, TCP ports 80/443, firewall/security groups, and NAT or CDN settings.", file=sys.stderr)
        sys.exit(1)
