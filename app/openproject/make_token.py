#!/usr/bin/env python3
"""Generate demo OpenProject Enterprise Edition tokens.

The token format is the one implemented by the `openproject-token` gem:

    armor( base64( {"data": ..., "key": ..., "iv": ...} ) )

`data` is the JSON payload encrypted with AES-128-CBC, `key` is the 16-byte
AES key encrypted with RSA PKCS#1 v1.5 using the *private* key (the app
recovers it with the public key via public_decrypt), `iv` is the 16-byte
initialization vector.

The `signed` format wraps that container once more:

    armor( base64( {"payload": base64(container_json),
                    "signature": base64(RSA-SHA256(container_json))} ) )
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives import padding as sympadding
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

# Feature catalog from openproject-token 8.15.0 (lib/open_project/token/plans.rb)
LEGACY_ENTERPRISE_PLAN_FEATURES = [
    "baseline_comparison",
    "board_view",
    "conditional_highlighting",
    "custom_actions",
    "custom_field_hierarchies",
    "define_custom_style",
    "edit_attribute_groups",
    "gantt_pdf_export",
    "ldap_groups",
    "one_drive_sharepoint_file_storage",
    "placeholder_users",
    "project_list_sharing",
    "readonly_work_packages",
    "sso_auth_providers",
    "team_planner_view",
    "virus_scanning",
    "work_package_query_relation_columns",
    "work_package_sharing",
]

BASIC_PLAN_FEATURES = [
    "baseline_comparison",
    "board_view",
    "conditional_highlighting",
    "custom_actions",
    "custom_field_hierarchies",
    "define_custom_style",
    "edit_attribute_groups",
    "gantt_pdf_export",
    "meeting_templates",
    "multiple_active_sprints",
    "placeholder_users",
    "readonly_work_packages",
    "sprint_sharing",
    "team_planner_view",
    "work_package_query_relation_columns",
]

PROFESSIONAL_PLAN_FEATURES = [
    "internal_comments",
    "mcp_server",
    "one_drive_sharepoint_file_storage",
    "sprint_report_pro_widgets",
    "sso_auth_providers",
    "time_entry_time_restrictions",
    "work_package_sharing",
    "work_package_subject_generation",
]

PREMIUM_PLAN_FEATURES = [
    "calculated_values",
    "capture_external_links",
    "customize_life_cycle",
    "ldap_groups",
    "portfolio_management",
    "project_creation_wizard",
    "project_list_sharing",
    "project_specific_list_values",
    "resource_management",
    "weighted_item_lists",
]

CORPORATE_PLAN_FEATURES = [
    "nextcloud_sso",
    "scim_api",
    "virus_scanning",
    "xwiki_integration",
]


def _ordered_unique(*groups: list[str]) -> list[str]:
    return list(dict.fromkeys(feature for group in groups for feature in group))


ALL_FEATURES = _ordered_unique(
    BASIC_PLAN_FEATURES,
    PROFESSIONAL_PLAN_FEATURES,
    PREMIUM_PLAN_FEATURES,
    CORPORATE_PLAN_FEATURES,
    LEGACY_ENTERPRISE_PLAN_FEATURES,
)

PLANS = {
    "basic": _ordered_unique(BASIC_PLAN_FEATURES),
    "professional": _ordered_unique(BASIC_PLAN_FEATURES, PROFESSIONAL_PLAN_FEATURES),
    "premium": _ordered_unique(BASIC_PLAN_FEATURES, PROFESSIONAL_PLAN_FEATURES, PREMIUM_PLAN_FEATURES),
    "corporate": _ordered_unique(
        BASIC_PLAN_FEATURES, PROFESSIONAL_PLAN_FEATURES, PREMIUM_PLAN_FEATURES, CORPORATE_PLAN_FEATURES
    ),
    "legacy_enterprise": _ordered_unique(LEGACY_ENTERPRISE_PLAN_FEATURES, BASIC_PLAN_FEATURES),
    "legacy_enterprise_professional": _ordered_unique(
        LEGACY_ENTERPRISE_PLAN_FEATURES, BASIC_PLAN_FEATURES, PROFESSIONAL_PLAN_FEATURES
    ),
    "legacy_enterprise_premium": _ordered_unique(
        LEGACY_ENTERPRISE_PLAN_FEATURES, BASIC_PLAN_FEATURES, PROFESSIONAL_PLAN_FEATURES, PREMIUM_PLAN_FEATURES
    ),
    # Accepted by the gem, but it has no entry in FEATURES_PER_PLAN.
    "legacy_enterprise_corporate": [],
}

FEATURE_SET = set(ALL_FEATURES)
MARKER = "OPENPROJECT-EE TOKEN"


def log(message: str) -> None:
    print(f"[make_token] {message}", file=sys.stderr)


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def unb64(data: str) -> bytes:
    return base64.b64decode("".join(data.split()), validate=False)


def resolve_features(spec: str) -> list[str]:
    value = spec.strip()
    if value.lower() == "all":
        return list(ALL_FEATURES)
    if value.lower() in {"", "none"}:
        return []

    features = [item.strip() for item in value.split(",") if item.strip()]
    unknown = sorted({feature for feature in features if feature not in FEATURE_SET})
    if unknown:
        raise argparse.ArgumentTypeError(
            f"unknown feature(s): {', '.join(unknown)}. Use --list-features to see valid names."
        )
    return list(dict.fromkeys(features))


def parse_date(value: str) -> date:
    try:
        return date.fromisoformat(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"expected YYYY-MM-DD, got {value!r}") from exc


def load_or_create_keypair(key_dir: Path, key_size: int, regenerate: bool) -> rsa.RSAPrivateKey:
    key_dir.mkdir(parents=True, exist_ok=True)
    private_path = key_dir / "private.pem"
    public_path = key_dir / "public.pem"

    private_key = None
    if private_path.exists() and not regenerate:
        private_key = serialization.load_pem_private_key(private_path.read_bytes(), password=None)
        if not isinstance(private_key, rsa.RSAPrivateKey):
            raise SystemExit(f"{private_path} does not contain an RSA private key")
        if private_key.key_size != key_size:
            log(f"existing key is {private_key.key_size}-bit, requested {key_size}-bit; regenerating")
            private_key = None

    if private_key is None:
        log(f"generating {key_size}-bit RSA demo key pair")
        private_key = rsa.generate_private_key(public_exponent=65537, key_size=key_size)
        private_path.write_bytes(
            private_key.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.TraditionalOpenSSL,
                encryption_algorithm=serialization.NoEncryption(),
            )
        )
        os.chmod(private_path, 0o600)

    public_key = private_key.public_key()
    public_path.write_bytes(
        public_key.public_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PublicFormat.SubjectPublicKeyInfo,
        )
    )
    return private_key


def rsa_private_encrypt(message: bytes, private_key: rsa.RSAPrivateKey) -> bytes:
    """RSA PKCS#1 v1.5 type-1 padding + private-key operation.

    Equivalent to Ruby's OpenSSL::PKey::RSA#private_encrypt, which is what the
    OpenProject token generator uses. The app reverses it with public_decrypt.
    """
    numbers = private_key.private_numbers()
    modulus = numbers.public_numbers.n
    private_exponent = numbers.d
    size = (modulus.bit_length() + 7) // 8

    if len(message) > size - 11:
        raise ValueError(f"message too long: {len(message)} bytes for a {size}-byte key")

    padding_bytes = b"\xff" * (size - len(message) - 3)
    encoded = b"\x00\x01" + padding_bytes + b"\x00" + message
    ciphertext = pow(int.from_bytes(encoded, "big"), private_exponent, modulus)
    return ciphertext.to_bytes(size, "big")


def rsa_public_decrypt(ciphertext: bytes, public_key: rsa.RSAPublicKey) -> bytes:
    numbers = public_key.public_numbers()
    modulus, exponent = numbers.n, numbers.e
    size = (modulus.bit_length() + 7) // 8
    encoded = pow(int.from_bytes(ciphertext, "big"), exponent, modulus).to_bytes(size, "big")

    if encoded[:2] != b"\x00\x01":
        raise ValueError("invalid PKCS#1 v1.5 type-1 padding")
    separator = encoded.index(b"\x00", 2)
    return encoded[separator + 1 :]


def aes_encrypt(plaintext: bytes, key: bytes, iv: bytes) -> bytes:
    padder = sympadding.PKCS7(128).padder()
    padded = padder.update(plaintext) + padder.finalize()
    encryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
    return encryptor.update(padded) + encryptor.finalize()


def aes_decrypt(ciphertext: bytes, key: bytes, iv: bytes) -> bytes:
    decryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
    padded = decryptor.update(ciphertext) + decryptor.finalize()
    unpadder = sympadding.PKCS7(128).unpadder()
    return unpadder.update(padded) + unpadder.finalize()


def armor(blob: str) -> str:
    body = "\n".join(blob[index : index + 64] for index in range(0, len(blob), 64))
    return f"-----BEGIN {MARKER}-----\n{body}\n-----END {MARKER}-----"


def build_payload(args: argparse.Namespace) -> dict:
    features = list(args.features)
    payload = {
        "version": args.version,
        "subscriber": args.subscriber,
        "mail": args.mail,
        "company": args.company,
        "domain": args.domain,
        "plan": args.plan,
        "issued_at": args.issued_at.isoformat(),
        "starts_at": args.starts_at.isoformat(),
        "trial": args.trial,
        "features": features,
    }

    if args.validate_domain is not None:
        payload["validate_domain"] = args.validate_domain

    if args.expires_at is not None:
        payload["expires_at"] = args.expires_at.isoformat()
        payload["reprieve_days"] = args.reprieve_days

    for field in ("notify_admins_at", "notify_users_at", "block_changes_at"):
        value = getattr(args, field)
        if value is not None:
            payload[field] = value.isoformat()

    if not args.unlimited_users:
        payload["restrictions"] = {"active_user_count": args.active_user_count}

    return payload


def create_token(args: argparse.Namespace) -> tuple[str, dict, rsa.RSAPrivateKey]:
    private_key = load_or_create_keypair(args.key_dir, args.key_size, args.regenerate_keys)
    public_key = private_key.public_key()
    payload = build_payload(args)

    plaintext = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    aes_key = os.urandom(16)
    iv = os.urandom(16)
    encrypted_data = aes_encrypt(plaintext, aes_key, iv)
    encrypted_key = rsa_private_encrypt(aes_key, private_key)

    container = {
        "data": b64(encrypted_data),
        "key": b64(encrypted_key),
        "iv": b64(iv),
    }
    container_json = json.dumps(container, separators=(",", ":")).encode("utf-8")

    if args.format == "signed":
        signature = private_key.sign(container_json, padding.PKCS1v15(), hashes.SHA256())
        outer = {"payload": b64(container_json), "signature": b64(signature)}
    else:
        outer = container

    outer_json = json.dumps(outer, separators=(",", ":")).encode("utf-8")
    token = armor(b64(outer_json))

    verify_token(token, public_key, expected_payload=payload)
    return token, payload, private_key


def verify_token(token: str, public_key: rsa.RSAPublicKey, expected_payload: dict | None = None) -> dict:
    lines = token.strip().splitlines()
    if not lines or lines[0] != f"-----BEGIN {MARKER}-----" or lines[-1] != f"-----END {MARKER}-----":
        raise ValueError("armor markers are missing or invalid")

    outer = json.loads(unb64("".join(lines[1:-1])))

    if "payload" in outer:
        payload_bytes = unb64(outer["payload"])
        signature = unb64(outer["signature"])
        public_key.verify(signature, payload_bytes, padding.PKCS1v15(), hashes.SHA256())
        container = json.loads(payload_bytes)
    else:
        container = outer

    aes_key = rsa_public_decrypt(unb64(container["key"]), public_key)
    plaintext = aes_decrypt(unb64(container["data"]), aes_key, unb64(container["iv"]))
    payload = json.loads(plaintext)

    if expected_payload is not None and payload != expected_payload:
        raise ValueError("self-check failed: decrypted payload differs from the input payload")
    return payload


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Generate a demo OpenProject Enterprise Edition token with a throwaway RSA key.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--key-dir", type=Path, default=Path(__file__).resolve().parent / "keys",
                        help="directory holding private.pem / public.pem")
    parser.add_argument("--key-size", type=int, default=2048, help="RSA key size for the demo key")
    parser.add_argument("--regenerate-keys", action="store_true", help="replace an existing demo key pair")

    parser.add_argument("--subscriber", default="Example Subscriber")
    parser.add_argument("--mail", default="admin@example.com")
    parser.add_argument("--company", default="Example Company")
    parser.add_argument("--domain", default="example.com")
    parser.add_argument("--version", default="8.15.0", help="token version matching the bundled feature catalog")
    parser.add_argument("--plan", choices=sorted(PLANS), default="corporate")
    parser.add_argument("--features", type=resolve_features, default="all",
                        help="'all', 'none', or a comma-separated list of feature keys")

    parser.add_argument("--active-user-count", type=int, default=10000)
    parser.add_argument("--unlimited-users", action="store_true", help="omit the active_user_count restriction")

    # OpenProject runs in UTC+8; use that date so the token is not dated ahead
    # or behind by the host timezone. Start one day earlier to tolerate skew.
    today = datetime.now(timezone(timedelta(hours=8))).date()
    parser.add_argument("--issued-at", type=parse_date, default=today)
    parser.add_argument("--starts-at", type=parse_date, default=today - timedelta(days=1))
    parser.add_argument("--expires-at", type=parse_date, default=today + timedelta(days=3650))
    parser.add_argument("--no-expiry", action="store_true", help="omit expires_at (tokens without expiry)")
    parser.add_argument("--reprieve-days", type=int, default=7)
    parser.add_argument("--trial", action="store_true", help="mark the token as a trial (requires expiry)")
    parser.add_argument("--notify-admins-at", type=parse_date)
    parser.add_argument("--notify-users-at", type=parse_date)
    parser.add_argument("--block-changes-at", type=parse_date)
    parser.add_argument("--validate-domain", dest="validate_domain", action="store_true", default=None,
                        help="explicitly set validate_domain=true")
    parser.add_argument("--no-validate-domain", dest="validate_domain", action="store_false", default=None,
                        help="set validate_domain=false (requires an expiry)")

    parser.add_argument("--format", choices=("legacy", "signed"), default="signed",
                        help="signed {payload,signature} wrapper (default) or legacy {data,key,iv} container")
    parser.add_argument("--output", type=Path, help="write the armored token here instead of stdout")
    parser.add_argument("--payload-output", type=Path, help="write the plaintext payload JSON here")
    parser.add_argument("--list-features", action="store_true", help="print the feature catalog and exit")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if args.list_features:
        for name in ALL_FEATURES:
            print(name)
        return 0

    if args.no_expiry:
        args.expires_at = None
    if args.trial and args.expires_at is None:
        parser.error("--trial requires an expiry; do not combine it with --no-expiry")
    if args.validate_domain is False and args.expires_at is None:
        parser.error("--no-validate-domain requires an expiry")
    if args.validate_domain is False and args.domain is None:
        parser.error("--no-validate-domain requires --domain")
    if args.issued_at > args.starts_at:
        log("warning: issued_at is after starts_at")

    token, payload, private_key = create_token(args)

    public_path = args.key_dir / "public.pem"
    fingerprint = hashlib.sha256(
        private_key.public_key().public_bytes(
            encoding=serialization.Encoding.DER,
            format=serialization.PublicFormat.SubjectPublicKeyInfo,
        )
    ).hexdigest()

    log(f"demo private key: {args.key_dir / 'private.pem'} ({private_key.key_size}-bit RSA)")
    log(f"demo public key:  {public_path}")
    log(f"public key SHA-256 (DER): {fingerprint}")
    log(f"plan={args.plan}, features={len(payload['features'])}, domain={args.domain}")
    log("WARNING: signed with the demo key. An unmodified OpenProject instance rejects this token.")

    if args.payload_output:
        args.payload_output.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
        log(f"payload written to {args.payload_output}")

    if args.output:
        args.output.write_text(token + "\n")
        log(f"token written to {args.output}")
    else:
        print(token)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
