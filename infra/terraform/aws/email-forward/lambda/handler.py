import os
import boto3
import email
import re
from urllib.parse import unquote_plus

# Initialize AWS clients
s3_client = boto3.client('s3')
ses_client = boto3.client('ses')

# Environment variables (set these in your Lambda configuration)
VERIFIED_SENDER = os.environ.get('VERIFIED_SENDER', 'g@grahamsmith.net')
GRAHAM_FORWARD_TO = os.environ.get('GRAHAM_FORWARD_TO', 'grahamsm@gmail.com')
MARK_FORWARD_TO = os.environ.get('MARK_FORWARD_TO', 'mgoodwin.us@gmail.com')

def lambda_handler(event, context):
    print("VERIFIED_SENDER:", VERIFIED_SENDER)
    print("GRAHAM_FORWARD_TO:", GRAHAM_FORWARD_TO)
    print("MARK_FORWARD_TO:", MARK_FORWARD_TO)
    print("Received event:", event)

    # Extract S3 bucket name and object key from the event
    try:
        record = event['Records'][0]
        s3_bucket_name = record['s3']['bucket']['name']
        s3_object_key = unquote_plus(record['s3']['object']['key'])
        print("S3 bucket:", s3_bucket_name)
        print("S3 object key:", s3_object_key)
    except KeyError as e:
        print("Error parsing S3 event:", e)
        raise e

    # Determine the forwarding recipient based on the object key prefix
    if s3_object_key.startswith('emails/graham/'):
        forward_to = GRAHAM_FORWARD_TO
    elif s3_object_key.startswith('emails/mark/'):
        forward_to = MARK_FORWARD_TO
    else:
        print("No matching prefix found. Skipping forwarding.")
        return {
            'statusCode': 200,
            'body': 'No forwarding rule for this email.'
        }

    # Fetch the raw email from S3
    try:
        s3_response = s3_client.get_object(Bucket=s3_bucket_name, Key=s3_object_key)
        raw_email = s3_response['Body'].read().decode('utf-8')
    except Exception as e:
        print("Error fetching email from S3:", e)
        raise e

    # Parse the raw email message
    msg = email.message_from_string(raw_email)

    # Debug: Print original headers
    print("Original headers:")
    for header, value in msg.items():
        print(f"{header}: {value}")

    # Save the original "From" header for Reply-To
    original_from = msg.get('From')

    # Remove headers that might cause SES to reject the message
    # Including DKIM signatures (SES will add its own) and other problematic headers
    headers_to_remove = [
        'From', 'Sender', 'Return-Path',
        'DKIM-Signature', 'X-SES-DKIM-SIGNATURE',
        'X-Google-DKIM-Signature', 'ARC-Seal', 'ARC-Message-Signature',
        'ARC-Authentication-Results'
    ]
    for header in headers_to_remove:
        # Remove all instances of each header (some may appear multiple times)
        while header in msg:
            del msg[header]

    # Set the From header to the verified sender and add a Reply-To header
    msg['From'] = VERIFIED_SENDER
    if original_from:
        msg['Reply-To'] = original_from

    # Debug: Print modified headers
    print("Modified headers:")
    for header, value in msg.items():
        print(f"{header}: {value}")

    # Convert the modified message back to a string
    modified_raw_email = msg.as_string()

    # --- Extra Step: Replace any lingering unverified address in the header section ---
    # Try to detect the header/body separator (accounting for CRLF)
    header_sep = None
    if "\r\n\r\n" in modified_raw_email:
        header_sep = "\r\n\r\n"
    elif "\n\n" in modified_raw_email:
        header_sep = "\n\n"

    if header_sep:
        header_section, body = modified_raw_email.split(header_sep, 1)
        # Perform a case-insensitive replacement of the unverified address in the header section
        header_section = re.sub(r'graham\.m\.smith@me\.com', VERIFIED_SENDER, header_section, flags=re.IGNORECASE)
        modified_raw_email = header_section + header_sep + body
    else:
        # If no separator is found, replace globally (less ideal if the body might contain the text)
        modified_raw_email = re.sub(r'graham\.m\.smith@me\.com', VERIFIED_SENDER, modified_raw_email, flags=re.IGNORECASE)
    # --- End Extra Step ---

    # Debug: Log the final header portion
    final_sep = "\r\n\r\n" if "\r\n\r\n" in modified_raw_email else "\n\n"
    final_header = modified_raw_email.split(final_sep, 1)[0] if final_sep else modified_raw_email
    print("Final email headers:")
    print(final_header)

    # Forward the email using SES
    try:
        response = ses_client.send_raw_email(
            Source=VERIFIED_SENDER,  # must be a verified email in SES
            Destinations=[forward_to],
            RawMessage={'Data': modified_raw_email}
        )
        print("Email forwarded! Message ID:", response['MessageId'])
    except Exception as e:
        print("Error forwarding email:", e)
        raise e

    return {
        'statusCode': 200,
        'body': 'Email processed and forwarded successfully.'
    }
