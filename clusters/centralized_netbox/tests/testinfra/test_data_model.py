"""Live proof that the server bootstrap seeds a coherent, linked base data model into NetBox.

Queries the REST API from the host (token + url from `tofu output`) and asserts the organizational
hierarchy, the DCIM device library, a real host **Device** in /dcim/devices/, IPAM populated with
the live subnet, and the VM->host `device` link — i.e. every empty tab is now populated and the two
models (VM and Device) are connected. See specs/netbox-data.md.

The `server` fixture blocks on the bootstrap marker, so by the time these run the seed has
completed; `client` blocks on the self-registration marker (needed for the VM-link / IP tests).
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


# --- organization ------------------------------------------------------------


def test_site_has_region_and_group(api, netbox, server):
    site = _results(api, "/api/dcim/sites/", name=netbox["site"])[0]
    assert site["region"] is not None, "site was not nested under a region"
    assert site["group"] is not None, "site was not placed in a site group"
    assert str(site["region"]["name"]) == netbox["region"]


def test_tenant_seeded(api, server):
    assert _results(api, "/api/tenancy/tenants/"), "no tenant was seeded"


# --- DCIM library ------------------------------------------------------------


def test_device_library_seeded(api, server):
    assert _results(api, "/api/dcim/manufacturers/"), "no manufacturer seeded"
    assert _results(api, "/api/dcim/device-types/"), "no device type seeded"
    assert _results(api, "/api/dcim/device-roles/", name="Hypervisor"), "hypervisor role missing"


def test_rack_in_site(api, netbox, server):
    racks = _results(api, "/api/dcim/racks/", name=netbox["rack"])
    assert racks, f"rack {netbox['rack']} was not seeded"
    assert str(racks[0]["site"]["name"]) == netbox["site"]


# --- the headline: a real DCIM Device populates /dcim/devices/ ---------------


def test_host_device_present_and_racked(api, netbox, server):
    devices = _results(api, "/api/dcim/devices/", name=netbox["host_device"])
    assert devices, f"host device {netbox['host_device']} not in /dcim/devices/"
    dev = devices[0]
    assert dev["status"]["value"] == "active"
    assert dev["rack"] is not None, "host device is not mounted in a rack"
    assert dev["position"] is not None, "host device has no rack position"


# --- IPAM reflects the live subnet -------------------------------------------


def test_ipam_rir_aggregate_prefix(api, netbox, server):
    assert _results(api, "/api/ipam/rirs/", name="RFC1918"), "RFC1918 RIR missing"
    assert _results(api, "/api/ipam/aggregates/"), "no aggregate seeded"
    prefixes = _results(api, "/api/ipam/prefixes/", prefix=netbox["prefix"])
    assert prefixes, f"prefix {netbox['prefix']} was not seeded"


def test_client_ip_inside_seeded_prefix(api, netbox, hosts, client):
    subnet = netbox["prefix"].rsplit(".", 1)[0] + "."  # e.g. "192.168.252."
    client_ip = hosts["client"]["ipv4"]
    assert client_ip.startswith(subnet), f"client IP {client_ip} not in prefix {netbox['prefix']}"


# --- the two models are connected: VM runs on the host Device ---------------


def test_client_vm_linked_to_host_device(api, netbox, client):
    vm = _results(api, "/api/virtualization/virtual-machines/", name=netbox["vm_name"])[0]
    assert vm["device"] is not None, "client VM is not linked to a host device"
    assert str(vm["device"]["name"]) == netbox["host_device"]


# --- tenancy -----------------------------------------------------------------


def test_contact_assigned_to_site(api, netbox, server):
    site_id = _results(api, "/api/dcim/sites/", name=netbox["site"])[0]["id"]
    assignments = _results(
        api, "/api/tenancy/contact-assignments/", object_type="dcim.site", object_id=site_id
    )
    assert assignments, "no contact assigned to the site"
