"""Cert fixtures + an in-process TLS server for the tls_cli hermetic tests.

Builds a self-signed "root" and a leaf signed by it (the step-ca analogue), plus a leaf whose
issuer CN mimics Let's Encrypt STAGING. A tiny threaded TLS server serves a given leaf so the
CLI can do a real handshake — no VM, no Docker, no network egress.
"""

import datetime
import socket
import ssl
import threading

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

_NOW = datetime.datetime.now(datetime.timezone.utc)


def _key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _make_ca(cn):
    key = _key()
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
    ski = x509.SubjectKeyIdentifier.from_public_key(key.public_key())
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(_NOW - datetime.timedelta(days=1))
        .not_valid_after(_NOW + datetime.timedelta(days=10))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=False,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=True,
                crl_sign=True,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(ski, critical=False)
        .sign(key, hashes.SHA256())
    )
    return key, cert


def _make_leaf(ca_key, ca_cert, cn, sans):
    key = _key()
    # A strict verifier (OpenSSL) requires the leaf's AKI to match the CA's SKI, like real
    # step-ca / LE certs — derive AKI from the CA's public key.
    aki = x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key())
    cert = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)]))
        .issuer_name(ca_cert.subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(_NOW - datetime.timedelta(days=1))
        .not_valid_after(_NOW + datetime.timedelta(days=10))
        .add_extension(
            x509.SubjectAlternativeName([x509.DNSName(s) for s in sans]), critical=False
        )
        .add_extension(aki, critical=False)
        .sign(ca_key, hashes.SHA256())
    )
    return key, cert


def _write(path, data: bytes):
    path.write_bytes(data)
    return str(path)


def _pem_cert(cert):
    return cert.public_bytes(serialization.Encoding.PEM)


def _pem_key(key):
    return key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    )


class _TLSServer:
    def __init__(self, certfile, keyfile):
        self.ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.ctx.load_cert_chain(certfile, keyfile)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(5)
        self.port = self.sock.getsockname()[1]
        self._stop = False
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        while not self._stop:
            self.sock.settimeout(0.5)
            try:
                conn, _ = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            try:
                tls = self.ctx.wrap_socket(conn, server_side=True)
                tls.recv(1024)
                tls.close()
            except Exception:  # noqa: BLE001 - a client that hangs up mid-handshake is fine
                try:
                    conn.close()
                except OSError:
                    pass

    def stop(self):
        self._stop = True
        try:
            self.sock.close()
        except OSError:
            pass


@pytest.fixture
def root_pem(tmp_path):
    """A step-ca-analogue root; returns (path, ca_key, ca_cert)."""
    key, cert = _make_ca("centralized-pki-ca Root CA")
    path = _write(tmp_path / "root_ca.crt", _pem_cert(cert))
    return path, key, cert


@pytest.fixture
def wrong_root_pem(tmp_path):
    _key_, cert = _make_ca("Some Other Root CA")
    return _write(tmp_path / "wrong_root.crt", _pem_cert(cert))


@pytest.fixture
def internal_server(tmp_path, root_pem):
    """A leaf signed by the step-ca root, served over TLS. Yields the listening port."""
    _path, ca_key, ca_cert = root_pem
    leaf_key, leaf_cert = _make_leaf(ca_key, ca_cert, "vault.lab.test", ["vault.lab.test"])
    cf = _write(tmp_path / "leaf.crt", _pem_cert(leaf_cert))
    kf = _write(tmp_path / "leaf.key", _pem_key(leaf_key))
    server = _TLSServer(cf, kf)
    yield server.port
    server.stop()


@pytest.fixture
def staging_server(tmp_path):
    """A leaf whose issuer CN mimics Let's Encrypt STAGING. Yields the listening port."""
    ca_key, ca_cert = _make_ca("(STAGING) Pretend Pear X1")
    leaf_key, leaf_cert = _make_leaf(ca_key, ca_cert, "auth.lab.test", ["auth.lab.test"])
    cf = _write(tmp_path / "staging_leaf.crt", _pem_cert(leaf_cert))
    kf = _write(tmp_path / "staging_leaf.key", _pem_key(leaf_key))
    server = _TLSServer(cf, kf)
    yield server.port
    server.stop()
