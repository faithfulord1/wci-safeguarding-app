import hashlib
import json
import logging
import os
import uuid
from datetime import date, datetime, timezone
from decimal import Decimal

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")
config = boto3.client("configservice")
sts = boto3.client("sts")

VAULT_NAME = os.environ["EVIDENCE_VAULT_NAME"]
ENVIRONMENT = os.environ.get("ENVIRONMENT", "Production")
RESOURCE_TYPE = os.environ.get("RESOURCE_TYPE", "AWS::S3::Bucket")


def json_default(value):
    """Normalize AWS SDK values so evidence can be deterministically serialized."""
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    if isinstance(value, Decimal):
        return str(value)
    raise TypeError(f"Type {type(value).__name__} is not JSON serializable")


def canonical_json(payload):
    return json.dumps(
        payload,
        sort_keys=True,
        separators=(",", ":"),
        default=json_default,
    )


def lambda_handler(event, context):
    collected_at = datetime.now(timezone.utc)
    request_id = getattr(context, "aws_request_id", None) or str(uuid.uuid4())

    compliance_response = config.get_compliance_summary_by_resource_type(
        ResourceTypes=[RESOURCE_TYPE]
    )
    account_id = sts.get_caller_identity()["Account"]

    evidence_payload = {
        "schema_version": "1.0",
        "evidence_id": f"EVD-{collected_at.strftime('%Y%m%dT%H%M%S%fZ')}",
        "collection_timestamp": collected_at.isoformat(),
        "collector": "aws-lambda-config-compliance-collector",
        "collector_request_id": request_id,
        "aws_account_id": account_id,
        "aws_region": os.environ.get("AWS_REGION", "unknown"),
        "resource_type": RESOURCE_TYPE,
        "environment": ENVIRONMENT,
        "compliance_summary": compliance_response,
    }

    payload_hash = hashlib.sha256(
        canonical_json(evidence_payload).encode("utf-8")
    ).hexdigest()
    evidence_payload["sha256_hash"] = payload_hash

    key = (
        f"account={account_id}/environment={ENVIRONMENT.lower()}/"
        f"year={collected_at:%Y}/month={collected_at:%m}/day={collected_at:%d}/"
        f"evidence_{evidence_payload['evidence_id']}_{request_id}.json"
    )

    body = json.dumps(
        evidence_payload,
        indent=2,
        sort_keys=True,
        default=json_default,
    ).encode("utf-8")

    response = s3.put_object(
        Bucket=VAULT_NAME,
        Key=key,
        Body=body,
        ContentType="application/json",
        Metadata={
            "sha256-hash": payload_hash,
            "chain-of-custody": "automated-lambda-collector",
            "schema-version": "1.0",
        },
    )

    logger.info(
        "Stored immutable evidence id=%s key=%s version_id=%s hash=%s",
        evidence_payload["evidence_id"],
        key,
        response.get("VersionId", "unknown"),
        payload_hash,
    )

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "status": "success",
                "evidence_id": evidence_payload["evidence_id"],
                "object_key": key,
                "version_id": response.get("VersionId"),
                "sha256_hash": payload_hash,
            }
        ),
    }
