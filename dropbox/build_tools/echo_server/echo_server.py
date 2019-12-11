from __future__ import annotations

import argparse
import socketserver
import sys


class EchoHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        ip, port = self.client_address
        data = self.request.makefile().read()
        print("Client {}:{} sent: {!r}".format(ip, port, data))
        sys.stdout.flush()
        response = "You sent this from {}:{} - {!r}\n".format(ip, port, data)
        self.request.sendall(response)


def main() -> None:
    ap = argparse.ArgumentParser("echo_server")
    ap.add_argument("--port", required=True, type=int, help="Port to listen on")
    args = ap.parse_args()

    server = socketserver.TCPServer(("0.0.0.0", args.port), EchoHandler, False)
    server.allow_reuse_address = True
    server.server_bind()
    server.server_activate()
    server.serve_forever()


if __name__ == "__main__":
    main()
