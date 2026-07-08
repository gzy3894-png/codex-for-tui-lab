#!/usr/bin/env python3
import argparse
import copy
import json
import os
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


REQUEST_MARKERS = {
    "codex_home_agents_marker": "user codex-home agents marker",
    "home_agents_marker": "user workdir agents marker",
    "workdir_agents_marker": "user actual workdir agents marker",
    "workdir_agents_policy": "For cloud E2E prompts that ask to reply exactly OK",
}


def normalize_backend_base(value):
    value = value.strip().rstrip("/")
    if not value:
        raise ValueError("backend base is empty")
    return value


def target_url(backend_base, path):
    if path.startswith("/v1/"):
        suffix = path[len("/v1") :]
    elif path == "/v1":
        suffix = ""
    else:
        suffix = path
    return backend_base + suffix


def summarize_content(content):
    if not isinstance(content, list):
        return {"content_is_list": False}
    return {
        "content_is_list": True,
        "content_len": len(content),
        "content_item_types": [
            item.get("type") if isinstance(item, dict) else type(item).__name__
            for item in content
        ],
        "content_item_keys": [
            sorted(item.keys()) if isinstance(item, dict) else []
            for item in content
        ],
    }


def summarize_input_item(item):
    if not isinstance(item, dict):
        return {"json_type": type(item).__name__}
    summary = {
        "type": item.get("type"),
        "role": item.get("role"),
        "author": item.get("author"),
        "recipient": item.get("recipient"),
        "keys": sorted(item.keys()),
        "has_encrypted_content": bool(item.get("encrypted_content")),
    }
    summary.update(summarize_content(item.get("content")))
    if isinstance(item.get("summary"), list):
        summary["summary_len"] = len(item["summary"])
    if isinstance(item.get("output"), dict):
        summary["output_keys"] = sorted(item["output"].keys())
    return summary


def contains_text(value, needle):
    if isinstance(value, str):
        return needle in value
    if isinstance(value, list):
        return any(contains_text(item, needle) for item in value)
    if isinstance(value, dict):
        return any(contains_text(item, needle) for item in value.values())
    return False


def summarize_request(body):
    try:
        payload = json.loads(body.decode("utf-8")) if body else None
    except Exception as exc:
        return {"body_json": False, "error": str(exc)}
    if not isinstance(payload, dict):
        return {"body_json": True, "json_type": type(payload).__name__}
    input_items = payload.get("input")
    tools = payload.get("tools")
    reasoning = payload.get("reasoning")
    text = payload.get("text")
    return {
        "body_json": True,
        "marker_hits": {
            name: contains_text(payload, marker)
            for name, marker in REQUEST_MARKERS.items()
        },
        "top_keys": sorted(payload.keys()),
        "model": payload.get("model"),
        "service_tier": payload.get("service_tier"),
        "stream": payload.get("stream"),
        "parallel_tool_calls": payload.get("parallel_tool_calls"),
        "include": payload.get("include"),
        "input_count": len(input_items) if isinstance(input_items, list) else None,
        "input_items": [
            summarize_input_item(item)
            for item in input_items
        ]
        if isinstance(input_items, list)
        else None,
        "tool_count": len(tools) if isinstance(tools, list) else None,
        "tool_types": [
            tool.get("type") if isinstance(tool, dict) else type(tool).__name__
            for tool in tools
        ]
        if isinstance(tools, list)
        else None,
        "reasoning": {
            "keys": sorted(reasoning.keys()),
            "effort": reasoning.get("effort"),
            "summary": reasoning.get("summary"),
            "context": reasoning.get("context"),
        }
        if isinstance(reasoning, dict)
        else None,
        "text_keys": sorted(text.keys()) if isinstance(text, dict) else None,
    }


def summarize_response_json(body):
    try:
        payload = json.loads(body.decode("utf-8")) if body else None
    except Exception as exc:
        return {"body_json": False, "error": str(exc)}
    if not isinstance(payload, dict):
        return {"body_json": True, "json_type": type(payload).__name__}
    error = payload.get("error")
    if isinstance(error, dict):
        return {
            "body_json": True,
            "error": {
                "message": error.get("message"),
                "type": error.get("type"),
                "param": error.get("param"),
                "code": error.get("code"),
            },
        }
    return {"body_json": True, "top_keys": sorted(payload.keys())}


def text_model_items(payload):
    data = payload.get("data")
    if not isinstance(data, list):
        return []
    items = []
    for item in data:
        if not isinstance(item, dict):
            continue
        model_id = item.get("id")
        if not isinstance(model_id, str) or not model_id:
            continue
        if "image" in model_id.lower() or model_id.startswith("codex-auto-"):
            continue
        items.append(item)
    return items


