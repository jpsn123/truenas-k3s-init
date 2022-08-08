#!/usr/bin/env python3
"""
Coder Enterprise License Signer

Generates Ed25519-signed JWT licenses compatible with Coder's license validation.
Usage:
    # Generate a new keypair and sign a license
    python3 sign_license.py --generate-key --key-dir ./keys --output license.txt

    # Sign with existing private key
    python3 sign_license.py --private-key ./keys/private.key --output license.txt

    # Verify a license against a public key
    python3 sign_license.py --verify license.txt --public-key ./keys/2022-08-12

    # Replace the official public key in the Coder source
    python3 sign_license.py --generate-key --key-dir ./keys --patch-source /root/coder
"""

import argparse
import base64
import json
import os
import struct
import time
import uuid

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def generate_keypair(key_dir: str) -> tuple:
    """Generate Ed25519 keypair and save to key_dir."""
    os.makedirs(key_dir, exist_ok=True)

    private_key = Ed25519PrivateKey.generate()
    public_key = private_key.public_key()

    # Save private key (raw 32 bytes + optional seed format)
    priv_bytes = private_key.private_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PrivateFormat.Raw,
        encryption_algorithm=serialization.NoEncryption(),
    )
    priv_path = os.path.join(key_dir, "private.key")
    with open(priv_path, "wb") as f:
        f.write(priv_bytes)
    os.chmod(priv_path, 0o600)
    print(f"Private key saved to {priv_path} ({len(priv_bytes)} bytes)")

    # Save public key as raw 32 bytes (same format as Coder's keys/2022-08-12)
    pub_bytes = public_key.public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    pub_path = os.path.join(key_dir, "2022-08-12")
    with open(pub_path, "wb") as f:
        f.write(pub_bytes)
    print(f"Public key saved to {pub_path} ({len(pub_bytes)} bytes)")

    return private_key, public_key


def load_private_key(path: str) -> Ed25519PrivateKey:
    """Load an Ed25519 private key from raw bytes."""
    with open(path, "rb") as f:
        data = f.read()
    return Ed25519PrivateKey.from_private_bytes(data)


def load_public_key(path: str):
    """Load an Ed25519 public key from raw bytes."""
    with open(path, "rb") as f:
        data = f.read()
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    return Ed25519PublicKey.from_public_bytes(data)


def base64url_encode(data: bytes) -> str:
    """Base64url encode without padding."""
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def base64url_decode(s: str) -> bytes:
    """Base64url decode with padding restoration."""
    s = s + "=" * (4 - len(s) % 4)
    return base64.urlsafe_b64decode(s)


def sign_jwt(payload: dict, private_key: Ed25519PrivateKey, kid: str = "2022-08-12") -> str:
    """Sign a JWT using EdDSA (Ed25519) with manual JOSE header construction."""
    header = {
        "alg": "EdDSA",
        "kid": kid,
        "typ": "JWT",
    }

    header_b64 = base64url_encode(json.dumps(header, separators=(",", ":")).encode())
    payload_b64 = base64url_encode(json.dumps(payload, separators=(",", ":")).encode())

    signing_input = f"{header_b64}.{payload_b64}".encode("ascii")
    signature = private_key.sign(signing_input)
    signature_b64 = base64url_encode(signature)

    return f"{header_b64}.{payload_b64}.{signature_b64}"


def verify_jwt(token: str, public_key_pem) -> dict:
    """Verify a JWT and return its claims."""
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError("Invalid JWT format")

    header = json.loads(base64url_decode(parts[0]))
    if header.get("alg") != "EdDSA":
        raise ValueError(f"Unsupported algorithm: {header.get('alg')}")

    signing_input = f"{parts[0]}.{parts[1]}".encode("ascii")
    signature = base64url_decode(parts[2])

    public_key_pem.verify(signature, signing_input)

    claims = json.loads(base64url_decode(parts[1]))
    return claims


def build_claims(
    sub: str = "admin@example.com",
    account_type: str = "enterprise",
    account_id: str = None,
    feature_set: str = "premium",
    duration_days: int = 365,
    grace_days: int = 30,
    user_limit: int = 0,
    features: dict = None,
    addons: list = None,
) -> dict:
    """Build Coder license claims."""
    now = int(time.time())
    exp = now + (duration_days + grace_days) * 86400
    license_expires = now + duration_days * 86400

    if account_id is None:
        account_id = sub

    if features is None:
        features = {
            "user_limit": user_limit,
            "audit_log": 1,
            "browser_only": 0,
            "scim": 1,
            "template_rbac": 1,
            "high_availability": 1,
            "multiple_git_auth": 1,
            "external_provisioner_daemons": 1,
            "appearance": 1,
            "managed_agent_limit": 1000000,
            "ai_governance_user_limit": 1000000,
        }

    if addons is None:
        addons = ["ai_governance"]

    claims = {
        "sub": sub,
        "exp": exp,
        "nbf": now,
        "iat": now,
        "jti": str(uuid.uuid4()),
        "license_expires": license_expires,
        "account_type": account_type,
        "account_id": account_id,
        "trial": False,
        "require_telemetry": False,
        "version": 3,
        "publish_usage_data": False,
        "all_features": True,
        "feature_set": feature_set,
        "features": features,
        "addons": addons,
    }
    return claims


