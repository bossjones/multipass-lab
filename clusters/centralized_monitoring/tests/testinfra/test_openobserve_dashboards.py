"""Live: the OpenObserve log dashboards are installed.

Dashboard import is *on-demand* (`just openobserve-dashboards <cluster>`), not part of
`just up`, so this test skips (rather than fails) when none are present — keeping a fresh
`just verify` green. Once imported, it asserts every expected board resolves via the
dashboards API. See specs/openobserve-dashboards.md.
"""

import json
import time

import pytest

OO = "http://localhost:5080"
AUTH = "admin@example.com:Complexpass#123"
ORG = "default"

EXPECTED_TITLES = {
    "Log Overview",
    "Error Triage",
    "Per-Host / Per-Stream",
    "Container Logs",
    "Kubernetes Pod Logs",
    "Cause & Effect",
}


def _skip_unless(enabled_exporters, flag):
    if flag not in enabled_exporters:
        pytest.skip(f"{flag} disabled")


def _get_json(host, path, timeout=60):
    url = f"{OO}{path}"
    deadline = time.time() + timeout
    while time.time() < deadline:
        res = host.run(f"curl -fsS -u '{AUTH}' '{url}'")
        if res.rc == 0 and res.stdout.strip():
            try:
                return json.loads(res.stdout)
            except json.JSONDecodeError:
                pass
        time.sleep(3)
    return None


def _extract_list(data, *keys):
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        for key in keys:
            if key in data:
                return data[key] or []
        for value in data.values():
            if isinstance(value, list):
                return value
    return []


def _title(item):
    if not isinstance(item, dict):
        return None
    if item.get("title"):
        return item["title"]
    for value in item.values():
        if isinstance(value, dict) and value.get("title"):
            return value["title"]
    return None


def _installed_titles(host):
    """Titles across the default folder + any named folders."""
    titles = set()
    folders = ["default"]
    # v0.91+: dashboard folders live under the v2 API.
    fdata = _get_json(host, f"/api/v2/{ORG}/folders/dashboards")
    for f in _extract_list(fdata, "list", "folders"):
        fid = f.get("folderId") or f.get("folder_id")
        if fid and fid != "default":
            folders.append(fid)
    for fid in dict.fromkeys(folders):
        data = _get_json(host, f"/api/{ORG}/dashboards?folder={fid}")
        for d in _extract_list(data, "dashboards", "list"):
            t = _title(d)
            if t:
                titles.add(t)
    return titles


def test_openobserve_dashboards_installed(server, enabled_exporters):
    _skip_unless(enabled_exporters, "enable_openobserve")
    installed = _installed_titles(server)
    if not installed:
        pytest.skip("no dashboards imported — run `just openobserve-dashboards`")
    missing = EXPECTED_TITLES - installed
    assert not missing, f"missing OpenObserve dashboards: {sorted(missing)}"
