#!/usr/bin/env python3
"""HTTPS fixture server for zick black-box tests.

Ports zic's lighttpd-environment fixture: serves the fixture wwwroot
over TLS with a self-signed certificate and (optionally) HTTP basic
auth for user ``mode`` password ``code``.

The zick CLI does not yet expose download authorizations (bead
zick-a05), so the black-box scripts run with ``--no-auth``; pass
``--require-auth`` once that lands.

Usage:
    fixture-server.py --wwwroot DIR --cert server.pem [--port N]
                      [--require-auth | --no-auth]
"""

import argparse
import base64
import functools
import http.server
import os
import ssl
import sys

AUTH_USER = "mode"
AUTH_PASS = "code"


class FixtureHandler(http.server.SimpleHTTPRequestHandler):
    """Serve the wwwroot directory, optionally demanding basic auth."""

    def __init__(self, *args, require_auth=False, **kwargs):
        self.require_auth = require_auth
        super().__init__(*args, **kwargs)

    def _authorized(self):
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        try:
            decoded = base64.b64decode(header[len("Basic "):]).decode("utf-8")
        except Exception:
            return False
        return decoded == "{}:{}".format(AUTH_USER, AUTH_PASS)

    def do_GET(self):
        if self.require_auth and not self._authorized():
            self.send_response(401)
            self.send_header("Content-Length", "0")
            self.send_header("WWW-Authenticate",
                             'Basic realm="zick fixture"')
            self.end_headers()
            self.close_connection = True
            return
        super().do_GET()

    def log_message(self, fmt, *args):
        # Keep the server quiet; the black-box scripts assert on the
        # client side, not on server logs.
        pass


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=8443)
    ap.add_argument("--wwwroot", required=True,
                    help="directory to serve (the fixture wwwroot)")
    ap.add_argument("--cert", required=True,
                    help="self-signed certificate file (server.pem)")
    ap.add_argument("--require-auth", action="store_true",
                    help="demand basic auth user %s password %s"
                         % (AUTH_USER, AUTH_PASS))
    args = ap.parse_args()

    handler = functools.partial(FixtureHandler,
                                directory=args.wwwroot,
                                require_auth=args.require_auth)
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", args.port),
                                            handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(args.cert)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)

    print("zick fixture server: https://127.0.0.1:{} (auth={})"
          .format(args.port,
                  "on" if args.require_auth else "off"),
          flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
