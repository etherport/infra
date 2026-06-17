terraform {
  required_version = ">= 1.14"
  required_providers {
    twilio = {
      source  = "twilio/twilio"
      version = "~> 0.9"
    }
  }
}

# Twilio provider: Account SID + API Key/Secret (preferred over Auth Token —
# API keys are scoped + rotatable; Auth Token is the master). Env vars
# (exact names the twilio/twilio provider reads):
#   TWILIO_ACCOUNT_SID   (AC…)
#   TWILIO_API_KEY       (SK… — the API Key SID)
#   TWILIO_API_SECRET    (the API Key secret)
#
# Create API Key one-time in console:
#   console.twilio.com → Account → API keys & tokens → Create API key
#     → Standard scope (sufficient for IaC)
#     → save SID + Secret to 1P item "twilio-tf-token":
#         username    = SK... (API Key SID)
#         credential  = the secret (Concealed)
#         account_sid = AC... (Account SID, find on console homepage —
#                       distinct from API Key SID!)
provider "twilio" {}
