# M71 — IAM Roles Anywhere for the headless mini.
#
# Trust anchor = the step-ca ROOT CA (reused PKI, M76). The mini presents a step-ca-issued
# leaf X.509 cert (CN = var.mini_cert_cn); aws_signing_helper exchanges it (via the profile)
# for short-lived STS creds against the role below — NO standing AWS key on the mini.
#
# ⚠️ This stack does NOT apply until the three owner-gated steps in
#    docs/planning/m71-roles-anywhere-plan.md are done (CI gets rolesanywhere:* perms;
#    the policy-scope/quota decision; mini-side cert setup). See that doc + ./README.md.

# ---- Trust anchor: trust certs chaining to the step-ca root -----------------------------
resource "aws_rolesanywhere_trust_anchor" "wind" {
  name    = "wind-homelab-step-ca"
  enabled = true

  source {
    source_type = "CERTIFICATE_BUNDLE"
    source_data {
      # step-ca root CA (public cert, committed). The mini's leaf is signed by step-ca's
      # intermediate; the client presents leaf+intermediate, RA validates up to this root.
      x509_certificate_data = file("${path.module}/${var.trust_anchor_cert_file}")
    }
  }
}

# ---- IAM role the mini assumes via RA ----------------------------------------------------
# Trust policy: only rolesanywhere.amazonaws.com, only via OUR trust anchor, only for a cert
# whose Subject CN == var.mini_cert_cn (RA surfaces cert fields as aws:PrincipalTag/x509*).
data "aws_iam_policy_document" "ra_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession", "sts:SetSourceIdentity"]

    principals {
      type        = "Service"
      identifiers = ["rolesanywhere.amazonaws.com"]
    }

    # Bind to OUR trust anchor (a cert from any other RA trust anchor in the account can't
    # assume this role).
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_rolesanywhere_trust_anchor.wind.arn]
    }

    # Bind to the mini's cert identity (Subject CN). Even a valid step-ca cert with a
    # different CN cannot assume this role. NB step-ca's `step ca certificate <CN>` sets
    # the Subject CN (and a matching SAN) to <CN>, so x509Subject/CN matches — confirm with
    # `openssl x509 -text` (if the host only lands in the SAN, use x509SAN/DNS instead).
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/x509Subject/CN"
      values   = [var.mini_cert_cn]
    }

    # Defense-in-depth: also require the issuer = our step-ca intermediate (so a different
    # sub-CA under the same root can't mint a CN-matching cert). Toggle via the var ("" = off).
    dynamic "condition" {
      for_each = var.mini_cert_issuer_cn != "" ? [1] : []
      content {
        test     = "StringEquals"
        variable = "aws:PrincipalTag/x509Issuer/CN"
        values   = [var.mini_cert_issuer_cn]
      }
    }
  }
}

resource "aws_iam_role" "mini_ra" {
  name                 = "wind-mini-roles-anywhere"
  description          = "M71: mini assumes this via IAM Roles Anywhere (step-ca cert) — replaces the standing [homelab] static key"
  assume_role_policy   = data.aws_iam_policy_document.ra_assume.json
  max_session_duration = var.session_duration_seconds
}

# Permissions = parity with terraform-homelab (or a curated subset — see variables.tf).
# ⚠️ If the list has >10 entries, raise the per-role managed-policy quota (L-0DA4ABF3) first.
resource "aws_iam_role_policy_attachment" "mini_ra" {
  for_each   = toset(var.attached_policy_names)
  role       = aws_iam_role.mini_ra.name
  policy_arn = "arn:aws:iam::${var.account_id}:policy/${each.value}"
}

# ---- RA profile: links the role, sets the session TTL -----------------------------------
resource "aws_rolesanywhere_profile" "mini" {
  name             = "wind-mini"
  enabled          = true
  role_arns        = [aws_iam_role.mini_ra.arn]
  duration_seconds = var.session_duration_seconds
}
