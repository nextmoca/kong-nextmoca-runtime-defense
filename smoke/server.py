import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer


class SmokeHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"status": "ok"})
            return
        self._send(404, {"error": "not_found"})

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", "0"))
        payload = json.loads(self.rfile.read(content_length) or b"{}")
        if os.environ.get("ROLE") == "selector":
            record = payload["records"][0]
            selected_text = record["text"].split(".", 1)[0] + "."
            self._send(
                200,
                {
                    "request_id": payload["request_id"],
                    "outcome": "selected",
                    "fallback_used": False,
                    "tokens_before": 100,
                    "tokens_after": 40,
                    "tokens_saved": 60,
                    "engine_latency_ms": 7.5,
                    "rendered_context": selected_text,
                    "selected": [
                        {
                            "record_id": record["id"],
                            "excerpt": selected_text,
                        }
                    ],
                },
            )
            return
        self._send(200, {"received": payload})

    def log_message(self, format, *args):
        return

    def _send(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


HTTPServer(("0.0.0.0", 8080), SmokeHandler).serve_forever()
