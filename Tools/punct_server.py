"""Punctuation restoration micro-service for LingoClass.
Run: python3 punct_server.py
Endpoint: POST /punct  { "text": "hello world" }  ->  { "text": "Hello world." }
"""
from http.server import HTTPServer, BaseHTTPRequestHandler
import json, sys

_model = None

def get_model():
    global _model
    if _model is None:
        try:
            from rpunct import RestorePuncts
            _model = RestorePuncts.restore("english")
            print("rpunct model loaded", file=sys.stderr)
        except Exception as e:
            print(f"rpunct load failed: {e}", file=sys.stderr)
            _model = False
    return _model

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/punct":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length))
        text = body.get("text", "")
        model = get_model()
        if model and text.strip():
            try:
                punctuated = model.punctuate(text)
                result = {"text": punctuated}
            except Exception:
                result = {"text": text}
        else:
            result = {"text": text}
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(result).encode())

    def log_message(self, format, *args):
        print(f"[punct] {args[0]}", file=sys.stderr)

if __name__ == "__main__":
    port = 18976
    print(f"Punctuation server on http://127.0.0.1:{port}", file=sys.stderr)
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
