"""Fleet-edge Traefik live e2e (specs/dynamic-traefik.md).

`traefik_cli.py sync` hot-pushes every cluster's `reverse_proxy_routes` into the services VM's
watched dynamic dir; this asserts the resulting router actually reaches its backend through the
edge. Runs entirely on the services VM (curl to 127.0.0.1 with --resolve) so it needs no host-side
DNS wiring. Auto-skips if the route hasn't been synced yet (`just traefik-sync`), so a plain
`just verify centralized_pki` on an isolated cluster stays green.
"""

import pytest

TRAEFIK_API = "http://127.0.0.1:8080/api/http/routers"


def test_netbox_route_reaches_backend_when_synced(services, domain):
    routers = services.run(f"curl -sf {TRAEFIK_API}")
    if routers.rc != 0 or "fleet-netbox@file" not in routers.stdout:
        pytest.skip("fleet-netbox route not synced onto this VM yet (run `just traefik-sync`)")

    probe = services.run(
        f"curl -sk -o /dev/null -w '%{{http_code}}' "
        f"--resolve netbox.{domain}:443:127.0.0.1 https://netbox.{domain}/"
    )
    status = probe.stdout.strip()
    assert status and status[0] in "23", f"expected a 2xx/3xx reaching netbox through the edge, got {status!r}"
