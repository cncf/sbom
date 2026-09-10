import contextlib
from datetime import datetime, timezone
from email.message import Message
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import Mock, patch
from urllib import error
from urllib.response import addinfourl


spec = importlib.util.spec_from_file_location(
    "sandbox_applications", Path(__file__).resolve().parents[1] / "sandbox-applications.py"
)
watcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watcher)
START = "2026-09-01T00:00:00Z"
NOW = datetime(2026, 9, 1, tzinfo=timezone.utc)
SHA = "a1" * 20


def issue(number=1, state="open", created="2020-01-01T00:00:00Z", body=None, **extra):
    return {
        "number": number, "state": state, "created_at": created,
        "title": "[Sandbox] Test",
        "body": body if body is not None else f"### {watcher.FIELD}\n\nhttps://github.com/Owner/Repo\n\n### Other\nhttps://github.com/Other/No",
        **extra,
    }


def store(keys=None):
    result = Mock()
    result.keys.return_value = {watcher.STARTED_KEY} if keys is None else keys
    result.read_started.return_value = START
    return result


def github_issues(*issues):
    result = Mock()
    result.issues.return_value = iter(issues)
    return result


class ParsingTests(unittest.TestCase):
    def repositories(self, body):
        return watcher.application_repositories(body, 123)

    def test_heading_only_selects_application_field(self):
        body = (
            "### Website\nhttps://github.com/Before/No\n\n"
            f"### {watcher.FIELD}\n\nhttps://github.com/ray-project/kuberay\n\n"
            "### Another heading\nhttps://github.com/After/No\n"
        )
        self.assertEqual(self.repositories(body), [("ray-project", "kuberay")])

    def test_plain_label_and_neighboring_labels(self):
        body = (
            f"{watcher.FIELD}\n\nhttps://github.com/Owner/Repo\n"
            "https://github.com/Second/Repo\n\nProject website\nhttps://github.com/Other/No"
        )
        self.assertEqual(self.repositories(body), [("Owner", "Repo"), ("Second", "Repo")])

    def test_empty_plain_field_does_not_read_next_label(self):
        body = f"{watcher.FIELD}\nProject website\nhttps://github.com/Other/No"
        with contextlib.redirect_stderr(io.StringIO()) as output:
            self.assertEqual(self.repositories(body), [])
        self.assertIn("::warning::", output.getvalue())

    def test_multiple_markdown_links_git_slash_and_case_dedup(self):
        body = (
            f"### {watcher.FIELD}\n"
            "- [one](https://github.com/Owner/Repo.git/)\n"
            "- <https://github.com/owner/repo/>\n"
            "- [two](https://github.com/Second/.github)\n"
        )
        self.assertEqual(self.repositories(body), [("Owner", "Repo"), ("Second", ".github")])

    def test_missing_empty_and_malformed_fields_warn(self):
        for body in (None, "", "### Something else\nhttps://github.com/a/b", f"### {watcher.FIELD}\n_No response_", f"### {watcher.FIELD}\nhttps://evil.test/a/b"):
            with self.subTest(body=body), contextlib.redirect_stderr(io.StringIO()) as output:
                self.assertEqual(self.repositories(body), [])
                self.assertIn("::warning::Issue #123:", output.getvalue())

    def test_invalid_link_does_not_discard_valid_link(self):
        with contextlib.redirect_stderr(io.StringIO()) as output:
            self.assertEqual(self.repositories(f"### {watcher.FIELD}\nhttps://evil.test/a/b https://github.com/a/b"), [("a", "b")])
            self.assertIn("::warning::", output.getvalue())

    def test_identity_and_url_guards(self):
        invalid = [
            "http://github.com/a/b", "https://github.com.evil.test/a/b",
            "https://user:secret@github.com/a/b", "https://github.com:443/a/b",
            "https://github.com/a/b/pull/1", "https://github.com/a/b?x=1",
            "https://github.com/a/b#readme", "https://github.com/a/..",
            "https://github.com/a/%2e%2e", "https://github.com/a/b%2fc",
            "https://github.com/a/b;touch", "https://github.com/a/$(id)",
            "https://github.com/a\\evil/b", "https://github.com/-owner/b",
            "https://github.com/a//b", "https://github.com/a/.git",
            "https://[malformed/a/b",
        ]
        for url in invalid:
            with self.subTest(url=url), self.assertRaises(watcher.WatcherError):
                watcher.repository_url(url)
        for owner, repo in [("../a", "b"), ("a", ".."), ("a", "$(id)"), ("a", "b/c"), ("a--b", "repo")]:
            with self.subTest(owner=owner, repo=repo), self.assertRaises(watcher.WatcherError):
                watcher.validate_identity(owner, repo)

    def test_annotation_escaping(self):
        with contextlib.redirect_stderr(io.StringIO()) as output:
            watcher.annotation("warning", "bad%value\r\n::error::injected")
        self.assertEqual(output.getvalue(), "::warning::bad%25value%0D%0A::error::injected\n")


