import unittest

from src.omarchy_toggl.api import Api, AuthError, PlanError, QuotaError, RateError
from tests.fakes import FakeOpener


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.opener = FakeOpener()
        self.api = Api("tok", opener=self.opener, sleep=lambda s: None, clock=lambda: 1000)

    def test_records_user_quota_headers(self):
        self.opener.on("GET", "/me", lambda p, b: {"fullname": "R"})
        self.api.me()
        self.assertEqual(self.api.quota["user"]["remaining"], 24)
        self.assertEqual(self.api.quota["user"]["resetsAt"], 2800)
        self.assertNotIn("workspace", self.api.quota)

    def test_workspace_calls_use_workspace_bucket(self):
        self.opener.on("GET", "/workspaces/7/tags", lambda p, b: [])
        self.api.tags(7)
        self.assertIn("workspace", self.api.quota)

    def test_basic_auth_header(self):
        self.opener.on("GET", "/me", lambda p, b: {})
        self.api.me()
        # "tok:api_token" base64
        self.assertEqual(self.api._auth, "Basic dG9rOmFwaV90b2tlbg==")

    def test_error_mapping(self):
        self.opener.on("GET", "/me", lambda p, b: (403, "bad"))
        with self.assertRaises(AuthError):
            self.api.me()
        self.opener.on("GET", "/me", lambda p, b: (402, "quota"))
        with self.assertRaises(QuotaError) as ctx:
            self.api.me()
        self.assertEqual(ctx.exception.resets_in, 1800)

    def test_402_without_quota_headers_is_plan_error(self):
        import io, urllib.error
        from tests.fakes import headers

        def opener(req, timeout=None):
            raise urllib.error.HTTPError(req.full_url, 402, "plan", headers(None, None), io.BytesIO(b'"premium"'))
        api = Api("tok", opener=opener)
        with self.assertRaises(PlanError):
            api.me()

    def test_429_retries_once(self):
        calls = []
        self.opener.on("GET", "/me", lambda p, b: (calls.append(1), (429, "slow"))[1])
        with self.assertRaises(RateError):
            self.api.me()
        self.assertEqual(len(calls), 2)

    def test_stop_conflict_returns_none(self):
        self.opener.on("PATCH", "/workspaces/7/time_entries/5/stop", lambda p, b: (409, "stopped"))
        self.assertIsNone(self.api.stop(7, 5))

    def test_plus_is_percent_encoded(self):
        self.opener.on("GET", "/me/time_entries", lambda p, b: [])
        self.api.entries("2026-09-01T00:00:00+02:00", "2026-09-02")
        url = self.opener.requests[-1][4]
        self.assertIn("%2B02%3A00", url)
        self.assertIn("meta=true", url)

    def test_create_adds_created_with(self):
        self.opener.on("POST", "/workspaces/7/time_entries", lambda p, b: {"id": 1, **b})
        self.api.create(7, {"description": "x", "duration": -1})
        body = self.opener.requests[-1][3]
        self.assertEqual(body["created_with"], "omarchy-toggl")
        self.assertEqual(body["workspace_id"], 7)


if __name__ == "__main__":
    unittest.main()
