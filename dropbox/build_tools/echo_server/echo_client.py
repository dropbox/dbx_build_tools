from __future__ import annotations

import argparse
import socket


def main() -> None:
    ap = argparse.ArgumentParser("echo_server")
    ap.add_argument("--port", required=True, type=int, help="Port to listen on")
    ap.add_argument("msg", help="Mesage to send to the echo server")
    args = ap.parse_args()

    s = socket.create_connection(("localhost", args.port))
    s.sendall(args.msg.encode("utf-8"))
    s.shutdown(socket.SHUT_WR)

    echo_msg = b""
    while True:
        buf = s.recv(1024)
        if not buf:
            break
        echo_msg += buf
    s.close()
    print(echo_msg.decode("utf-8"))


main()