class DiscoveryTests(unittest.TestCase):
    def test_baseline_and_exact_title_and_pr_filters(self):
        github = github_issues(
            issue(5, "closed", START), issue(2, "closed"),
            issue(1), issue(6, "closed", "2026-09-02T00:00:00Z"),
            issue(7, title=" [Sandbox] Wrong"), issue(8, title="[sandbox] Wrong"),
            issue(9, pull_request={}),
        )
        result = watcher.discover(github, store())
        self.assertEqual([item["issue"] for item in result["include"]], [1, 5, 6])

    def test_bootstrap_is_uploaded_before_fetching_issues(self):
        events = []
        storage = store(set())
        storage.write_started.side_effect = lambda value: events.append(("put", value))
        github = Mock()
        github.issues.side_effect = lambda: events.append(("issues",)) or iter([issue()])
        result = watcher.discover(github, storage, NOW)
        self.assertEqual(events, [("put", START + "\n"), ("issues",)])
        self.assertEqual(len(result["include"]), 1)
        storage.read_started.assert_not_called()

    def test_existing_marker_never_rewritten(self):
        storage = store()
        watcher.discover(github_issues(), storage)
        storage.read_started.assert_called_once()
        storage.write_started.assert_not_called()

    def test_objects_without_bootstrap_fail(self):
        storage = store({watcher.PREFIX + "1/a/b.spdx.json"})
        with self.assertRaisesRegex(watcher.WatcherError, "restore"):
            watcher.discover(github_issues(), storage, NOW)
        storage.write_started.assert_not_called()

    def test_list_get_and_put_failure_propagate(self):
        for operation in ("keys", "read_started", "write_started"):
            storage = store(set() if operation == "write_started" else None)
            getattr(storage, operation).side_effect = watcher.WatcherError("denied")
            github = github_issues()
            with self.subTest(operation=operation), self.assertRaisesRegex(watcher.WatcherError, "denied"):
                watcher.discover(github, storage, NOW)
            github.issues.assert_not_called()

    def test_invalid_bootstrap_is_not_reset(self):
        for timestamp in ("garbage", "2026-09-01", "2026-09-01T00:00:00", "2026-09-01T00:00:00+01:00", ""):
            storage = store()
            storage.read_started.return_value = timestamp
            with self.subTest(timestamp=timestamp), self.assertRaises(watcher.WatcherError):
                watcher.discover(github_issues(), storage)
            storage.write_started.assert_not_called()

    def test_complete_key_dedup_is_per_issue_not_revision(self):
        storage = store({watcher.STARTED_KEY, watcher.PREFIX + "1/owner/repo.spdx.json"})
        github = github_issues(issue(1), issue(2), issue(2))
        result = watcher.discover(github, storage)
        self.assertEqual(result, {"include": [{
            "issue": 2, "owner": "Owner", "repo": "Repo",
            "key": watcher.PREFIX + "2/owner/repo.spdx.json",
        }]})
        github.get.assert_not_called()

    def test_limit_defers_oldest_first_and_next_poll_can_drain(self):
        issues = [issue(number) for number in range(260, 0, -1)]
        with contextlib.redirect_stderr(io.StringIO()) as output:
            result = watcher.discover(github_issues(*issues), store())
        self.assertEqual([item["issue"] for item in result["include"]], list(range(1, 257)))
        self.assertIn("Deferring 4", output.getvalue())
        keys = {watcher.STARTED_KEY} | {item["key"] for item in result["include"]}
        remaining = watcher.discover(github_issues(*issues), store(keys))
        self.assertEqual([item["issue"] for item in remaining["include"]], [257, 258, 259, 260])


