#!/usr/bin/env python3
import argparse
import json
import os
import pty
import select
import signal
import subprocess
import sys
import time
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


def assert_post(path, post, expected_model, expected_effort):
    status = post.get("upstream_status")
    if not isinstance(status, int) or not (200 <= status < 300):
        raise AssertionError(
            f"{path.name}: upstream status should be 2xx, got {status!r}; "
            f"error={post.get('upstream_error_json')!r}"
        )
    if post.get("response_complete") is not True:
        raise AssertionError(f"{path.name}: upstream response did not complete")
    if not isinstance(post.get("response_bytes"), int) or post["response_bytes"] <= 0:
        raise AssertionError(f"{path.name}: upstream response was empty")

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


class PtySession:
    def __init__(self, argv, env, cwd, transcript_path):
        self.master_fd, slave_fd = pty.openpty()
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

    def send(self, text):
        os.write(self.master_fd, text.encode("utf-8"))
        self.read_available(0.2)

    def close(self):
        try:
            self.send("\x03")
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", required=True)
    parser.add_argument("--home", required=True)
    parser.add_argument("--codex-home", required=True)
    parser.add_argument("--work-dir", required=True)
    parser.add_argument("--shape-dir", required=True)
    parser.add_argument("--initial-model", required=True)
    parser.add_argument("--target-model", required=True)
    parser.add_argument("--target-effort", default="high")
    parser.add_argument("--transcript", required=True)
    args = parser.parse_args()

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
        [args.bin, "--skip-git-repo-check"],
        env=env,
        cwd=args.work_dir,
        transcript_path=args.transcript,
    )
    try:
        session.drain(3)
        session.send("Reply exactly OK. cloud e2e first\n")
        posts = wait_for_posts(session, args.shape_dir, 1, 180)
        first_path, first_post = posts[0]
        assert_post(first_path, first_post, args.initial_model, "medium")

        session.drain(3)
        session.send("/model\n")
        session.drain(1)
        session.send("2")
        session.drain(1)
        session.send("3")
        session.drain(2)
        session.send("Reply exactly OK. cloud e2e after switch\n")
        posts = wait_for_posts(session, args.shape_dir, 2, 180)
        second_path, second_post = posts[1]
        assert_post(second_path, second_post, args.target_model, args.target_effort)
    finally:
        session.close()

    print(
        "OK: TUI model/reasoning switch affected next request "
        f"({args.initial_model}/medium -> {args.target_model}/{args.target_effort})"
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise
