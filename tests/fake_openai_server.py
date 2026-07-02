#!/usr/bin/env python3
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    models = []

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def _write_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self._write_json(200, {"ok": True})
            return
        if self.path == "/v1/models":
            self._write_json(200, {"data": [{"id": model} for model in self.models]})
            return
        self._write_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/v1/responses":
            self._write_json(200, {
                "id": "resp_lab_fake",
                "object": "response",
                "status": "completed",
                "output": [],
            })
            return
        self._write_json(404, {"error": "not found"})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--models", required=True)
    args = parser.parse_args()
    Handler.models = [item.strip() for item in args.models.split(",") if item.strip()]
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"fake_openai_server listening on {args.host}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
