#!/usr/bin/env python3
"""Generate certificate material once, then print license-shaped JWTs from it.

Usage:

    python3 generate_enterprise_license_sample.py certs
    python3 generate_enterprise_license_sample.py jwt --install-id <install-id>

Generated certificate/key filenames intentionally do not use the old
`enterprise.signed.sample` prefix.
"""

from __future__ import annotations

import argparse
from base64 import b64decode, b64encode
from datetime import UTC, datetime, timedelta
from pathlib import Path

import jwt
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509 import (
    BasicConstraints,
    Certificate,
    CertificateBuilder,
    KeyUsage,
    Name,
    NameAttribute,
    load_der_x509_certificate,
    load_pem_x509_certificate,
    random_serial_number,
)
from cryptography.x509.oid import NameOID

OUT_DIR = Path(__file__).resolve().parent
PUBLIC_CERT_PATH = OUT_DIR / "public.pem"
INTERMEDIATE_CERT_PATH = OUT_DIR / "intermediate.pem"
LEAF_CERT_PATH = OUT_DIR / "leaf.pem"
LEAF_KEY_PATH = OUT_DIR / "leaf.key.pem"
LICENSE_AUDIENCE_PREFIX = "enterprise.goauthentik.io/license/"
LICENSE_NAME = "Manual Audit Enterprise License"
VALIDITY_DAYS = 36500
INTERNAL_USERS = 1_000_000
EXTERNAL_USERS = 1_000_000
X5C_CERTIFICATE_COUNT = 2

FEATURES = [
    "mutual_tls_stage",
    "google_device_trust_connector",
    "account_lockdown_stage",
    "source_stage",
    "google_workspace_provider",
    "microsoft_entra_provider",
    "ssf_provider",
    "ws_federation_provider",
    "radius_provider_eap_tls",
    "google_chrome_connector",
    "fleet_endpoint_connector",
    "agent_endpoint_connector",
    "unique_password_policy",
    "data_export_reports",
    "access_lifecycle_reviews",
    "enterprise_audit_expanded_diff",
]


def name(common_name: str) -> Name:
    return Name(
        [
            NameAttribute(NameOID.COUNTRY_NAME, "US"),
            NameAttribute(NameOID.STATE_OR_PROVINCE_NAME, "California"),
            NameAttribute(NameOID.LOCALITY_NAME, "San Francisco"),
            NameAttribute(NameOID.ORGANIZATION_NAME, "Audit Sample Only"),
            NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, "Enterprise Licenses"),
            NameAttribute(NameOID.COMMON_NAME, common_name),
        ]
    )


def new_key() -> ec.EllipticCurvePrivateKey:
    return ec.generate_private_key(ec.SECP384R1())


