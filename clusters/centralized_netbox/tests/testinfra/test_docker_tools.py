"""Live checks for the docker operator TUIs (wharf, oxker, dive) on the docker VMs.

The server always runs docker; the discovery agent runs docker only when enable_discovery (its
fixture skips otherwise). The client VM has no docker and is not checked here. Gated on the
enable_docker_tools flag (docker_tools_enabled output) — skipped, not failed, when off.
"""

import pytest

TOOLS = ("wharf", "oxker", "dive")


@pytest.mark.parametrize("tool", TOOLS)
def test_server_docker_tool_on_path(server, docker_tools_enabled, tool):
    if not docker_tools_enabled:
        pytest.skip("enable_docker_tools disabled")
    # dive installs to /usr/bin via its .deb; wharf/oxker to /usr/local/bin — resolve via PATH.
    assert server.run(f"command -v {tool}").rc == 0, (
        f"{tool} not installed on the server VM"
    )


def test_server_ubuntu_in_docker_group(server, docker_tools_enabled):
    if not docker_tools_enabled:
        pytest.skip("enable_docker_tools disabled")
    assert "docker" in server.run("id -nG ubuntu").stdout.split(), (
        "ubuntu should be in the docker group on the server VM"
    )


@pytest.mark.parametrize("tool", TOOLS)
def test_agent_docker_tool_on_path(agent, docker_tools_enabled, tool):
    # The `agent` fixture already skips when discovery is disabled.
    if not docker_tools_enabled:
        pytest.skip("enable_docker_tools disabled")
    assert agent.run(f"command -v {tool}").rc == 0, (
        f"{tool} not installed on the agent VM"
    )
