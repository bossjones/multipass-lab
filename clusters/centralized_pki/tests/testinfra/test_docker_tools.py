"""Live checks for the docker operator TUIs (wharf, oxker, dive) on the docker VMs.

Both the ca and services VMs run docker. Gated on the enable_docker_tools flag (surfaced via
the docker_tools_enabled output), so the suite is skipped — not failed — when the tools are off.
"""

import pytest

TOOLS = ("wharf", "oxker", "dive")
ROLES = ("ca", "services")


@pytest.mark.parametrize("role", ROLES)
@pytest.mark.parametrize("tool", TOOLS)
def test_docker_tool_on_path(request, docker_tools_enabled, role, tool):
    if not docker_tools_enabled:
        pytest.skip("enable_docker_tools disabled")
    host = request.getfixturevalue(role)
    # dive installs to /usr/bin via its .deb; wharf/oxker to /usr/local/bin — resolve via PATH.
    assert host.run(f"command -v {tool}").rc == 0, (
        f"{tool} not installed on the {role} VM"
    )


@pytest.mark.parametrize("role", ROLES)
def test_ubuntu_in_docker_group(request, docker_tools_enabled, role):
    if not docker_tools_enabled:
        pytest.skip("enable_docker_tools disabled")
    host = request.getfixturevalue(role)
    assert "docker" in host.run("id -nG ubuntu").stdout.split(), (
        f"ubuntu should be in the docker group on the {role} VM"
    )
