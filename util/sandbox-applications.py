#!/usr/bin/env python3
"""Discover sandbox applications and resolve immutable GitHub revisions."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib import error, parse, request


API_ROOT = "https://api.github.com"
PREFIX = "sandbox-applications/"
STARTED_KEY = PREFIX + ".started-at"
FIELD = "Project repo URL in scope of application"
MATRIX_LIMIT = 256


class WatcherError(Exception):
    pass


class APIError(WatcherError):
    def __init__(self, path, status):
        self.status = status
        super().__init__(f"GitHub GET {path} failed (HTTP {status}); check access and API limits")


def annotation(level, message):
    escaped = str(message).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::{level}::{escaped}", file=sys.stderr)


class GitHubRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        try:
            destination = parse.urlsplit(newurl)
        except ValueError:
            return None
        if (
            destination.scheme != "https"
            or destination.netloc.lower() not in {"api.github.com", "api.github.com:443"}
            or any(ord(character) < 32 or ord(character) == 127 for character in newurl)
        ):
            return None
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class GitHub:
    def __init__(self, token):
        if not token:
            raise WatcherError("GH_TOKEN must be configured")
        self.token = token
        self.opener = request.build_opener(GitHubRedirect())

    def get(self, path):
        if not path.startswith("/") or path.startswith("//"):
            raise WatcherError("GitHub API path must be relative to the fixed API host")
        req = request.Request(
            API_ROOT + path,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "sandbox-application-sbom-watcher",
            },
        )
        try:
            with self.opener.open(req, timeout=60) as response:
                return json.load(response)
        except error.HTTPError as exc:
            exc.close()
            raise APIError(path, exc.code) from None
        except (error.URLError, OSError, ValueError):
            raise WatcherError(f"GitHub GET {path} failed: network error or invalid JSON") from None

    def issues(self):
        page = 1
        while True:
            items = self.get(
                "/repos/cncf/sandbox/issues?"
                + parse.urlencode({"state": "all", "per_page": 100, "page": page})
            )
            if not isinstance(items, list) or any(not isinstance(item, dict) for item in items):
                raise WatcherError("GitHub issues response must be an array of issue objects")
            yield from items
            if len(items) < 100:
                return
            page += 1


def validate_identity(owner, repo):
    if not isinstance(owner, str) or not re.fullmatch(
        r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?", owner
    ) or "--" in owner:
        raise WatcherError("Invalid GitHub repository owner")
    if not isinstance(repo, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", repo) or repo in {".", ".."}:
        raise WatcherError("Invalid GitHub repository name")
    return owner, repo


def repository_url(url):
    try:
        parsed = parse.urlsplit(url)
    except ValueError:
        raise WatcherError("Malformed repository URL") from None
    if parsed.scheme != "https" or parsed.netloc.lower() != "github.com" or parsed.query or parsed.fragment:
        raise WatcherError("Repository URL must use https://github.com without credentials, query, or fragment")
    parts = parsed.path.rstrip("/").split("/")
    if len(parts) != 3 or parts[0] != "":
        raise WatcherError("Repository URL must contain exactly an owner and repository")
    owner, repo = parts[1:]
    if repo.endswith(".git"):
        repo = repo[:-4]
    return validate_identity(owner, repo)


def application_repositories(body, issue_number):
    if not isinstance(body, str):
        annotation("warning", f"Issue #{issue_number}: missing {FIELD} field")
        return []
    lines = body.splitlines()
    fields = []
    for index, line in enumerate(lines):
        label = re.sub(r"^\s{0,3}#{1,6}\s+", "", line).strip()
        label = re.sub(r"\s+#+$", "", label).strip().strip("*").rstrip(":").strip().strip("*")
        if label != FIELD:
            continue
        content = []
        heading = bool(re.match(r"^\s{0,3}#{1,6}\s+", line))
        for following in lines[index + 1:]:
            if re.match(r"^\s{0,3}#{1,6}\s+", following):
                break
            # Plain labels have no heading delimiter; another text label ends the field.
            if not heading and following.strip() and not re.search(r"://|www\.", following):
                break
            content.append(following)
        fields.append("\n".join(content))
    if not fields:
        annotation("warning", f"Issue #{issue_number}: missing {FIELD} field")
        return []

    result, seen = [], set()
    for field in fields:
        urls = re.findall(r"(?:[A-Za-z][A-Za-z0-9+.-]*://|www\.)[^\s<>\"`]+", field)
        if not urls:
            annotation("warning", f"Issue #{issue_number}: {FIELD} contains no repository URL")
        for raw_url in urls:
            url = raw_url.rstrip(")]},")
            try:
                owner, repo = repository_url(url)
            except WatcherError as exc:
                annotation("warning", f"Issue #{issue_number}: invalid application repository URL: {exc}")
                continue
            identity = (owner.lower(), repo.lower())
            if identity not in seen:
                seen.add(identity)
                result.append((owner, repo))
    return result


def utc_timestamp(value, context):
    if not isinstance(value, str):
        raise WatcherError(f"{context} must be an ISO UTC timestamp")
    try:
        timestamp = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        raise WatcherError(f"{context} must be an ISO UTC timestamp") from None
    if timestamp.tzinfo is None or timestamp.utcoffset().total_seconds() != 0:
        raise WatcherError(f"{context} must be an ISO UTC timestamp")
    return timestamp


class ObjectStore:
    def __init__(self, endpoint, region, bucket):
        if not all((endpoint, region, bucket)):
            raise WatcherError("S3_ENDPOINT, S3_REGION, and SANDBOX_BUCKET must be configured")
        self.endpoint = endpoint if endpoint.startswith(("http://", "https://")) else "https://" + endpoint
        self.region, self.bucket = region, bucket

    def run(self, operation, *args):
        command = [
            "aws", "s3api", operation, "--endpoint-url", self.endpoint,
            "--region", self.region, "--bucket", self.bucket, "--output", "json", *args,
        ]
        try:
            result = subprocess.run(
                command, check=True, capture_output=True, text=True,
                env={**os.environ, "AWS_PAGER": ""},
            )
        except subprocess.CalledProcessError as exc:
            diagnostics = "\n".join(
                f"{label}: {value.strip()}"
                for label, value in (("stderr", exc.stderr), ("stdout", exc.stdout))
                if value and value.strip()
            )
            for name in ("GH_TOKEN", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"):
                secret = os.environ.get(name)
                if secret:
                    diagnostics = diagnostics.replace(secret, "[REDACTED]")
            raise WatcherError(
                f"S3 {operation} failed (AWS CLI exit {exc.returncode}); "
                "check endpoint, credentials, and bucket permissions"
                + (f"\n{diagnostics}" if diagnostics else "\nAWS CLI returned no diagnostic output")
            ) from None
        except OSError as exc:
            raise WatcherError(
                f"Cannot execute AWS CLI for S3 {operation}: {exc.strerror or type(exc).__name__}; "
                "ensure aws is installed and executable"
            ) from None
        try:
            value = json.loads(result.stdout)
        except (ValueError, TypeError):
            raise WatcherError(f"S3 {operation} returned invalid JSON") from None
        if not isinstance(value, dict):
            raise WatcherError(f"S3 {operation} returned invalid metadata")
        return value

    def keys(self):
        result = self.run("list-objects-v2", "--prefix", PREFIX)
        objects = result.get("Contents", [])
        if not isinstance(objects, list) or any(
            not isinstance(item, dict) or not isinstance(item.get("Key"), str) for item in objects
        ):
            raise WatcherError("S3 list-objects-v2 returned invalid object keys")
        return {item["Key"] for item in objects}

    def read_started(self):
        with tempfile.NamedTemporaryFile(prefix=".sandbox-applications-", dir=".") as local:
            self.run("get-object", "--key", STARTED_KEY, local.name)
            try:
                return Path(local.name).read_text(encoding="utf-8")
            except (OSError, UnicodeError):
                raise WatcherError("Cannot read downloaded sandbox bootstrap timestamp") from None

    def write_started(self, timestamp):
        with tempfile.NamedTemporaryFile(mode="w+", prefix=".sandbox-applications-", dir=".") as local:
            local.write(timestamp)
            local.flush()
            self.run(
                "put-object", "--key", STARTED_KEY, "--body", local.name,
                "--content-type", "text/plain",
            )


def discover(github, store, now=None):
    keys = store.keys()
    if STARTED_KEY in keys:
        started = utc_timestamp(store.read_started(), "Sandbox bootstrap timestamp")
    else:
        if any(key.startswith(PREFIX) and key.endswith(".spdx.json") for key in keys):
            raise WatcherError("Sandbox SBOM objects exist but .started-at is missing; restore the bootstrap marker")
        started = now if now is not None else datetime.now(timezone.utc)
        started = utc_timestamp(started.isoformat(), "Current time")
        store.write_started(started.isoformat().replace("+00:00", "Z") + "\n")

    issues = []
    for issue in github.issues():
        if "pull_request" in issue or not isinstance(issue.get("title"), str) or not issue["title"].startswith("[Sandbox]"):
            continue
        if type(issue.get("number")) is not int or issue["number"] <= 0:
            raise WatcherError("GitHub application issue is missing a valid issue number")
        created = utc_timestamp(issue.get("created_at"), f"Issue #{issue['number']} creation time")
        if issue.get("state") not in {"open", "closed"}:
            raise WatcherError(f"Issue #{issue['number']} has an invalid state")
        if issue["state"] == "open" or created >= started:
            issues.append((created, issue["number"], issue))

    candidates, seen = [], set()
    for _, number, issue in sorted(issues, key=lambda item: item[:2]):
        for owner, repo in application_repositories(issue.get("body"), number):
            key = f"{PREFIX}{number}/{owner.lower()}/{repo.lower()}.spdx.json"
            if key not in keys and key not in seen:
                seen.add(key)
                candidates.append({"issue": number, "owner": owner, "repo": repo, "key": key})
    if len(candidates) > MATRIX_LIMIT:
        annotation("notice", f"Deferring {len(candidates) - MATRIX_LIMIT} application repositories to the next poll (matrix limit {MATRIX_LIMIT})")
    return {"include": candidates[:MATRIX_LIMIT]}


def resolve(github, owner, repo):
    owner, repo = validate_identity(owner, repo)
    base = f"/repos/{owner}/{repo}"
    repository = github.get(base)
    if not isinstance(repository, dict) or not isinstance(repository.get("default_branch"), str) or not repository["default_branch"].strip():
        raise WatcherError(f"GitHub repository {owner}/{repo} is missing its default branch")
    try:
        release = github.get(base + "/releases/latest")
    except APIError as exc:
        if exc.status != 404:
            raise
        ref, source = repository["default_branch"], "default-branch"
    else:
        if (
            not isinstance(release, dict)
            or release.get("draft") is not False
            or release.get("prerelease") is not False
            or not isinstance(release.get("tag_name"), str)
            or not release["tag_name"].strip()
        ):
            raise WatcherError(f"GitHub latest release for {owner}/{repo} is not a valid stable release")
        ref, source = release["tag_name"], "release"
    commit = github.get(base + "/commits/" + parse.quote(ref, safe=""))
    if not isinstance(commit, dict) or not isinstance(commit.get("sha"), str) or not re.fullmatch(r"[0-9a-f]{40}", commit["sha"]):
        raise WatcherError(f"GitHub commit for {owner}/{repo} is missing a valid 40-character lowercase SHA")
    return {
        "owner": owner, "repo": repo, "repository": f"{owner}/{repo}", "ref": ref,
        "version": ref if source == "release" else commit["sha"],
        "commit": commit["sha"], "source": source,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    discovery = commands.add_parser("discover")
    discovery.add_argument("--output", required=True)
    revision = commands.add_parser("resolve")
    revision.add_argument("--owner", required=True)
    revision.add_argument("--repo", required=True)
    revision.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        github = GitHub(os.environ.get("GH_TOKEN"))
        if args.command == "discover":
            store = ObjectStore(
                os.environ.get("S3_ENDPOINT"), os.environ.get("S3_REGION"),
                os.environ.get("SANDBOX_BUCKET"),
            )
            result = discover(github, store)
        else:
            result = resolve(github, args.owner, args.repo)
        Path(args.output).write_text(json.dumps(result) + "\n", encoding="utf-8")
    except WatcherError as exc:
        annotation("error", exc)
        return 1
    except OSError as exc:
        annotation("error", f"Local filesystem operation failed: {exc.strerror or type(exc).__name__}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
