"""A stand-in for HAProxy, so the rest of Scripts/proxy-protocol-check.sh can be exercised where HAProxy is absent.

It listens where haproxy.cfg's frontends do (18081: PROXY v2, 18082: PROXY v1), reads one HTTP request head, takes the
address named in X-Test-Src, connects to the kit's server on 18080, sends a PROXY header claiming that address, forwards
the request, and relays the answer. The PROXY headers are built from the HAProxy PROXY protocol specification (version 1
text line; version 2 binary: signature, 0x21, family/protocol, length, addresses, ports).

It is not evidence about HAProxy: only about the kit's half. Run with: python3 -I emulated_balancer.py
"""
import socket
import struct
import threading

BACKEND = ("127.0.0.1", 18080)
SIGNATURE = b"\r\n\r\n\x00\r\nQUIT\n"


def proxy_header(version, source):
    family = socket.AF_INET6 if ":" in source else socket.AF_INET
    packed = socket.inet_pton(family, source)
    destination_text = "::1" if family == socket.AF_INET6 else "127.0.0.1"
    destination = socket.inet_pton(family, destination_text)
    if version == 1:
        name = "TCP6" if family == socket.AF_INET6 else "TCP4"
        return "PROXY {} {} {} 40000 18081\r\n".format(name, source, destination_text).encode()
    code = 0x21 if family == socket.AF_INET6 else 0x11
    body = packed + destination + struct.pack("!HH", 40000, 18081)
    return SIGNATURE + bytes([0x21, code]) + struct.pack("!H", len(body)) + body


def serve(client, version):
    with client:
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = client.recv(4096)
            if not chunk:
                return
            head += chunk
        source = "127.0.0.1"
        for line in head.split(b"\r\n"):
            if line.lower().startswith(b"x-test-src:"):
                source = line.split(b":", 1)[1].strip().decode()
        with socket.create_connection(BACKEND, timeout=5) as backend:
            backend.sendall(proxy_header(version, source) + head)
            while True:
                data = backend.recv(4096)
                if not data:
                    break
                client.sendall(data)


def listen(port, version):
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", port))
    server.listen(16)
    while True:
        client, _ = server.accept()
        threading.Thread(target=serve, args=(client, version), daemon=True).start()


if __name__ == "__main__":
    threading.Thread(target=listen, args=(18082, 1), daemon=True).start()
    listen(18081, 2)
