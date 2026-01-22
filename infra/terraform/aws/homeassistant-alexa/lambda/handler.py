import os
import json
import logging
import urllib3
import boto3
from botocore.exceptions import ClientError

_debug = bool(os.environ.get('DEBUG'))

_logger = logging.getLogger('HomeAssistant-SmartHome')
_logger.setLevel(logging.DEBUG if _debug else logging.INFO)

# Cache for secrets
_cached_token = None


def get_access_token():
    """Retrieve the Home Assistant access token from Secrets Manager."""
    global _cached_token
    if _cached_token is not None:
        return _cached_token

    secret_name = os.environ.get('SECRET_NAME')
    if not secret_name:
        raise ValueError("SECRET_NAME environment variable not set")

    region = os.environ.get('AWS_REGION', 'us-east-1')
    client = boto3.client('secretsmanager', region_name=region)

    try:
        response = client.get_secret_value(SecretId=secret_name)
        secret = json.loads(response['SecretString'])
        _cached_token = secret.get('access_token')
        if not _cached_token:
            raise ValueError("access_token not found in secret")
        return _cached_token
    except ClientError as e:
        _logger.error(f"Error retrieving secret: {e}")
        raise


def lambda_handler(event, context):
    """Handle incoming Alexa directive."""

    _logger.debug('Event: %s', event)

    base_url = os.environ.get('BASE_URL')
    assert base_url is not None, 'Please set BASE_URL environment variable'
    base_url = base_url.strip("/")

    directive = event.get('directive')
    assert directive is not None, 'Malformatted request - missing directive'
    assert directive.get('header', {}).get('payloadVersion') == '3', \
        'Only support payloadVersion == 3'

    scope = directive.get('endpoint', {}).get('scope')
    if scope is None:
        # token is in grantee for Linking directive
        scope = directive.get('payload', {}).get('grantee')
    if scope is None:
        # token is in payload for Discovery directive
        scope = directive.get('payload', {}).get('scope')
    assert scope is not None, 'Malformatted request - missing endpoint.scope'
    assert scope.get('type') == 'BearerToken', 'Only support BearerToken'

    token = scope.get('token')
    if token is None and _debug:
        # In debug mode, use the token from Secrets Manager
        token = get_access_token()

    verify_ssl = not bool(os.environ.get('NOT_VERIFY_SSL'))

    http = urllib3.PoolManager(
        cert_reqs='CERT_REQUIRED' if verify_ssl else 'CERT_NONE',
        timeout=urllib3.Timeout(connect=2.0, read=10.0)
    )

    response = http.request(
        'POST',
        '{}/api/alexa/smart_home'.format(base_url),
        headers={
            'Authorization': 'Bearer {}'.format(token),
            'Content-Type': 'application/json',
        },
        body=json.dumps(event).encode('utf-8'),
    )
    if response.status >= 400:
        return {
            'event': {
                'payload': {
                    'type': 'INVALID_AUTHORIZATION_CREDENTIAL'
                            if response.status in (401, 403) else 'INTERNAL_ERROR',
                    'message': response.data.decode("utf-8"),
                }
            }
        }
    _logger.debug('Response: %s', response.data.decode("utf-8"))
    return json.loads(response.data.decode('utf-8'))
