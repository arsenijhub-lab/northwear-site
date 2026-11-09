from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import socket
import webbrowser


SITE_DIRECTORY = Path(__file__).resolve().parent
PORT = 8000
handler = partial(SimpleHTTPRequestHandler, directory=str(SITE_DIRECTORY))

try:
    server = ThreadingHTTPServer(("0.0.0.0", PORT), handler)
except OSError:
    server = ThreadingHTTPServer(("127.0.0.1", PORT), handler)

hostname = socket.gethostname()
try:
    local_ip = socket.gethostbyname(hostname)
except Exception:
    local_ip = "127.0.0.1"

print(f"NORTH WEAR is running:")
print(f"  - On PC:    http://127.0.0.1:{PORT}/")
if local_ip != "127.0.0.1":
    print(f"  - On phone: http://{local_ip}:{PORT}/ (same Wi-Fi)")
print("Press Ctrl+C to stop.")

webbrowser.open(f"http://127.0.0.1:{PORT}/")

try:
    server.serve_forever()
except KeyboardInterrupt:
    print("\nStopping NORTH WEAR local server.")
finally:
    server.server_close()
