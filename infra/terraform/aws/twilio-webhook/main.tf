# Package Lambda code
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/lambda/handler.zip"
}

resource "aws_lambda_function" "twilio_webhook" {
  filename         = data.archive_file.lambda.output_path
  function_name    = "twilio-webhook"
  description      = "Handles Twilio voice + SMS webhooks: voice → Dial(forward); SMS → SES email"
  role             = aws_iam_role.lambda.arn
  handler          = "handler.lambda_handler"
  source_code_hash = data.archive_file.lambda.output_base64sha256
  runtime          = "python3.13"
  architectures    = ["arm64"]
  memory_size      = 256
  timeout          = 10

  environment {
    variables = {
      FORWARD_NUMBER    = var.forward_number
      EMAIL_TO          = var.email_to
      SES_FROM          = var.ses_from
      SES_REGION        = var.ses_region
      TWILIO_AUTH_TOKEN = var.twilio_auth_token
    }
  }

  depends_on = [
    aws_iam_role_policy.logs,
    aws_iam_role_policy.ses,
  ]
}

# CloudWatch Log Group with explicit retention (Lambda would auto-create
# at infinite retention otherwise).
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/twilio-webhook"
  retention_in_days = 30
}

# Function URL — public HTTPS endpoint that Twilio webhooks POST to.
# Auth: NONE (signature verification happens inside the Lambda via
# X-Twilio-Signature header, if TWILIO_AUTH_TOKEN is set).
resource "aws_lambda_function_url" "twilio_webhook" {
  function_name      = aws_lambda_function.twilio_webhook.function_name
  authorization_type = "NONE"

  cors {
    allow_origins = ["*"]
    allow_methods = ["POST"]
  }
}
