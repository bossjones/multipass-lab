"""Live checks for the docker operator TUIs (wharf, oxker, dive) on the docker VMs.

Both VMs run docker only in the 'exact' version_mode; docker_tools_enabled already folds that
in (enable_docker_tools && exact). The suite is skipped — not failed — when it is off.
"""

import pytest

TOOLS = ("wharf", "oxker", "dive")
ROLES = ("controller", "usg")


@pytest.mark.parametrize("role", ROLES)
@pytest.mark.parametrize("tool", TOOLS)
def test_docker_tool_on_path(request, docker_tools_enabled, role, tool):
    if not docker_tools_enabled:
        pytest.skip("docker tools disabled (flag off or modern mode)")
    host = request.getfixturevalue(role)
    # dive installs to /usr/bin via its .deb; wharf/oxker to /usr/local/bin — resolve via PATH.
    assert host.run(f"command -v {tool}").rc == 0, (
        f"{tool} not installed on the {role} VM"
    )


@pytest.mark.parametrize("role", ROLES)
def test_ubuntu_in_docker_group(request, docker_tools_enabled, role):
    if not docker_tools_enabled:
        pytest.skip("docker tools disabled (flag off or modern mode)")
    host = request.getfixturevalue(role)
    assert "docker" in host.run("id -nG ubuntu").stdout.split(), (
        f"ubuntu should be in the docker group on the {role} VM"
    )