def patch_source(source_dir: str, key_dir: str):
    """Replace the public key in Coder source with the new one."""
    src_key = os.path.join(key_dir, "2022-08-12")
    dst_key = os.path.join(source_dir, "enterprise", "coderd", "keys", "2022-08-12")

    if not os.path.exists(src_key):
        print(f"Error: public key not found at {src_key}")
        return

    import shutil
    shutil.copy2(src_key, dst_key)
    print(f"Patched {dst_key} with new public key")


def main():
    parser = argparse.ArgumentParser(description="Coder Enterprise License Signer")
    parser.add_argument("--generate-key", action="store_true", help="Generate new Ed25519 keypair")
    parser.add_argument("--key-dir", default="./license_keys", help="Directory for key storage")
    parser.add_argument("--private-key", default=None, help="Path to existing private key")
    parser.add_argument("--public-key", default=None, help="Path to public key for verification")
    parser.add_argument("--output", "-o", default="license.txt", help="Output license file path")
    parser.add_argument("--verify", default=None, help="Verify a license file")
    parser.add_argument("--patch-source", default=None, help="Patch Coder source with new public key")
    parser.add_argument("--sub", default="admin@example.com", help="License subject (email)")
    parser.add_argument("--account-type", default="premium", help="Account type (premium)")
    parser.add_argument("--feature-set", default="premium", help="Feature set (premium)")
    parser.add_argument("--duration-days", type=int, default=3650, help="License duration in days")
    parser.add_argument("--grace-days", type=int, default=30, help="Grace period in days")
    parser.add_argument("--user-limit", type=int, default=0, help="User limit (0=unlimited)")
    args = parser.parse_args()

    if args.verify:
        pub_key_path = args.public_key or os.path.join(args.key_dir, "2022-08-12")
        if not os.path.exists(pub_key_path):
            # Try the official key
            pub_key_path = os.path.join(
                os.path.dirname(__file__), "enterprise", "coderd", "keys", "2022-08-12"
            )
        pub_key = load_public_key(pub_key_path)
        with open(args.verify, "r") as f:
            token = f.read().strip()
        try:
            claims = verify_jwt(token, pub_key)
            print("Signature VALID")
            print(json.dumps(claims, indent=2))
        except Exception as e:
            print(f"Signature INVALID: {e}")
        return

    if args.generate_key:
        private_key, _ = generate_keypair(args.key_dir)
    elif args.private_key:
        private_key = load_private_key(args.private_key)
    else:
        print("Error: specify --generate-key or --private-key")
        return

    claims = build_claims(
        sub=args.sub,
        account_type=args.account_type,
        feature_set=args.feature_set,
        duration_days=args.duration_days,
        grace_days=args.grace_days,
        user_limit=args.user_limit,
    )

    token = sign_jwt(claims, private_key)

    with open(args.output, "w") as f:
        f.write(token)
    print(f"License written to {args.output}")
    print(f"Token length: {len(token)}")

    # Print claims summary
    print(f"\nClaims summary:")
    print(f"  Subject:       {claims['sub']}")
    print(f"  Account Type:  {claims['account_type']}")
    print(f"  Feature Set:   {claims['feature_set']}")
    print(f"  Version:       {claims['version']}")
    print(f"  Issued At:     {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(claims['iat']))}")
    print(f"  Not Before:    {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(claims['nbf']))}")
    print(f"  License Expires: {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(claims['license_expires']))}")
    print(f"  JWT Expires:   {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(claims['exp']))}")

    # Verify the token we just signed
    pub_key_path = os.path.join(args.key_dir, "2022-08-12")
    if os.path.exists(pub_key_path):
        pub_key = load_public_key(pub_key_path)
        try:
            verify_jwt(token, pub_key)
            print("\nSelf-verification: PASSED")
        except Exception as e:
            print(f"\nSelf-verification FAILED: {e}")

    if args.patch_source:
        patch_source(args.patch_source, args.key_dir)


if __name__ == "__main__":
    main()
