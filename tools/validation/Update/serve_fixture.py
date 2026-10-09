import argparse
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import time
from urllib.parse import urlsplit

parser = argparse.ArgumentParser()
parser.add_argument("--directory", required=True)
parser.add_argument("--delay", type=float, default=25)
args = parser.parse_args()


class DelayedFeed(SimpleHTTPRequestHandler):
    def do_GET(self):
        if urlsplit(self.path).path == "/ota-e2e/beta.json":
            time.sleep(args.delay)
        try:
            super().do_GET()
        except (BrokenPipeError, ConnectionResetError):
            pass


ThreadingHTTPServer(("127.0.0.1", 13684), functools.partial(DelayedFeed, directory=args.directory)).serve_forever()
