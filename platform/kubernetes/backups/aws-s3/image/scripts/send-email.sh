#!/usr/bin/env bash
set -euo pipefail

: "${EMAIL_FROM:?missing EMAIL_FROM}"
: "${EMAIL_TO:?missing EMAIL_TO}"
: "${EMAIL_SUBJECT:?missing EMAIL_SUBJECT}"

EMAIL_FROM_NAME="${EMAIL_FROM_NAME:-}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"

# Compose a friendly "Name <email>" sender when name is provided.
if [[ -n "$EMAIL_FROM_NAME" ]]; then
  SOURCE="${EMAIL_FROM_NAME} <${EMAIL_FROM}>"
else
  SOURCE="${EMAIL_FROM}"
fi

BODY_FILE="${1:-/dev/stdin}"
BODY="$(cat "$BODY_FILE")"

# Use JSON input to properly escape body content with newlines and special chars
JSON_INPUT=$(jq -n \
  --arg from "$SOURCE" \
  --arg to "$EMAIL_TO" \
  --arg subject "$EMAIL_SUBJECT" \
  --arg body "$BODY" \
  '{
    Source: $from,
    Destination: { ToAddresses: [$to] },
    Message: {
      Subject: { Data: $subject, Charset: "utf-8" },
      Body: { Text: { Data: $body, Charset: "utf-8" } }
    }
  }')

aws --region "$AWS_REGION" ses send-email --cli-input-json "$JSON_INPUT"