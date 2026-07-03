"""Live checks for the docker operator TUIs (wharf, oxker, dive) on the server VM.

Gated on the enable_docker_tools flag (surfaced via the docker_tools_enabled output), so the
suite is skipped — not failed — when the tools are turned off.
"""

import pytest

TOOLS = ("wharf", "oxker", "dive")


@pytest.mark.parametrize("tool", TOOLS)
def test_docker_tool_on_path(server, docker_tools_enabled, tool):
    if not docker_tools_enabled:
        pytest.skip("enable_docker_tools disabled")
    # dive installs to /usr/bin via its .deb; wharf/oxker to /usr/local/bin — resolve via PATH.
    assert server.run(f"command -v {tool}").rc == 0, (
        f"{tool} not installed on the server VM"
    )


def test_ubuntu_in_docker_group(server, docker_tools_enabled):
    if not docker_tools_enabled:
        pytest.skip("enable_docker_tools disabled")
    assert "docker" in server.run("id -nG ubuntu").stdout.split(), (
        "ubuntu should be in the docker group so the TUIs reach the socket without sudo"
    )
