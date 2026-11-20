#!/usr/bin/env python3


import json
import os
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse


def read_setting(name: str) -> str:

    config_dir = os.environ.get("CONFIG_DIR", "/etc/config")
    path = os.path.join(config_dir, name)
    try:
        with open(path, encoding="utf-8") as handle:
            value = handle.read().strip()
    except OSError:
        value = ""
    if value:
        return value
    return os.environ.get(name, "")


class Handler(BaseHTTPRequestHandler):
    server_version = "demo-service"

    def log_message(self, fmt: str, *args) -> None:
        # Keep container logs to a single line per request.
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None: 
        path = urlparse(self.path).path
        if path == "/healthz":
            self._send(200, b"ok\n", "text/plain; charset=utf-8")
            return
        if path == "/":
            payload = {
                "app": read_setting("APP_NAME"),
                "version": read_setting("VERSION"),
                "pod": socket.gethostname(),
            }
            body = json.dumps(payload).encode("utf-8")
            self._send(200, body, "application/json")
            return
        self._send(404, b"not found\n", "text/plain; charset=utf-8")


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"listening on 0.0.0.0:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
