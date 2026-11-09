# Client websocket minimal pour les REPL de norns (matron :5555, sclang :5556).
# usage : python3 repl.py PORT "code" [secondes d'écoute]
import base64, os, socket, struct, sys, time

port, code = int(sys.argv[1]), sys.argv[2]
listen = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0

s = socket.create_connection(("127.0.0.1", port), timeout=5)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall((
    "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
    "Sec-WebSocket-Protocol: bus.sp.nanomsg.org\r\n\r\n").encode())
buf = b""
while b"\r\n\r\n" not in buf:
    buf += s.recv(4096)
buf = buf.split(b"\r\n\r\n", 1)[1]

# sclang exécute le code reçu à la réception de ESC (0x1b)
payload = (code + ("\x1b" if port == 5556 else "\n")).encode()
mask = os.urandom(4)
n = len(payload)
head = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n))
s.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

end = time.time() + listen
s.settimeout(0.2)
while time.time() < end:
    try:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    except socket.timeout:
        pass
    while len(buf) >= 2:
        ln, off = buf[1] & 0x7F, 2
        if ln == 126:
            if len(buf) < 4: break
            ln, off = struct.unpack(">H", buf[2:4])[0], 4
        elif ln == 127:
            if len(buf) < 10: break
            ln, off = struct.unpack(">Q", buf[2:10])[0], 10
        if len(buf) < off + ln:
            break
        sys.stdout.write(buf[off:off + ln].decode(errors="replace"))
        buf = buf[off + ln:]
