#!/usr/bin/env python3
"""A stand-in for `codex app-server`, for testing the tunnel to one on another machine.
It answers /readyz, accepts a WebSocket only with the token whose SHA-256 it was given, and
replies to JSON-RPC requests. No model, no conversations."""
import base64, hashlib, json, socket, struct, sys, threading

args = sys.argv[1:]
if not args or args[0] != "app-server":
    sys.exit(2)
listen = args[args.index("--listen") + 1]
digest = args[args.index("--ws-token-sha256") + 1]
port = int(listen.rsplit(":", 1)[1])

def recv_exact(conn, n):
    data = b""
    while len(data) < n:
        chunk = conn.recv(n - len(data))
        if not chunk:
            raise ConnectionError
        data += chunk
    return data

def send_text(conn, text):
    body = text.encode()
    head = bytes([0x81])
    if len(body) < 126:
        head += bytes([len(body)])
    else:
        head += bytes([126]) + struct.pack(">H", len(body))
    conn.sendall(head + body)

def serve(conn):
    try:
        request = b""
        while b"\r\n\r\n" not in request:
            request += conn.recv(4096)
        lines = request.decode(errors="replace").split("\r\n")
        headers = {k.lower(): v for k, v in (l.split(": ", 1) for l in lines[1:] if ": " in l)}
        if lines[0].startswith("GET /readyz"):
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
            return
        token = headers.get("authorization", "").removeprefix("Bearer ")
        if hashlib.sha256(token.encode()).hexdigest() != digest:
            conn.sendall(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        conn.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").encode())
        while True:
            first, second = recv_exact(conn, 2)
            length = second & 0x7F
            if length == 126:
                length = struct.unpack(">H", recv_exact(conn, 2))[0]
            elif length == 127:
                length = struct.unpack(">Q", recv_exact(conn, 8))[0]
            mask = recv_exact(conn, 4) if second & 0x80 else b"\0\0\0\0"
            body = bytes(b ^ mask[i % 4] for i, b in enumerate(recv_exact(conn, length)))
            if first & 0x0F == 8:
                return
            if first & 0x0F != 1:
                continue
            message = json.loads(body)
            if "id" not in message:
                continue
            method = message.get("method")
            result = {}
            if method == "thread/start":
                result = {"thread": {"id": "fake-thread-1", "cwd": message["params"].get("cwd")}}
            elif method == "initialize":
                result = {"userAgent": "fake-codex"}
            send_text(conn, json.dumps({"id": message["id"], "result": result}))
    except Exception:
        pass
    finally:
        conn.close()

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", port))
server.listen(8)
while True:
    conn, _ = server.accept()
    threading.Thread(target=serve, args=(conn,), daemon=True).start()
