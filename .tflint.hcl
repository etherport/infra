# tflint config for homelab-infra.
# Minimal + offline: the built-in `terraform` ruleset only (no cloud plugins,
# so the pre-commit hook needs no provider creds or `tflint --init`). Catches
# unused declarations, naming conventions, deprecated syntax, missing versions.
# Tune / add the aws ruleset plugin later (tracked: outstanding-work.md M61).

config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
