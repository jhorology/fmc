"""Transport contracts tested through zsh, without generating or executing commands."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


SOURCE = Path(__file__).resolve().parents[1] / "fmc.zsh"


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.requests = []
        self.responses = []
        case = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                case.requests.append((self.path, json.loads(body)))
                status, response = case.responses.pop(0)
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(
                    response.encode() if isinstance(response, str)
                    else json.dumps(response).encode()
                )

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.env = {
            **os.environ,
            "FMC_BACKEND": "fm-serve",
            "FMC_BASE_URL": f"http://127.0.0.1:{self.server.server_port}/v1/",
            "FMC_MODEL": "pcc",
            "FMC_TIMEOUT": "3",
            "FMC_HISTORY_FILE": str(Path(self.temp.name) / "history"),
            "FMC_MAX_RETRIES": "2",
            "FMC_CLOUD_NUM_EXAMPLES": "0",
            "FMC_NUM_EXAMPLES": "8",
            "FMC_EXAMPLES_FILE": str(SOURCE.parent / "data/examples.tsv"),
            "FMC_RULES_FILE": str(SOURCE.parent / "data/rules.tsv"),
        }

    def run_zsh(self, script, *args):
        return subprocess.run(
            ["zsh", "-f", "-c", 'source "$1"; shift; ' + script, "test", str(SOURCE), *args],
            env=self.env, text=True, capture_output=True, timeout=15,
        )

    def respond(self, content="pwd", **message):
        self.responses.append((200, {
            "choices": [{"finish_reason": "stop", "message": {"content": content, **message}}],
        }))

    def test_api_preserves_prompts_and_selects_model(self):
        self.respond("```zsh\npwd\n```")
        prompt = '日本語の依頼 "quotes"\n$(touch never-execute)'
        instructions = "Instructions\nwith examples"
        result = self.run_zsh('_fmc_generate "$1" "$2" greedy', prompt, instructions)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "pwd\n")
        path, body = self.requests[0]
        self.assertEqual(path, "/v1/chat/completions")
        self.assertEqual(body["model"], "pcc")
        self.assertEqual(body["temperature"], 0)
        self.assertIs(body["stream"], False)
        self.assertEqual(body["messages"], [
            {"role": "system", "content": instructions},
            {"role": "user", "content": prompt},
        ])

    def test_sampling_retry_omits_greedy_temperature(self):
        self.respond()
        result = self.run_zsh('_fmc_generate prompt instructions sample')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("temperature", self.requests[0][1])

    def test_model_option_is_local_to_invocation(self):
        self.respond()
        self.respond()
        result = self.run_zsh('fmc -p -m system "カレントディレクトリを表示"; fmc -p "カレントディレクトリを表示"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "pwd\npwd\n")
        self.assertEqual([b["model"] for _, b in self.requests], ["system", "pcc"])

    def test_pcc_omits_examples_while_system_keeps_them(self):
        self.respond("date -v-1d +%Y-%m-%d")
        self.respond("date -v-1d +%Y-%m-%d")
        result = self.run_zsh('fmc -p -m system "昨日の日付"; fmc -p -m pcc "昨日の日付"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 2)
        self.assertIn("Examples:", self.requests[0][1]["messages"][0]["content"])
        self.assertNotIn("Examples:", self.requests[1][1]["messages"][0]["content"])

    def test_validation_feedback_reaches_api(self):
        self.respond("fmc_nonexistent_command")
        self.respond()
        result = self.run_zsh('fmc -p "カレントディレクトリを表示"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "pwd\n")
        self.assertEqual(len(self.requests), 2)
        self.assertIn("Wrong answer: fmc_nonexistent_command", self.requests[1][1]["messages"][1]["content"])

    def test_unavailable_pcc_does_not_fall_back(self):
        self.responses.append((503, {"error": {"message": "Please use the Terminal app."}}))
        result = self.run_zsh('fm() { print UNEXPECTED_FALLBACK; }; fmc -p "今日の日付を表示"')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("HTTP 503", result.stderr)
        self.assertIn("Please use the Terminal app.", result.stderr)
        self.assertEqual(len(self.requests), 1)

    def test_invalid_or_refused_responses_fail(self):
        for response in ["not json", {}, {"choices": [{"message": {"content": None, "refusal": "Denied"}}]},
                         {"choices": [{"finish_reason": "length", "message": {"content": "partial"}}]}]:
            with self.subTest(response=response):
                self.responses.append((200, response))
                result = self.run_zsh('_fmc_generate prompt instructions')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_cli_backend_keeps_sampling_and_model_options(self):
        self.env["FMC_BACKEND"] = "local"
        self.env["FMC_TEST_ARGS"] = str(Path(self.temp.name) / "cli-args")
        result = self.run_zsh('fm() { print -rl -- "$@" > "$FMC_TEST_ARGS"; print pwd; }; _fmc_generate prompt instructions')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "pwd\n")
        self.assertIn("--no-stream\n--greedy\n--model\npcc\n", Path(self.env["FMC_TEST_ARGS"]).read_text())
        self.assertEqual(self.requests, [])

    def test_print_mode_does_not_execute_api_command(self):
        marker = Path(self.temp.name) / "must-not-exist"
        self.respond(f"touch {marker}")
        result = self.run_zsh('fmc -p "指定ファイルを作成: $1"', str(marker))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"touch {marker}\n")
        self.assertFalse(marker.exists())

    def test_dangerous_api_command_is_blocked(self):
        self.env["FMC_MAX_RETRIES"] = "0"
        self.respond("rm -rf ~")
        result = self.run_zsh('fmc -p "ファイルを削除"')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("危険なコマンド", result.stderr)

    def test_invalid_backend_and_missing_option_value_fail(self):
        for options in ("--backend invalid request", "--backend", "--base-url", "-m"):
            with self.subTest(options=options):
                result = self.run_zsh("fmc -p " + options)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
        self.assertEqual(self.requests, [])

    def test_local_flag_resets_pcc_and_preserves_environment(self):
        self.env["FMC_TEST_ARGS"] = str(Path(self.temp.name) / "cli-args")
        result = self.run_zsh('fm() { print -rl -- "$@" > "$FMC_TEST_ARGS"; print pwd; }; fmc -l -p "カレントディレクトリを表示"; print "$FMC_MODEL"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "pwd\npcc\n")
        self.assertIn("--model\nsystem\n", Path(self.env["FMC_TEST_ARGS"]).read_text())
        self.assertEqual(self.requests, [])

    def test_shortcut_cloud_backend_is_preserved(self):
        self.env["FMC_SHORTCUT_NAME"] = "test-cloud"
        self.env["FMC_TEST_PROMPT"] = str(Path(self.temp.name) / "shortcut-prompt")
        result = self.run_zsh('shortcuts() { [[ "$1 $2" == "run test-cloud" ]] || return 1; cat > "$FMC_TEST_PROMPT"; print pwd; }; fmc -c -p "カレントディレクトリを表示"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "pwd\n")
        prompt = Path(self.env["FMC_TEST_PROMPT"]).read_text()
        self.assertIn("Request: カレントディレクトリを表示", prompt)
        self.assertNotIn("Examples:", prompt)
        self.assertEqual(self.requests, [])

    def test_shortcut_failure_still_falls_back_to_on_device(self):
        self.env["FMC_TEST_ARGS"] = str(Path(self.temp.name) / "cli-args")
        result = self.run_zsh('shortcuts() { cat >/dev/null; print unavailable >&2; return 1; }; fm() { print -rl -- "$@" > "$FMC_TEST_ARGS"; print pwd; }; fmc -c -p "カレントディレクトリを表示"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "pwd\n")
        self.assertIn("--model\nsystem\n", Path(self.env["FMC_TEST_ARGS"]).read_text())
        self.assertEqual(self.requests, [])


if __name__ == "__main__":
    unittest.main()
