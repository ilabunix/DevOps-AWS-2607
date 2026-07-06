"""
OpsIQ Central — api_handler.py
Single Lambda proxy for all REST API routes. Path-based routing with CORS.
"""
import json
import os
import time

import boto3
from boto3.dynamodb.conditions import Attr, Key
from botocore.exceptions import ClientError

TOPOLOGY_TABLE  = os.environ['TOPOLOGY_TABLE']
ANOMALY_TABLE   = os.environ['ANOMALY_TABLE']
INCIDENT_TABLE  = os.environ['INCIDENT_TABLE']
HEALTH_TABLE    = os.environ['HEALTH_TABLE']
TOPOLOGY_BUCKET = os.environ['TOPOLOGY_BUCKET']
RUNBOOKS_BUCKET = os.environ['RUNBOOKS_BUCKET']
BEDROCK_MODEL_ID = os.environ['BEDROCK_MODEL_ID']
REGION          = os.environ['REGION']
PROJECT         = os.environ['PROJECT_NAME']

ddb     = boto3.resource('dynamodb')
s3      = boto3.client('s3')
bedrock = boto3.client('bedrock-runtime', region_name=REGION)

t_tbl = ddb.Table(TOPOLOGY_TABLE)
a_tbl = ddb.Table(ANOMALY_TABLE)
i_tbl = ddb.Table(INCIDENT_TABLE)
h_tbl = ddb.Table(HEALTH_TABLE)

CORS_HEADERS = {
    'Access-Control-Allow-Origin':  '*',
    'Access-Control-Allow-Headers': 'Content-Type,X-Amz-Date,Authorization',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Content-Type': 'application/json',
}


def _resp(status: int, body) -> dict:
    return {
        'statusCode': status,
        'headers': CORS_HEADERS,
        'body': json.dumps(body, default=str),
    }


# ── ROUTE HANDLERS ─────────────────────────────────────────────────────────

def get_accounts(_params: dict) -> dict:
    """GET /accounts — all account health scores."""
    resp     = h_tbl.scan()
    accounts = resp.get('Items', [])
    return _resp(200, {'accounts': accounts})


def get_topology(params: dict) -> dict:
    """GET /accounts/{id}/topology — D3 graph JSON."""
    account_id = params.get('accountId')
    try:
        obj  = s3.get_object(Bucket=TOPOLOGY_BUCKET, Key=f'{account_id}/current.json')
        data = json.loads(obj['Body'].read())
        return _resp(200, data)
    except ClientError:
        return _resp(404, {'error': f'Topology not found for {account_id}'})


def get_anomalies(params: dict) -> dict:
    """GET /accounts/{id}/anomalies — last 30 min."""
    account_id = params.get('accountId')
    cutoff     = str(int((time.time() - 30 * 60) * 1000))
    resp       = a_tbl.query(
        KeyConditionExpression=Key('accountId').eq(account_id) & Key('sortKey').gte(cutoff),
        ScanIndexForward=False,
        Limit=50,
    )
    items = resp.get('Items', [])
    # Parse 'details' JSON string and merge into the item for richer frontend display
    enriched = []
    for item in items:
        if isinstance(item.get('details'), str):
            try:
                detail_data = json.loads(item['details'])
                merged = {**item, **detail_data}
                enriched.append(merged)
            except Exception:
                enriched.append(item)
        else:
            enriched.append(item)
    return _resp(200, {'accountId': account_id, 'anomalies': enriched})


def get_incidents(params: dict) -> dict:
    """GET /accounts/{id}/incidents — recent incidents via GSI."""
    account_id = params.get('accountId')
    resp       = i_tbl.query(
        IndexName='accountId-timestamp-index',
        KeyConditionExpression=Key('accountId').eq(account_id),
        ScanIndexForward=False,
        Limit=20,
    )
    return _resp(200, {'accountId': account_id, 'incidents': resp.get('Items', [])})


