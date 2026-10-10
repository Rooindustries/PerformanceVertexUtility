import argparse
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import time
from urllib.parse import urlsplit

parser = argparse.ArgumentParser()
parser.add_argument("--directory", required=True)
parser.add_argument("--delay", type=float, default=25)
parser.add_argument("--feed-path", default="/ota-e2e/beta.json")
parser.add_argument("--fault", choices=["slow-feed", "http-error", "disconnect", "stall-installer"], default="slow-feed")
args = parser.parse_args()


class DelayedFeed(SimpleHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        if args.fault == "slow-feed" and path == args.feed_path:
            time.sleep(args.delay)
        elif path.endswith(".exe") and args.fault == "http-error":
            self.send_error(503, "Fixture installer is unavailable")
            return
        elif path.endswith(".exe") and args.fault in ("disconnect", "stall-installer"):
            self.send_response(200)
            self.send_header("Content-Length", "110000000")
            self.end_headers()
            if args.fault == "stall-installer":
                time.sleep(1250)
            else:
                self.wfile.write(b"fixture transport failure")
                self.wfile.flush()
                self.connection.shutdown(2)
            return
        try:
            super().do_GET()
        except (BrokenPipeError, ConnectionResetError):
            pass


ThreadingHTTPServer(("127.0.0.1", 13684), functools.partial(DelayedFeed, directory=args.directory)).serve_forever()