def build_cert(
    *,
    subject: Name,
    issuer: Name,
    public_key,
    issuer_key: ec.EllipticCurvePrivateKey,
    is_ca: bool,
    not_before: datetime,
    not_after: datetime,
) -> Certificate:
    builder = (
        CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(public_key)
        .serial_number(random_serial_number())
        .not_valid_before(not_before)
        .not_valid_after(not_after)
        .add_extension(
            BasicConstraints(ca=is_ca, path_length=0 if is_ca else None),
            critical=True,
        )
        .add_extension(
            KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=is_ca,
                crl_sign=is_ca,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
    )
    return builder.sign(private_key=issuer_key, algorithm=hashes.SHA384())


def der_b64(cert: Certificate) -> str:
    return b64encode(cert.public_bytes(serialization.Encoding.DER)).decode("ascii")


def pem_cert(cert: Certificate) -> bytes:
    return cert.public_bytes(serialization.Encoding.PEM)


def pem_private_key(key: ec.EllipticCurvePrivateKey) -> bytes:
    return key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def load_private_key(path: Path) -> ec.EllipticCurvePrivateKey:
    return serialization.load_pem_private_key(path.read_bytes(), password=None)


def generate_certificates() -> None:
    now = datetime.now(UTC).replace(microsecond=0)
    not_after = now + timedelta(days=VALIDITY_DAYS)

    root_key = new_key()
    intermediate_key = new_key()
    leaf_key = new_key()

    root_subject = name("Audit Sample Enterprise Licensing Root X1")
    root_cert = build_cert(
        subject=root_subject,
        issuer=root_subject,
        public_key=root_key.public_key(),
        issuer_key=root_key,
        is_ca=True,
        not_before=now - timedelta(minutes=5),
        not_after=not_after,
    )
    intermediate_cert = build_cert(
        subject=name("Audit Sample Enterprise Licensing Intermediate"),
        issuer=root_cert.subject,
        public_key=intermediate_key.public_key(),
        issuer_key=root_key,
        is_ca=True,
        not_before=now - timedelta(minutes=5),
        not_after=not_after,
    )
    leaf_cert = build_cert(
        subject=name("Audit Sample Enterprise License Signing Leaf"),
        issuer=intermediate_cert.subject,
        public_key=leaf_key.public_key(),
        issuer_key=intermediate_key,
        is_ca=False,
        not_before=now - timedelta(minutes=5),
        not_after=not_after,
    )

    PUBLIC_CERT_PATH.write_bytes(pem_cert(root_cert))
    INTERMEDIATE_CERT_PATH.write_bytes(pem_cert(intermediate_cert))
    LEAF_CERT_PATH.write_bytes(pem_cert(leaf_cert))
    LEAF_KEY_PATH.write_bytes(pem_private_key(leaf_key))

    print(f"wrote: {PUBLIC_CERT_PATH}")
    print(f"wrote: {INTERMEDIATE_CERT_PATH}")
    print(f"wrote: {LEAF_CERT_PATH}")
    print(f"wrote: {LEAF_KEY_PATH}")


def load_certificate_material() -> tuple[
    Certificate,
    Certificate,
    Certificate,
    ec.EllipticCurvePrivateKey,
]:
    missing_paths = [
        path
        for path in (PUBLIC_CERT_PATH, INTERMEDIATE_CERT_PATH, LEAF_CERT_PATH, LEAF_KEY_PATH)
        if not path.exists()
    ]
    if missing_paths:
        missing = ", ".join(str(path) for path in missing_paths)
        raise FileNotFoundError(f"missing certificate material: {missing}; run certs first")

    root = load_pem_x509_certificate(PUBLIC_CERT_PATH.read_bytes())
    intermediate = load_pem_x509_certificate(INTERMEDIATE_CERT_PATH.read_bytes())
    leaf = load_pem_x509_certificate(LEAF_CERT_PATH.read_bytes())
    leaf_key = load_private_key(LEAF_KEY_PATH)
    return root, intermediate, leaf, leaf_key


def verify_directly_issued_by(child: Certificate, issuer: Certificate) -> None:
    child.verify_directly_issued_by(issuer)


def verify_certificate_chain(
    root: Certificate,
    intermediate: Certificate,
    leaf: Certificate,
) -> None:
    verify_directly_issued_by(leaf, intermediate)
    verify_directly_issued_by(intermediate, root)


def build_payload(audience: str) -> dict:
    now = datetime.now(UTC).replace(microsecond=0)
    expires = now + timedelta(days=VALIDITY_DAYS)
    return {
        "aud": audience,
        "exp": int(expires.timestamp()),
        "name": LICENSE_NAME,
        "internal_users": INTERNAL_USERS,
        "external_users": EXTERNAL_USERS,
        "license_flags": [],
        "license_type": "enterprise",
        "edition": "enterprise",
        "features": FEATURES,
        "iat": int(now.timestamp()),
        "nbf": int(now.timestamp()),
        "note": "Signed by a local audit-only CA chain, not Authentik's official licensing CA.",
    }


def generate_jwt(install_id: str) -> str:
    root, intermediate, leaf, leaf_key = load_certificate_material()
    verify_certificate_chain(root, intermediate, leaf)

    audience = f"{LICENSE_AUDIENCE_PREFIX}{install_id}"
    headers = {
        "typ": "JWT",
        "alg": "ES384",
        "x5c": [der_b64(leaf), der_b64(intermediate)],
    }
    payload = build_payload(audience)
    token = jwt.encode(payload, pem_private_key(leaf_key), algorithm="ES384", headers=headers)
    if isinstance(token, bytes):
        token = token.decode("ascii")

    verify_generated(token, audience, root)
    return token


def verify_generated(token: str, audience: str, root: Certificate) -> None:
    header = jwt.get_unverified_header(token)
    x5c = header.get("x5c", [])
    if len(x5c) != X5C_CERTIFICATE_COUNT:
        raise ValueError(f"expected {X5C_CERTIFICATE_COUNT} x5c certificates, got {len(x5c)}")

    leaf = load_der_x509_certificate(b64decode(x5c[0]))
    intermediate = load_der_x509_certificate(b64decode(x5c[1]))
    verify_certificate_chain(root, intermediate, leaf)
    jwt.decode(token, leaf.public_key(), algorithms=["ES384"], audience=audience)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("certs", help="Generate and save local certificate material.")
    jwt_parser = subparsers.add_parser("jwt", help="Print a JWT using saved certificate material.")
    jwt_parser.add_argument(
        "--install-id",
        required=True,
        help="Install ID used to build the JWT audience claim.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.command == "certs":
        generate_certificates()
        return
    token = generate_jwt(args.install_id)
    print(token)


if __name__ == "__main__":
    main()
