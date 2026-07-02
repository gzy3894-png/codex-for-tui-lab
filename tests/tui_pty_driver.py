#!/usr/bin/env python3
import argparse
import fcntl
import json
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import time
import termios
from pathlib import Path


def load_posts(shape_dir):
    posts = []
    for path in sorted(Path(shape_dir).glob("request-*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        if data.get("method") == "POST" and data.get("path") in {
            "/responses",
            "/v1/responses",
        }:
            posts.append((path, data))
    return posts


def request_summary(post):
    req = post.get("request") if isinstance(post, dict) else None
    return req if isinstance(req, dict) else {}


def upstream_error_summary(post):
    for key in ("upstream_error", "upstream_error_json"):
        value = post.get(key)
        if isinstance(value, dict):
            return value
    return None


def assert_response_shape_safe(path, post):
    status = post.get("upstream_status")
    if not isinstance(status, int) or not (200 <= status < 300):
        raise AssertionError(
            f"{path.name}: upstream status should be 2xx, got {status!r}; "
            f"error={upstream_error_summary(post)!r}"
        )
    if post.get("response_complete") is not True:
        raise AssertionError(f"{path.name}: upstream response did not complete")
    if not isinstance(post.get("response_bytes"), int) or post["response_bytes"] <= 0:
        raise AssertionError(f"{path.name}: upstream response was empty")

    req = request_summary(post)
    items = req.get("input_items")
    if not isinstance(items, list) or not items:
        raise AssertionError(f"{path.name}: request input summary is empty")
    for idx, item in enumerate(items):
        if not isinstance(item, dict):
            continue
        item_type = item.get("type")
        content_len = item.get("content_len")
        if item_type not in {None, "message"} and content_len not in {None, 0}:
            raise AssertionError(
                f"{path.name}: input[{idx}] type {item_type!r} carries "
                f"content_len={content_len}; this matches the relay 400 class"
            )


def assert_post(path, post, expected_model, expected_effort):
    assert_response_shape_safe(path, post)
    req = request_summary(post)
    model = req.get("model")
    reasoning = req.get("reasoning") or {}
    effort = reasoning.get("effort") if isinstance(reasoning, dict) else None
    if model != expected_model:
        raise AssertionError(
            f"{path.name}: model should be {expected_model!r}, got {model!r}"
        )
    if effort != expected_effort:
        raise AssertionError(
            f"{path.name}: reasoning effort should be {expected_effort!r}, got {effort!r}"
        )


def assert_workdir_agents_read(path, post):
    req = request_summary(post)
    marker_hits = req.get("marker_hits")
    if not isinstance(marker_hits, dict):
        raise AssertionError(f"{path.name}: request shape did not include marker_hits")
    if marker_hits.get("workdir_agents_marker") is not True:
        raise AssertionError(f"{path.name}: workdir AGENTS.md marker was not read")
    if marker_hits.get("workdir_agents_policy") is not True:
        raise AssertionError(f"{path.name}: workdir AGENTS.md policy was not read")


class PtySession:
    def __init__(self, argv, env, cwd, transcript_path, rows=40, cols=140):
        self.master_fd, slave_fd = pty.openpty()
        self.transcript_path = Path(transcript_path)
        self.set_window_size(slave_fd, rows, cols)
        env = env.copy()
        env["LINES"] = str(rows)
        env["COLUMNS"] = str(cols)
        self.proc = subprocess.Popen(
            argv,
            cwd=cwd,
            env=env,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            start_new_session=True,
            close_fds=True,
        )
        os.close(slave_fd)
        os.set_blocking(self.master_fd, False)
        self.transcript = open(transcript_path, "wb")

    def set_window_size(self, fd, rows, cols):
        try:
            winsize = struct.pack("HHHH", rows, cols, 0, 0)
            fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)
        except OSError:
            pass

    def read_available(self, timeout=0.1):
        chunks = []
        end = time.time() + timeout
        while time.time() < end:
            remaining = max(0.01, end - time.time())
            readable, _, _ = select.select([self.master_fd], [], [], remaining)
            if not readable:
                break
            try:
                data = os.read(self.master_fd, 65536)
            except BlockingIOError:
                break
            except OSError:
                break
            if not data:
                break
            self.transcript.write(data)
            self.transcript.flush()
            chunks.append(data)
        return b"".join(chunks)

    def drain(self, seconds):
        end = time.time() + seconds
        while time.time() < end and self.proc.poll() is None:
            self.read_available(0.2)

    def drain_until_quiet(self, min_seconds=0.5, quiet_seconds=0.5, timeout=10):
        start = time.time()
        deadline = start + timeout
        quiet_since = None
        while time.time() < deadline and self.proc.poll() is None:
            data = self.read_available(0.2)
            now = time.time()
            if data:
                quiet_since = None
            elif quiet_since is None:
                quiet_since = now
            elif now - start >= min_seconds and now - quiet_since >= quiet_seconds:
                return

    def send_bytes(self, data):
        os.write(self.master_fd, data)
        self.read_available(0.2)

    def send_text(self, text):
        self.send_bytes(text.encode("utf-8"))

    def send_enter(self):
        self.send_bytes(b"\r")

    def send_escape(self):
        self.send_bytes(b"\x1b")

    def clear_input(self):
        self.send_bytes(b"\x15")

    def send_text_and_enter(self, text):
        self.send_text(text)
        self.send_enter()

    def send(self, text):
        self.send_text(text)

    def wait_for_transcript_text(self, text, timeout=10):
        needle = text.encode("utf-8")
        deadline = time.time() + timeout
        while time.time() < deadline and self.proc.poll() is None:
            self.read_available(0.2)
            self.transcript.flush()
            try:
                haystack = self.transcript_path.read_bytes()
            except OSError:
                haystack = b""
            if needle in haystack:
                return
        raise TimeoutError(f"timed out waiting for TUI text {text!r}")

    def wait_for_any_transcript_text(self, texts, timeout=10):
        needles = [(text, text.encode("utf-8")) for text in texts]
        deadline = time.time() + timeout
        while time.time() < deadline and self.proc.poll() is None:
            self.read_available(0.2)
            self.transcript.flush()
            try:
                haystack = self.transcript_path.read_bytes()
            except OSError:
                haystack = b""
            for text, needle in needles:
                if needle in haystack:
                    return text
        choices = ", ".join(repr(text) for text in texts)
        raise TimeoutError(f"timed out waiting for any TUI text: {choices}")

    def close(self):
        try:
            self.send_bytes(b"\x03")
            time.sleep(0.5)
            self.read_available(0.5)
        except Exception:
            pass
        if self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
            except Exception:
                self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(self.proc.pid, signal.SIGKILL)
                except Exception:
                    self.proc.kill()
        try:
            os.close(self.master_fd)
        except Exception:
            pass
        self.transcript.close()


