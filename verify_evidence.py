import argparse
import hashlib
import json
import sys


def canonical_json(payload):
    return json.dumps(payload, sort_keys=True, separators=(",", ":"))


def verify(path):
    with open(path, "r", encoding="utf-8") as evidence_file:
        payload = json.load(evidence_file)

    recorded_hash = payload.pop("sha256_hash", None)
    if not recorded_hash:
        raise ValueError("Evidence file has no sha256_hash field")

    calculated_hash = hashlib.sha256(
        canonical_json(payload).encode("utf-8")
    ).hexdigest()

    return recorded_hash, calculated_hash, recorded_hash == calculated_hash


def main():
    parser = argparse.ArgumentParser(description="Verify a GRC evidence JSON file")
    parser.add_argument("evidence_file")
    args = parser.parse_args()

    recorded, calculated, valid = verify(args.evidence_file)
    print(f"Recorded:   {recorded}")
    print(f"Calculated: {calculated}")
    print(f"Integrity:  {'VALID' if valid else 'FAILED'}")
    return 0 if valid else 1


if __name__ == "__main__":
    sys.exit(main())