def ensure_text_model_aliases(payload, minimum_count):
    if minimum_count <= 0 or not isinstance(payload, dict):
        return {}, payload
    data = payload.get("data")
    if not isinstance(data, list):
        return {}, payload
    text_items = text_model_items(payload)
    if len(text_items) >= minimum_count or not text_items:
        return {}, payload
    existing_ids = {
        item.get("id")
        for item in data
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    target = text_items[0]
    target_id = target["id"]
    aliases = {}
    out = copy.deepcopy(payload)
    out_data = out.get("data")
    idx = 1
    while len(text_items) + len(aliases) < minimum_count:
        alias = f"codex-tui-switch-{idx}"
        idx += 1
        if alias in existing_ids:
            continue
        cloned = copy.deepcopy(target)
        cloned["id"] = alias
        out_data.append(cloned)
        existing_ids.add(alias)
        aliases[alias] = target_id
    return aliases, out


class Handler(BaseHTTPRequestHandler):
    backend_base = ""
    log_dir = ""
    counter = 0
    ensure_text_model_aliases = 0
    model_alias_map = {}

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def write_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def write_log(self, payload):
        Handler.counter += 1
        path = os.path.join(Handler.log_dir, f"request-{Handler.counter:03d}.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, indent=2, sort_keys=True)
            fh.write("\n")

    def forward(self, method):
        body = self.rfile.read(int(self.headers.get("content-length", "0") or "0"))
        parsed = urlsplit(self.path)
        path = parsed.path + (("?" + parsed.query) if parsed.query else "")
        if parsed.path == "/healthz":
            self.write_json(200, {"ok": True})
            return

        shape = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "method": method,
            "path": parsed.path,
            "headers": {
                "content-type": self.headers.get("content-type"),
                "accept": self.headers.get("accept"),
            },
        }
        if method == "POST":
            shape["request"] = summarize_request(body)
            if Handler.model_alias_map:
                try:
                    payload = json.loads(body.decode("utf-8")) if body else None
                    if isinstance(payload, dict):
                        model = payload.get("model")
                        if model in Handler.model_alias_map:
                            payload["model"] = Handler.model_alias_map[model]
                            body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
                            shape["model_alias"] = {
                                "requested": model,
                                "backend": Handler.model_alias_map[model],
                            }
                except Exception as exc:
                    shape["model_alias_error"] = repr(exc)

        req_headers = {}
        for key, value in self.headers.items():
            lower = key.lower()
            if lower in {"host", "content-length", "connection", "accept-encoding"}:
                continue
            req_headers[key] = value

        req = urllib.request.Request(
            target_url(Handler.backend_base, path),
            data=body if method != "GET" else None,
            headers=req_headers,
            method=method,
        )
        if (
            method == "GET"
            and parsed.path == "/v1/models"
            and Handler.ensure_text_model_aliases > 0
        ):
            try:
                with urllib.request.urlopen(req, timeout=180) as upstream:
                    upstream_body = upstream.read()
                    payload = json.loads(upstream_body.decode("utf-8"))
                    aliases, payload = ensure_text_model_aliases(
                        payload,
                        Handler.ensure_text_model_aliases,
                    )
                    Handler.model_alias_map.update(aliases)
                    out = json.dumps(payload).encode("utf-8")
                    shape["upstream_status"] = upstream.status
                    shape["model_aliases"] = aliases
                    self.send_response(upstream.status)
                    self.send_header("content-type", "application/json")
                    self.send_header("content-length", str(len(out)))
                    self.end_headers()
                    self.wfile.write(out)
                    shape["response_complete"] = True
                    shape["response_bytes"] = len(out)
                    self.write_log(shape)
            except urllib.error.HTTPError as exc:
                error_body = exc.read()
                shape["upstream_status"] = exc.code
                shape["upstream_error"] = summarize_response_json(error_body)
                self.write_log(shape)
                self.send_response(exc.code)
                for key, value in exc.headers.items():
                    if key.lower() in {"transfer-encoding", "connection"}:
                        continue
                    self.send_header(key, value)
                self.end_headers()
                self.wfile.write(error_body)
            except Exception as exc:
                shape["proxy_error"] = repr(exc)
                self.write_log(shape)
                self.write_json(502, {"error": "proxy_error", "message": str(exc)})
            return

        try:
            with urllib.request.urlopen(req, timeout=180) as upstream:
                shape["upstream_status"] = upstream.status
                self.send_response(upstream.status)
                for key, value in upstream.headers.items():
                    if key.lower() in {"transfer-encoding", "connection"}:
                        continue
                    self.send_header(key, value)
                self.end_headers()
                bytes_sent = 0
                chunks_sent = 0
                while True:
                    chunk = upstream.read(65536)
                    if not chunk:
                        break
                    bytes_sent += len(chunk)
                    chunks_sent += 1
                    self.wfile.write(chunk)
                    self.wfile.flush()
                shape["response_complete"] = True
                shape["response_bytes"] = bytes_sent
                shape["response_chunks"] = chunks_sent
                self.write_log(shape)
        except urllib.error.HTTPError as exc:
            error_body = exc.read()
            shape["upstream_status"] = exc.code
            shape["upstream_error"] = summarize_response_json(error_body)
            self.write_log(shape)
            self.send_response(exc.code)
            for key, value in exc.headers.items():
                if key.lower() in {"transfer-encoding", "connection"}:
                    continue
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(error_body)
        except Exception as exc:
            shape["proxy_error"] = repr(exc)
            self.write_log(shape)
            self.write_json(502, {"error": "proxy_error", "message": str(exc)})

    def do_GET(self):
        self.forward("GET")

    def do_POST(self):
        self.forward("POST")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--backend-base", required=True)
    parser.add_argument("--log-dir", required=True)
    parser.add_argument("--ensure-text-model-aliases", type=int, default=0)
    args = parser.parse_args()

    Handler.backend_base = normalize_backend_base(args.backend_base)
    Handler.log_dir = args.log_dir
    Handler.ensure_text_model_aliases = args.ensure_text_model_aliases
    os.makedirs(Handler.log_dir, exist_ok=True)

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"relay_shape_proxy listening on {args.host}:{args.port}", flush=True)
    sys.stdout.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