def get_incident_detail(params: dict) -> dict:
    """GET /incidents/{id} — full incident with AI summary."""
    incident_id = params.get('incidentId')
    resp = i_tbl.scan(
        FilterExpression=Attr('incidentId').eq(incident_id),
        Limit=1,
    )
    items = resp.get('Items', [])
    if not items:
        return _resp(404, {'error': 'Incident not found'})
    return _resp(200, items[0])


def get_explain(params: dict) -> dict:
    """GET /accounts/{id}/explain — Bedrock architecture narrative."""
    account_id = params.get('accountId')
    try:
        obj      = s3.get_object(Bucket=TOPOLOGY_BUCKET, Key=f'{account_id}/current.json')
        topology = json.loads(obj['Body'].read())
    except ClientError:
        return _resp(404, {'error': f'Topology not found for {account_id}'})

    nodes_summary = json.dumps(topology.get('nodes', [])[:15], indent=2)
    prompt = f"""You are an AWS Solutions Architect. Analyze this infrastructure topology for account '{account_id}' and provide a clear, concise narrative explanation suitable for an engineering team.

Infrastructure nodes:
{nodes_summary}

Write a 3-4 paragraph explanation covering:
1. What this application does (infer from resource types and names)
2. How the components connect and data flows through the system
3. Key architectural patterns in use
4. Any architectural risks or observations

Be specific — use actual resource names and types from the data. Keep it under 300 words."""

    body = json.dumps({
        'anthropic_version': 'bedrock-2023-05-31',
        'max_tokens': 600,
        'messages': [{'role': 'user', 'content': prompt}],
    })
    resp   = bedrock.invoke_model(
        modelId=BEDROCK_MODEL_ID,
        contentType='application/json',
        accept='application/json',
        body=body,
    )
    result    = json.loads(resp['body'].read())
    narrative = result['content'][0]['text']
    return _resp(200, {'accountId': account_id, 'narrative': narrative})


def get_all_incidents(_params: dict) -> dict:
    """GET /incidents — all recent incidents across all accounts."""
    resp = i_tbl.scan(Limit=50)
    return _resp(200, {'incidents': resp.get('Items', [])})


