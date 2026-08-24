import importlib
import json
import os
import sys
from datetime import datetime, timezone
from decimal import Decimal
from unittest.mock import MagicMock

os.environ.setdefault("EVIDENCE_VAULT_NAME", "test-vault")

boto3_mock = MagicMock()
sys.modules["boto3"] = boto3_mock
collector = importlib.import_module("collector")


def test_json_default_normalizes_aws_types():
    timestamp = datetime(2026, 8, 24, 12, 0, tzinfo=timezone.utc)
    assert collector.json_default(timestamp) == timestamp.isoformat()
    assert collector.json_default(Decimal("3.14")) == "3.14"


def test_canonical_json_is_deterministic():
    left = {"b": 2, "a": 1}
    right = {"a": 1, "b": 2}
    assert collector.canonical_json(left) == collector.canonical_json(right)


def test_lambda_writes_hashed_evidence(monkeypatch):
    fake_config = MagicMock()
    fake_config.get_compliance_summary_by_resource_type.return_value = {
        "ComplianceSummariesByResourceType": []
    }
    fake_sts = MagicMock()
    fake_sts.get_caller_identity.return_value = {"Account": "123456789012"}
    fake_s3 = MagicMock()
    fake_s3.put_object.return_value = {"VersionId": "version-1"}

    monkeypatch.setattr(collector, "config", fake_config)
    monkeypatch.setattr(collector, "sts", fake_sts)
    monkeypatch.setattr(collector, "s3", fake_s3)

    context = MagicMock()
    context.aws_request_id = "request-123"
    response = collector.lambda_handler({}, context)

    assert response["statusCode"] == 200
    put_args = fake_s3.put_object.call_args.kwargs
    body = json.loads(put_args["Body"].decode("utf-8"))
    assert body["aws_account_id"] == "123456789012"
    assert len(body["sha256_hash"]) == 64
    assert put_args["Metadata"]["chain-of-custody"] == "automated-lambda-collector"