class ObjectStoreTests(unittest.TestCase):
    def setUp(self):
        self.storage = watcher.ObjectStore("https://s3.example.test", "test-region", "test-bucket")

    @patch.object(watcher.subprocess, "run")
    def test_list_uses_automatic_pagination_and_complete_keys(self, run):
        keys = [watcher.STARTED_KEY] + [f"{watcher.PREFIX}{number}/a/b.spdx.json" for number in range(1100)]
        run.return_value.stdout = json.dumps({"Contents": [{"Key": key} for key in keys]})
        self.assertEqual(self.storage.keys(), set(keys))
        argv = run.call_args.args[0]
        self.assertIsInstance(argv, list)
        self.assertNotIn("--no-paginate", argv)
        self.assertNotIn("--max-items", argv)
        self.assertEqual(argv[argv.index("--prefix") + 1], watcher.PREFIX)
        self.assertEqual(argv[argv.index("--output") + 1], "json")
        self.assertEqual(run.call_args.kwargs["env"]["AWS_PAGER"], "")
        self.assertNotIn("shell", run.call_args.kwargs)

    @patch.object(watcher.subprocess, "run")
    def test_marker_transfers_use_local_files_and_metadata_stdout(self, run):
        paths = []
        def fake_run(argv, **kwargs):
            operation = argv[2]
            if operation == "put-object":
                path = Path(argv[argv.index("--body") + 1])
                self.assertEqual(path.read_text(), START + "\n")
                self.assertEqual(argv[argv.index("--content-type") + 1], "text/plain")
            else:
                self.assertEqual(operation, "get-object")
                path = Path(argv[-1])
                path.write_text(START + "\n")
            self.assertEqual(path.parent.resolve(), Path.cwd())
            paths.append(path)
            return Mock(stdout='{"ContentLength": 21}')
        run.side_effect = fake_run
        self.storage.write_started(START + "\n")
        self.assertEqual(self.storage.read_started(), START + "\n")
        self.assertTrue(all(not path.exists() for path in paths))

    @patch.object(watcher.subprocess, "run")
    def test_command_failures_are_never_missing_objects(self, run):
        for operation in ("list-objects-v2", "get-object", "put-object"):
            run.side_effect = subprocess.CalledProcessError(
                254, ["aws"], stderr="AccessDenied: 403 forbidden", output="request-id: 123"
            )
            with self.subTest(operation=operation), self.assertRaises(watcher.WatcherError) as raised:
                self.storage.run(operation)
            self.assertIn(operation, str(raised.exception))
            self.assertIn("permissions", str(raised.exception))
            self.assertIn("AWS CLI exit 254", str(raised.exception))
            self.assertIn("stderr: AccessDenied: 403 forbidden", str(raised.exception))
            self.assertIn("stdout: request-id: 123", str(raised.exception))
            self.assertNotIn("--debug", run.call_args.args[0])

    @patch.object(watcher.subprocess, "run")
    def test_diagnostics_redact_configured_tokens(self, run):
        run.side_effect = subprocess.CalledProcessError(
            1, ["aws"], stderr="failure github-secret", output="aws-secret"
        )
        with patch.dict(watcher.os.environ, {"GH_TOKEN": "github-secret", "AWS_SECRET_ACCESS_KEY": "aws-secret"}):
            with self.assertRaises(watcher.WatcherError) as raised:
                self.storage.run("put-object")
        self.assertIn("[REDACTED]", str(raised.exception))
        self.assertNotIn("github-secret", str(raised.exception))
        self.assertNotIn("aws-secret", str(raised.exception))

    @patch.object(watcher.subprocess, "run")
    def test_executable_failures_are_distinct(self, run):
        run.side_effect = FileNotFoundError(2, "No such file or directory", "aws")
        with self.assertRaises(watcher.WatcherError) as raised:
            self.storage.keys()
        self.assertIn("Cannot execute AWS CLI", str(raised.exception))
        self.assertIn("No such file or directory", str(raised.exception))
        self.assertIn("installed and executable", str(raised.exception))
        self.assertNotIn("AWS CLI exit", str(raised.exception))

    def test_endpoint_scheme_normalization(self):
        for endpoint, expected in (
            ("s3.example.test", "https://s3.example.test"),
            ("https://s3.example.test", "https://s3.example.test"),
            ("http://localhost:9000", "http://localhost:9000"),
        ):
            with self.subTest(endpoint=endpoint):
                self.assertEqual(watcher.ObjectStore(endpoint, "region", "bucket").endpoint, expected)

    @patch.object(watcher.subprocess, "run")
    def test_invalid_list_responses_fail(self, run):
        for response in ("not json", "[]", '{"Contents": null}', '{"Contents": [{}]}'):
            run.return_value.stdout = response
            with self.subTest(response=response), self.assertRaises(watcher.WatcherError):
                self.storage.keys()