def summarise_incident(params: dict) -> dict:
    """POST /incidents/{id}/summarise — on-demand Bedrock summarisation.
    Checks for cached summary first. Only calls Bedrock if none exists.
    Result written to DynamoDB and returned — subsequent calls are free.
    """
    incident_id = params.get('incidentId')
    if not incident_id:
        return _resp(400, {'error': 'incidentId required'})

    # Scan for incident
    try:
        resp = i_tbl.scan(
            FilterExpression=Attr('incidentId').eq(incident_id)
        )
        items = resp.get('Items', [])
        if not items:
            return _resp(404, {'error': 'Incident not found'})
        incident = items[0]
    except Exception as e:
        print(f'Incident lookup error: {type(e).__name__}: {e}')
        return _resp(500, {'error': f'Lookup failed: {e}'})

    # Return cached summary if it exists — no Bedrock call
    if incident.get('aiSummary'):
        return _resp(200, {
            'incidentId': incident_id,
            'aiSummary':  incident['aiSummary'],
            'cached':     True,
        })

    # No cached summary — call Bedrock
    account_id    = incident.get('accountId', 'unknown')
    incident_type = incident.get('incidentType', 'unknown')
    signal_count  = incident.get('signalCount', 0)
    signals       = incident.get('signals', [])[:5]
    blast         = incident.get('blastRadius', {})

    signal_lines = []
    for s in signals:
        sig_type = s.get('anomalyType', s.get('type', 'unknown'))
        desc     = s.get('description', s.get('message', s.get('signature', '')))[:120]
        sev      = s.get('severity', 'UNKNOWN')
        signal_lines.append(f'  [{sev}] {sig_type}: {desc}')

    directly_affected = blast.get('directlyAffected', [])[:3]
    blast_str = ', '.join(directly_affected) if directly_affected else 'unknown'

    prompt = f"""AWS incident detected. Provide a concise operational analysis.

Account: {account_id}
Type: {incident_type}
Total signals: {signal_count} (showing top {len(signal_lines)})
Blast radius: {blast_str}

Top signals:
{chr(10).join(signal_lines)}

Respond with ONLY this JSON (no markdown, no explanation):
{{
  "headline": "one sentence describing the incident",
  "probableCauses": ["primary cause in one sentence"],
  "investigationSteps": ["step 1", "step 2", "step 3"],
  "confidence": "HIGH|MEDIUM|LOW",
  "estimatedResolutionTime": "X-Y minutes",
  "runbookReference": {{"section": "relevant-runbook-section"}}
}}"""

    try:
        body = json.dumps({
            'anthropic_version': 'bedrock-2023-05-31',
            'max_tokens': 400,
            'messages': [{'role': 'user', 'content': prompt}],
        })
        resp = bedrock.invoke_model(
            modelId=BEDROCK_MODEL_ID,
            contentType='application/json',
            accept='application/json',
            body=body,
        )
        result = json.loads(resp['body'].read())
        raw    = result['content'][0]['text'].strip()
        if raw.startswith('```'):
            raw = raw.split('\n', 1)[1].rsplit('```', 1)[0].strip()
        summary = json.loads(raw)
    except Exception as e:
        print(f'Bedrock summarise error: {type(e).__name__}: {e}')
        return _resp(500, {'error': f'Bedrock call failed: {str(e)}'})

    # Cache the summary in DynamoDB
    try:
        i_tbl.update_item(
            Key={
                'incidentId': incident['incidentId'],
                'timestamp':  incident['timestamp'],
            },
            UpdateExpression='SET aiSummary = :s, summarisedAt = :t',
            ExpressionAttributeValues={
                ':s': summary,
                ':t': int(time.time() * 1000),
            },
        )
    except Exception as e:
        print(f'Failed to cache summary: {e}')

    return _resp(200, {
        'incidentId': incident_id,
        'aiSummary':  summary,
        'cached':     False,
    })


# ── ROUTER ─────────────────────────────────────────────────────────────────

def handler(event, _context):
    method = event.get('httpMethod', 'GET')
    path   = event.get('path', '/')

    # Strip API Gateway stage prefix (e.g. /poc/incidents -> /incidents)
    stage = event.get('requestContext', {}).get('stage', '')
    if stage and path.startswith(f'/{stage}'):
        path = path[len(f'/{stage}'):]
    if not path:
        path = '/'

    # CORS preflight
    if method == 'OPTIONS':
        return _resp(200, {})

    # Simple path parsing without complex regex
    path_parts = [p for p in path.strip('/').split('/') if p]
    params = {}

    try:
        # /accounts
        if path_parts == ['accounts'] and method == 'GET':
            return get_accounts(params)

        # /accounts/{id}/...
        if len(path_parts) >= 2 and path_parts[0] == 'accounts':
            params['accountId'] = path_parts[1]
            if len(path_parts) == 2 and method == 'GET':
                return get_accounts(params)
            if len(path_parts) == 3:
                sub = path_parts[2]
                if sub == 'topology':  return get_topology(params)
                if sub == 'anomalies': return get_anomalies(params)
                if sub == 'incidents': return get_incidents(params)
                if sub == 'explain':   return get_explain(params)

        # /incidents[/{id}]
        if len(path_parts) >= 1 and path_parts[0] == 'incidents':
            if len(path_parts) == 1 and method == 'GET':
                return get_all_incidents(params)
            if len(path_parts) == 2 and method == 'GET':
                params['incidentId'] = path_parts[1]
                return get_incident_detail(params)
            if len(path_parts) == 3 and path_parts[2] == 'summarise' and method == 'POST':
                params['incidentId'] = path_parts[1]
                return summarise_incident(params)

        return _resp(404, {'error': f'Route not found: {method} {path}'})

    except Exception as e:
        print(f'API handler error: {e}')
        return _resp(500, {'error': str(e)})
