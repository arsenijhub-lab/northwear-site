from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import webbrowser


SITE_DIRECTORY = Path(__file__).resolve().parent
SITE_URL = "http://127.0.0.1:8000/"
handler = partial(SimpleHTTPRequestHandler, directory=str(SITE_DIRECTORY))
server = ThreadingHTTPServer(("127.0.0.1", 8000), handler)

print(f"NORTH WEAR is running at {SITE_URL}. Press Ctrl+C to stop.")
webbrowser.open(SITE_URL)

try:
    server.serve_forever()
except KeyboardInterrupt:
    print("\nStopping NORTH WEAR local server.")
finally:
    server.server_close()
