import json
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import bridge


class BridgeSecurityTests(unittest.TestCase):
    def setUp(self):
        self.original_token = bridge.TOKEN
        bridge.TOKEN = "test-secret"
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), bridge.Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        bridge.TOKEN = self.original_token

    def request(self, path, *, method="GET", token=None, data=None):
        headers = {}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        body = None if data is None else json.dumps(data).encode()
        if body is not None:
            headers["Content-Type"] = "application/json"
        return urllib.request.urlopen(
            urllib.request.Request(
                self.base_url + path,
                data=body,
                headers=headers,
                method=method,
            ),
            timeout=2,
        )

    def test_non_loopback_bind_requires_token(self):
        with self.assertRaisesRegex(ValueError, "HERMES_WIDGET_TOKEN"):
            bridge.validate_bind_security("0.0.0.0", "")
        bridge.validate_bind_security("0.0.0.0", "configured")
        bridge.validate_bind_security("127.0.0.1", "")

    def test_get_requires_token(self):
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.request("/session")
        self.assertEqual(error.exception.code, 401)
        error.exception.close()

        with self.request("/session", token="test-secret") as response:
            self.assertEqual(response.status, 200)

    def test_loopback_mode_allows_requests_without_token(self):
        bridge.TOKEN = ""
        with self.request("/session") as response:
            self.assertEqual(response.status, 200)

    def test_post_requires_token(self):
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.request("/chat/new", method="POST", data={})
        self.assertEqual(error.exception.code, 401)
        error.exception.close()

        with self.request(
            "/chat/new", method="POST", token="test-secret", data={}
        ) as response:
            self.assertEqual(response.status, 200)

    def test_oversized_request_is_rejected(self):
        original_limit = bridge.MAX_REQUEST_BYTES
        bridge.MAX_REQUEST_BYTES = 1
        try:
            with self.assertRaises(urllib.error.HTTPError) as error:
                self.request(
                    "/chat/new", method="POST", token="test-secret", data={}
                )
            self.assertEqual(error.exception.code, 413)
            error.exception.close()
        finally:
            bridge.MAX_REQUEST_BYTES = original_limit

    def test_authenticated_model_switch_uses_bridge_endpoint(self):
        original_current_model = bridge.current_model
        original_set_model = bridge.set_model
        bridge.current_model = lambda: ("old-model", "deepseek")
        bridge.set_model = lambda model_id: (
            {"id": model_id, "provider": "deepseek"},
            None,
        )
        try:
            with self.request(
                "/model",
                method="POST",
                token="test-secret",
                data={"model": "deepseek-chat"},
            ) as response:
                payload = json.load(response)
            self.assertEqual(payload["model"], "deepseek-chat")
            self.assertEqual(payload["previous"], "old-model")
        finally:
            bridge.current_model = original_current_model
            bridge.set_model = original_set_model


if __name__ == "__main__":
    unittest.main()
