#!/usr/bin/env python3
import json
import subprocess
import sys
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer

SHORTCUT_NAME = "ask-cloud-model"
PORT = 8088


def log(tag: str, message: str):
    timestamp = datetime.now().strftime("%H:%M:%S")
    print(f"[{timestamp}] [{tag}] {message}", flush=True)


class OpenAIProxyHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/v1/chat/completions":
            log("WARN", f"404 Not Found: {self.path}")
            self.send_response(404)
            self.end_headers()
            return

        content_length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(content_length)

        try:
            body = json.loads(raw_body)
        except Exception as e:
            log("ERROR", f"JSON Parse Error: {e}")
            self.send_response(400)
            self.end_headers()
            return

        # 会話履歴の整形
        messages = body.get("messages", [])
        log("INFO", f"Received request with {len(messages)} message(s)")

        # 最後のメッセージまたは全体を連結
        prompt = "\n".join(
            [f"{m.get('role', 'user')}: {m.get('content', '')}" for m in messages]
        )

        # ログに送出プロンプトを表示 (長い場合は先頭200文字程度)
        preview = prompt.replace("\n", " ")[:200]
        log("INPUT", f"Prompt preview: {preview}...")

        start_time = time.time()
        log("RUN", f"Calling shortcut: '{SHORTCUT_NAME}' via shortcuts run...")

        try:
            res = subprocess.run(
                [
                    "shortcuts",
                    "run",
                    SHORTCUT_NAME,
                    "--input-path",
                    "-",
                    "--output-path",
                    "-",
                    "--output-type",
                    "public.plain-text",
                ],
                input=prompt,
                capture_output=True,
                text=True,
                check=True,
            )
            elapsed = time.time() - start_time
            reply_text = res.stdout.strip()
            log("SUCCESS", f"Got response in {elapsed:.2f}s")
            log("OUTPUT", f"Result: {reply_text}")

        except subprocess.CalledProcessError as e:
            elapsed = time.time() - start_time
            error_msg = e.stderr.strip() if e.stderr else str(e)
            log("FAIL", f"Shortcut execution failed after {elapsed:.2f}s: {error_msg}")

            # 利用制限などに引っかかった場合のエラーメッセージ
            reply_text = f"PCC Shortcut Error: {error_msg}"

        # OpenAI 互換レスポンスの作成
        response_data = {
            "id": f"chatcmpl-{int(time.time())}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": "apple-cloud-model",
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": reply_text},
                    "finish_reason": "stop",
                }
            ],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        }

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(response_data, ensure_ascii=False).encode("utf-8"))
        log("INFO", "200 OK sent back to client\n" + "-" * 50)

    def log_message(self, format, *args):
        # http.server 既定のアクセスログ抑制 (カスタムログと重複防止)
        return


if __name__ == "__main__":
    print("=" * 50)
    print(f" PCC OpenAI Proxy Server Started")
    print(f" URL: http://localhost:{PORT}/v1/chat/completions")
    print(f" Target Shortcut: '{SHORTCUT_NAME}'")
    print("=" * 50)
    try:
        HTTPServer(("127.0.0.1", PORT), OpenAIProxyHandler).serve_forever()
    except KeyboardInterrupt:
        print("\nStopping server...")
        sys.exit(0)