class GitHubTests(unittest.TestCase):
    def test_paginated_all_issues_without_search_limit(self):
        github = watcher.GitHub("secret")
        github.get = Mock(side_effect=[[issue()] * 100 for _ in range(11)] + [[issue(99)]])
        self.assertEqual(len(list(github.issues())), 1101)
        self.assertEqual(github.get.call_count, 12)
        self.assertIn("state=all&per_page=100&page=12", github.get.call_args.args[0])

    def test_exact_page_boundary_fetches_empty_final_page(self):
        github = watcher.GitHub("secret")
        github.get = Mock(side_effect=[[issue()] * 100, []])
        self.assertEqual(len(list(github.issues())), 100)
        self.assertEqual(github.get.call_count, 2)

    def test_http_errors_context_without_secret(self):
        github = watcher.GitHub("SECRET")
        github.opener = Mock()
        for status in (401, 403, 404, 429, 500):
            github.opener.open.side_effect = error.HTTPError("https://api.github.com/repos/a/b", status, "SECRET", {}, None)
            with self.subTest(status=status), self.assertRaises(watcher.APIError) as raised:
                github.get("/repos/a/b")
            self.assertEqual(raised.exception.status, status)
            self.assertIn("/repos/a/b", str(raised.exception))
            self.assertNotIn("SECRET", str(raised.exception))
        req = github.opener.open.call_args.args[0]
        self.assertEqual(req.full_url, "https://api.github.com/repos/a/b")
        self.assertEqual(req.get_header("Authorization"), "Bearer SECRET")

    def test_redirects_only_allow_the_https_api_origin(self):
        handler = watcher.GitHubRedirect()
        original = watcher.request.Request(
            "https://api.github.com/repos/old/repo", headers={"Authorization": "Bearer SECRET"}
        )
        for target in (
            "https://evil.test", "http://api.github.com/repositories/1",
            "https://api.github.com.evil.test/repositories/1",
            "https://user:password@api.github.com/repositories/1",
            "https://api.github.com:444/repositories/1", "https://[invalid",
            "https://api.github.com/\r\ninjected",
        ):
            with self.subTest(target=target):
                self.assertIsNone(handler.redirect_request(original, None, 301, "", {}, target))
        for target in ("https://api.github.com/repositories/1", "https://api.github.com:443/repositories/1"):
            with self.subTest(target=target):
                redirected = handler.redirect_request(original, None, 301, "", {}, target)
                self.assertEqual(redirected.full_url, target)
                self.assertEqual(redirected.get_header("Authorization"), "Bearer SECRET")

    def test_transferred_repository_redirect_and_foreign_rejection_without_network(self):
        for target in ("https://api.github.com/repositories/123", "https://evil.test/repositories/123", "http://api.github.com/repositories/123"):
            calls = []
            class FakeHTTPS(watcher.request.HTTPSHandler, watcher.request.HTTPHandler):
                def https_open(self, req):
                    calls.append(req)
                    headers = Message()
                    status, body = 200, b'{"default_branch":"main"}'
                    if len(calls) == 1:
                        headers["Location"] = target
                        status, body = 301, b""
                    response = addinfourl(io.BytesIO(body), headers, req.full_url, status)
                    response.msg = "Moved" if status == 301 else "OK"
                    return response
                http_open = https_open
            github = watcher.GitHub("SECRET")
            github.opener = watcher.request.build_opener(FakeHTTPS(), watcher.GitHubRedirect())
            with self.subTest(target=target):
                if target.startswith("https://api.github.com/"):
                    self.assertEqual(github.get("/repos/old/repo"), {"default_branch": "main"})
                    self.assertEqual(len(calls), 2)
                    self.assertEqual(calls[1].full_url, target)
                    self.assertEqual(calls[1].get_header("Authorization"), "Bearer SECRET")
                else:
                    with self.assertRaises(watcher.APIError):
                        github.get("/repos/old/repo")
                    self.assertEqual(len(calls), 1)

    def test_network_and_invalid_json_errors_are_explicit(self):
        github = watcher.GitHub("SECRET")
        github.opener = Mock()
        github.opener.open.side_effect = error.URLError("SECRET")
        with self.assertRaises(watcher.WatcherError) as raised:
            github.get("/repos/a/b")
        self.assertNotIn("SECRET", str(raised.exception))
        github.opener.open.side_effect = None
        github.opener.open.return_value.__enter__ = Mock(return_value=io.StringIO("not json"))
        github.opener.open.return_value.__exit__ = Mock(return_value=False)
        with self.assertRaisesRegex(watcher.WatcherError, "invalid JSON"):
            github.get("/repos/a/b")

    def test_absolute_or_foreign_paths_rejected(self):
        github = watcher.GitHub("SECRET")
        github.opener = Mock()
        for path in ("https://evil.test", "//evil.test"):
            with self.subTest(path=path), self.assertRaises(watcher.WatcherError):
                github.get(path)
        github.opener.open.assert_not_called()


