terraform {
  required_version = ">= 1.0"
  required_providers {
    twilio = {
      source  = "twilio/twilio"
      version = "~> 0.34"
    }
  }
}

# Twilio provider: Account SID + API Key/Secret (preferred over Auth Token —
# API keys are scoped + rotatable; Auth Token is the master). Env vars:
#   TWILIO_ACCOUNT_SID
#   TWILIO_API_KEY_SID
#   TWILIO_API_KEY_SECRET
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
