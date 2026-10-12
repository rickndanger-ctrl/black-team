#!/usr/bin/env python3
"""A stand-in for an OpenAI-compatible cloud service, for testing Black Team's wire format without a real key.

    python3 stub.py <port> <record.jsonl> [--strict]

It listens on 127.0.0.1 only, records every POST body it receives (one JSON object per line, with the Authorization header
reduced to its length so the record never holds a key), and answers:

  GET  /v1/models            a short model list
  POST /v1/chat/completions  without tools: a streamed sentence and a usage chunk
                             with tools: a canned tool-calling exchange (read notes.txt, edit it, then say it is done)

--strict makes it behave like a service that refuses some fields, so the learn-from-400 behaviour can be seen:
  temperature -> 400 "Unsupported value" (param temperature); max_tokens -> 400 "Use 'max_completion_tokens' instead";
  reasoning_effort -> 400 "Unrecognized request argument".
"""
import json, os, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, record = int(sys.argv[1]), sys.argv[2]
strict = "--strict" in sys.argv
lock = threading.Lock()
expected = os.environ.get("STUB_EXPECT_KEY", "")


def log(entry):
    with lock, open(record, "a") as f:
        f.write(json.dumps(entry) + "\n")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        auth = self.headers.get("Authorization", "")
        log({"method": "GET", "path": self.path, "authorization_length": len(auth), "authorization_is_expected_key": bool(expected) and auth == "Bearer " + expected, "has_x_api_key": "x-api-key" in {k.lower() for k in self.headers.keys()}})
        if self.path.split("?")[0] == "/v1/models":
            return self._json(200, {"object": "list", "data": [{"id": "stand-in-large", "context_length": 200000}, {"id": "stand-in-small"}]})
        self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        auth = self.headers.get("Authorization", "")
        entry = {"method": "POST", "path": self.path, "authorization_length": len(auth), "authorization_is_expected_key": bool(expected) and auth == "Bearer " + expected, "body": body}
        if strict:
            refusal = None
            if "temperature" in body:
                refusal = {"error": {"message": "Unsupported value: 'temperature' does not support 0.7 with this model. Only the default (1) value is supported.", "type": "invalid_request_error", "param": "temperature", "code": "unsupported_value"}}
            elif "max_tokens" in body:
                refusal = {"error": {"message": "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.", "type": "invalid_request_error", "param": "max_tokens", "code": "unsupported_parameter"}}
            elif "reasoning_effort" in body:
                refusal = {"error": {"message": "Unrecognized request argument supplied: reasoning_effort", "type": "invalid_request_error", "param": "reasoning_effort"}}
            if refusal:
                entry["answered"] = 400
                log(entry)
                return self._json(400, refusal)
        entry["answered"] = 200
        log(entry)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        out = lambda chunk: self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode()) or self.wfile.flush()
        messages = body.get("messages", [])
        last_user = max([i for i, m in enumerate(messages) if m.get("role") == "user"] or [0])
        done = [m for m in messages[last_user + 1:] if m.get("role") == "tool"]
        usage = lambda p, c: {"choices": [], "usage": {"prompt_tokens": p, "completion_tokens": c, "prompt_tokens_details": {"cached_tokens": p // 4}}}
        if body.get("tools"):
            call = None
            if len(done) == 0:
                call = ("read", {"path": "notes.txt"})
            elif len(done) == 1:
                call = ("edit", {"path": "notes.txt", "old": "version=1", "new": "version=2"})
            if call:
                out({"choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}}]})
                out({"choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "id": "call_%d" % len(done), "type": "function", "function": {"name": call[0], "arguments": json.dumps(call[1])}}]}}]})
                out({"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]})
                out(usage(900 + 300 * len(done), 40))
            else:
                for piece in ["I changed ", "notes.txt to version=2."]:
                    out({"choices": [{"index": 0, "delta": {"content": piece}}]})
                out({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
                out(usage(1500, 30))
        else:
            for piece in ["Hello from ", "the stand-in service."]:
                out({"choices": [{"index": 0, "delta": {"content": piece}}]})
            out({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
            out(usage(120, 12))
        self.wfile.write(b"data: [DONE]\n\n")


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