class ResolveTests(unittest.TestCase):
    def test_release_resolves_tag_to_immutable_commit(self):
        github = Mock()
        github.get.side_effect = [
            {"default_branch": "main"},
            {"tag_name": "release/v1", "draft": False, "prerelease": False},
            {"sha": SHA},
        ]
        self.assertEqual(watcher.resolve(github, "Owner", "Repo"), {
            "owner": "Owner", "repo": "Repo", "repository": "Owner/Repo",
            "ref": "release/v1", "version": "release/v1", "commit": SHA, "source": "release",
        })
        self.assertEqual([call.args[0] for call in github.get.call_args_list], [
            "/repos/Owner/Repo", "/repos/Owner/Repo/releases/latest",
            "/repos/Owner/Repo/commits/release%2Fv1",
        ])

    def test_only_latest_404_falls_back_to_default_branch(self):
        github = Mock()
        github.get.side_effect = [
            {"default_branch": "custom/main"}, watcher.APIError("/releases/latest", 404), {"sha": SHA},
        ]
        result = watcher.resolve(github, "a", "b")
        self.assertEqual(result["source"], "default-branch")
        self.assertEqual(result["ref"], "custom/main")
        self.assertEqual(result["version"], SHA)
        self.assertEqual(github.get.call_args.args[0], "/repos/a/b/commits/custom%2Fmain")

    def test_non404_release_failures_do_not_fallback(self):
        for status in (401, 403, 429, 500):
            github = Mock()
            github.get.side_effect = [{"default_branch": "main"}, watcher.APIError("/releases/latest", status)]
            with self.subTest(status=status), self.assertRaises(watcher.APIError):
                watcher.resolve(github, "a", "b")
            self.assertEqual(github.get.call_count, 2)

    def test_repository_404_is_not_release_absence(self):
        github = Mock()
        github.get.side_effect = watcher.APIError("/repos/a/b", 404)
        with self.assertRaises(watcher.APIError):
            watcher.resolve(github, "a", "b")
        self.assertEqual(github.get.call_count, 1)

    def test_missing_default_branch_and_invalid_releases_fail(self):
        for repository in ({}, None, {"default_branch": ""}):
            github = Mock()
            github.get.return_value = repository
            with self.subTest(repository=repository), self.assertRaises(watcher.WatcherError):
                watcher.resolve(github, "a", "b")
        for release in (
            {}, None, {"tag_name": "v1", "draft": True, "prerelease": False},
            {"tag_name": "v1", "draft": False, "prerelease": True},
            {"tag_name": "", "draft": False, "prerelease": False},
        ):
            github = Mock()
            github.get.side_effect = [{"default_branch": "main"}, release]
            with self.subTest(release=release), self.assertRaises(watcher.WatcherError):
                watcher.resolve(github, "a", "b")
            self.assertEqual(github.get.call_count, 2)

    def test_invalid_sha_and_invalid_identities_fail(self):
        for sha in (None, "", "abc", "A" * 40, "g" * 40):
            github = Mock()
            github.get.side_effect = [{"default_branch": "main"}, watcher.APIError("/releases/latest", 404), {"sha": sha}]
            with self.subTest(sha=sha), self.assertRaises(watcher.WatcherError):
                watcher.resolve(github, "a", "b")
        github = Mock()
        with self.assertRaises(watcher.WatcherError):
            watcher.resolve(github, "../evil", "repo")
        github.get.assert_not_called()


