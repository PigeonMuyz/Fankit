from http.server import HTTPServer, BaseHTTPRequestHandler
import time

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        if self.path == "/known":
            self.send_header("Content-Length", str(512 * 1024))
        self.end_headers()
        for _ in range(64):
            self.wfile.write(b"x" * 8192)
            self.wfile.flush()
            time.sleep(0.01)
    def log_message(self, *args):
        pass

server = HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
