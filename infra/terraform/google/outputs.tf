// Sensitive output: the Places API (New) key material for Cue Find-food.
//
// Delivered to the app OUT OF BAND (the repo has no automated TF->SOPS bridge, by
// design — Flux owns the cluster, secrets live SOPS-encrypted in git). After apply:
//
//   KEY=$(terraform -chdir=infra/terraform/google output -raw cue_places_key)
//   sops set platform/kubernetes/cue-api/03-secret-app.sops.yaml \
//     '["stringData"]["CUE_GOOGLE_PLACES_KEY"]' "\"$KEY\""
//
// envFrom secretRef: cue-app then injects it into the pod (no Deployment edit).
output "cue_places_key" {
  description = "Google Places API (New) restricted API key for Cue Find-food (-> CUE_GOOGLE_PLACES_KEY)"
  value       = google_apikeys_key.cue_places.key_string
  sensitive   = true
}