def wait_for_posts(session, shape_dir, count, timeout):
    deadline = time.time() + timeout
    last_seen = 0
    while time.time() < deadline:
        session.read_available(0.2)
        if session.proc.poll() is not None:
            raise RuntimeError(f"codex TUI exited early with rc={session.proc.returncode}")
        posts = load_posts(shape_dir)
        last_seen = len(posts)
        if len(posts) >= count:
            return posts
    raise TimeoutError(f"timed out waiting for {count} POST /responses logs; saw {last_seen}")


def open_model_picker(session, model):
    session.drain_until_quiet(min_seconds=0.5, quiet_seconds=0.3, timeout=5)
    session.send_escape()
    session.drain_until_quiet(min_seconds=1, quiet_seconds=0.5, timeout=20)
    session.clear_input()
    session.drain_until_quiet(min_seconds=0.3, quiet_seconds=0.2, timeout=3)
    session.send_text_and_enter("/model")
    session.wait_for_transcript_text(model, timeout=20)
    session.drain_until_quiet(min_seconds=0.5, quiet_seconds=0.3, timeout=10)


def switch_model(session, model, model_index, effort_index):
    open_model_picker(session, model)
    session.send_text(str(model_index))
    session.wait_for_any_transcript_text(["High", "高"], timeout=20)
    session.drain_until_quiet(min_seconds=0.5, quiet_seconds=0.3, timeout=10)
    session.send_text(str(effort_index))
    session.drain_until_quiet(min_seconds=1, quiet_seconds=0.5, timeout=20)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", required=True)
    parser.add_argument("--home", required=True)
    parser.add_argument("--codex-home", required=True)
    parser.add_argument("--work-dir", required=True)
    parser.add_argument("--shape-dir", required=True)
    parser.add_argument("--initial-model", required=True)
    parser.add_argument("--switch-model", action="append", required=True)
    parser.add_argument("--switch-index", action="append", type=int, required=True)
    parser.add_argument("--target-effort", default="high")
    parser.add_argument("--effort-index", type=int, default=3)
    parser.add_argument("--transcript", required=True)
    args = parser.parse_args()
    if len(args.switch_model) != len(args.switch_index):
        raise ValueError("--switch-model and --switch-index counts must match")
    if len(args.switch_model) < 3:
        raise ValueError("cloud gate must exercise at least three in-session model switches")

    env = os.environ.copy()
    env.update(
        {
            "HOME": args.home,
            "CODEX_HOME": args.codex_home,
            "TERM": "xterm-256color",
            "NO_COLOR": "1",
        }
    )

    session = PtySession(
        [args.bin],
        env=env,
        cwd=args.work_dir,
        transcript_path=args.transcript,
    )
    try:
        session.drain_until_quiet(min_seconds=2, quiet_seconds=1, timeout=30)
        session.send_text_and_enter("Reply exactly OK. cloud e2e first")
        posts = wait_for_posts(session, args.shape_dir, 1, 180)
        first_path, first_post = posts[0]
        assert_post(first_path, first_post, args.initial_model, "medium")
        assert_workdir_agents_read(first_path, first_post)

        for idx, (model, model_index) in enumerate(
            zip(args.switch_model, args.switch_index), start=1
        ):
            switch_model(session, model, model_index, args.effort_index)
            session.send_text_and_enter(f"Reply exactly OK. cloud e2e after switch {idx}")
            posts = wait_for_posts(session, args.shape_dir, idx + 1, 180)
            path, post = posts[idx]
            assert_post(path, post, model, args.target_effort)
            assert_workdir_agents_read(path, post)

        for path, post in load_posts(args.shape_dir):
            assert_response_shape_safe(path, post)
    finally:
        session.close()

    final_model = args.switch_model[-1]
    print(
        "OK: TUI repeated model/reasoning switches affected subsequent requests "
        f"({args.initial_model}/medium -> {final_model}/{args.target_effort}; "
        f"switches={len(args.switch_model)})"
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise
