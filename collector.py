import json
import boto3
import hashlib
from datetime import datetime
import os

s3 = boto3.client('s3')
config = boto3.client('configservice')
VAULT_NAME = os.environ['EVIDENCE_VAULT_NAME']

def lambda_handler(event, context):
    # Retrieve AWS Config state
    compliance_response = config.get_compliance_summary_by_resource_type(
        ResourceType='AWS::S3::Bucket'
    )

    # Construct immutable evidence schema
    evidence_payload = {
        "evidence_id": f"EVD-{datetime.utcnow().strftime('%Y%m%d%H%M%S')}",
        "collection_timestamp": datetime.utcnow().isoformat(),
        "resource_type": "AWS::S3::Bucket",
        "compliance_summary": compliance_response,
        "environment": os.environ.get('ENVIRONMENT', 'Production')
    }

    # Compute cryptographic hash for tamper evidence
    payload_string = json.dumps(evidence_payload, sort_keys=True)
    payload_hash = hashlib.sha256(payload_string.encode('utf-8')).hexdigest()
    evidence_payload['sha256_hash'] = payload_hash

    file_name = f"evidence_{evidence_payload['evidence_id']}.json"

    # Store directly into WORM S3 Vault
    s3.put_object(
        Bucket=VAULT_NAME,
        Key=file_name,
        Body=json.dumps(evidence_payload, indent=2),
        ContentType='application/json',
        Metadata={
            'sha256_hash': payload_hash,
            'chain-of-custody': 'automated-lambda-collector'
        }
    )

    return {
        'statusCode': 200,
        'body': json.dumps({
            'status': 'success',
            'evidence_id': evidence_payload['evidence_id'],
            'sha256_hash': payload_hash
        })
    }
