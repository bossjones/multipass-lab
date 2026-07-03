"""DNS resolution layer: AdGuard Home (:53) forwards to Unbound (127.0.0.1:5335), and a
blocklisted domain is blocked."""

import time


def _wait_listening(host, port, timeout=240):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if host.socket(f"tcp://0.0.0.0:{port}").is_listening:
            return True
        time.sleep(5)
    return False


def test_adguard_listens_on_53(server):
    assert _wait_listening(server, 53), "AdGuard Home is not listening on :53"


def test_unbound_resolves_recursively(server):
    # Unbound answers directly on its localhost port.
    res = server.run("dig @127.0.0.1 -p 5335 example.com +short +time=3 +tries=1")
    assert res.rc == 0 and res.stdout.strip(), "Unbound did not resolve example.com"


def test_adguard_resolves_via_unbound(server):
    # AdGuard (:53) -> Unbound path resolves a normal domain.
    res = server.run("dig @127.0.0.1 example.com +short +time=3 +tries=1")
    assert res.rc == 0 and res.stdout.strip(), "AdGuard did not resolve example.com"


def test_adguard_blocks_a_known_ad_domain(server):
    # A domain on the default blocklists is answered as blocked (0.0.0.0 / NXDOMAIN / empty).
    res = server.run("dig @127.0.0.1 doubleclick.net +short +time=3 +tries=1")
    answer = res.stdout.strip()
    assert res.rc == 0, "query itself failed"
    assert answer in ("", "0.0.0.0", "::"), f"expected a blocked answer, got: {answer!r}"