class CLITests(unittest.TestCase):
    @patch.object(watcher.Path, "write_text")
    @patch.object(watcher, "discover")
    @patch.object(watcher, "ObjectStore")
    @patch.object(watcher, "GitHub")
    def test_local_io_failures_do_not_always_claim_output_write_failure(self, github, storage, discover, write):
        with patch.object(watcher.sys, "argv", ["sandbox-applications.py", "discover", "--output", "matrix.json"]):
            for failure_site in (discover, write):
                discover.side_effect = None
                discover.return_value = {"include": []}
                write.side_effect = None
                failure_site.side_effect = PermissionError(13, "Permission denied", "local-file")
                with self.subTest(site=failure_site), contextlib.redirect_stderr(io.StringIO()) as output:
                    self.assertEqual(watcher.main(), 1)
                self.assertIn("Local filesystem operation failed: Permission denied", output.getvalue())
                self.assertNotIn("Cannot write output file", output.getvalue())

    @patch.object(watcher.Path, "write_text")
    @patch.object(watcher, "resolve")
    @patch.object(watcher, "GitHub")
    def test_resolve_writes_json_only_to_requested_file(self, github, resolve, write):
        resolve.return_value = {"commit": SHA}
        with patch.dict(watcher.os.environ, {"GH_TOKEN": "secret"}), patch.object(
            watcher.sys, "argv",
            ["sandbox-applications.py", "resolve", "--owner", "Owner", "--repo", "Repo", "--output", "revision.json"],
        ):
            self.assertEqual(watcher.main(), 0)
        github.assert_called_once_with("secret")
        resolve.assert_called_once_with(github.return_value, "Owner", "Repo")
        self.assertEqual(json.loads(write.call_args.args[0]), {"commit": SHA})

    @patch.object(watcher.Path, "write_text")
    @patch.object(watcher, "discover")
    @patch.object(watcher, "ObjectStore")
    @patch.object(watcher, "GitHub")
    def test_discovery_contract_and_failure_exit(self, github, storage, discover, write):
        env = {"GH_TOKEN": "secret", "S3_ENDPOINT": "https://example.test", "S3_REGION": "region", "PROJECT_BUCKET": "bucket"}
        discover.return_value = {"include": []}
        with patch.dict(watcher.os.environ, env), patch.object(
            watcher.sys, "argv", ["sandbox-applications.py", "discover", "--output", "matrix.json"]
        ):
            self.assertEqual(watcher.main(), 0)
            storage.assert_called_once_with("https://example.test", "region", "bucket")
            discover.assert_called_once_with(github.return_value, storage.return_value)
            self.assertEqual(json.loads(write.call_args.args[0]), {"include": []})
            write.reset_mock()
            discover.side_effect = watcher.WatcherError("list denied")
            with contextlib.redirect_stderr(io.StringIO()) as output:
                self.assertEqual(watcher.main(), 1)
            write.assert_not_called()
            self.assertIn("::error::list denied", output.getvalue())


if __name__ == "__main__":
    unittest.main()
