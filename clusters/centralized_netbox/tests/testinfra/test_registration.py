"""The headline end-to-end proof: query NetBox's REST API from the host and confirm the client
VM registered *itself* — a Virtual Machine in the bootstrapped cluster, with an eth0 interface
and a primary IPv4 equal to the client's actual DHCP address.
"""

import httpx
import pytest


@pytest.fixture(scope="session")
def api(netbox):
    headers = {"Authorization": f"Token {netbox['token']}", "Accept": "application/json"}
    with httpx.Client(base_url=netbox["base_url"], headers=headers, timeout=15) as c:
        yield c


def _results(api, path, **params):
    resp = api.get(path, params=params)
    resp.raise_for_status()
    return resp.json()["results"]


def test_cluster_exists(api, netbox):
    results = _results(api, "/api/virtualization/clusters/", name=netbox["cluster"])
    assert results, f"cluster {netbox['cluster']} not found"
    assert str(results[0]["type"]["name"]) == "Multipass"


def test_client_vm_registered_active(api, netbox):
    results = _results(api, "/api/virtualization/virtual-machines/", name=netbox["vm_name"])
    assert results, f"VM {netbox['vm_name']} did not self-register"
    assert results[0]["status"]["value"] == "active"


def test_client_vm_has_eth0_interface(api, netbox):
    vms = _results(api, "/api/virtualization/virtual-machines/", name=netbox["vm_name"])
    vm_id = vms[0]["id"]
    ifaces = _results(api, "/api/virtualization/interfaces/", virtual_machine_id=vm_id)
    assert any(i["name"] == "eth0" for i in ifaces), "eth0 interface missing"


def test_client_vm_primary_ip_matches(api, netbox, hosts):
    vms = _results(api, "/api/virtualization/virtual-machines/", name=netbox["vm_name"])
    primary = vms[0]["primary_ip4"]
    assert primary is not None, "VM has no primary_ip4"
    client_ip = hosts["client"]["ipv4"]
    assert primary["address"].split("/")[0] == client_ip, (
        f"primary_ip4 {primary['address']} != client IP {client_ip}"
    )
