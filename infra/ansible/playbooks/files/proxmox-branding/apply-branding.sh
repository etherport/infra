#!/usr/bin/env bash
# Etherport branding for Proxmox VE — run as root on each PVE node.
# Re-run safe (idempotent). Installs an apt hook so branding survives
# pve-manager updates, which overwrite these files.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
PVE=/usr/share/pve-manager
STAMP="/usr/local/share/etherport-branding"

mkdir -p "$STAMP"
cp "$SRC_DIR/etherport-logo-proxmox.png" "$STAMP/"
cp "$SRC_DIR/etherport-logo-proxmox-light.png" "$STAMP/" 2>/dev/null || true
cp "$SRC_DIR/etherport-favicon.png" "$STAMP/"
cp "$SRC_DIR/etherport.css" "$STAMP/"

apply() {
  # 1. Logo (header + login dialog use the same file).
  #    Dark-only nodes: keep the dark asset + disable PVE's dark-theme image
  #    filter (rule in etherport.css). Mixed/light: copy the -light asset
  #    instead and let PVE's dark theme invert it.
  cp "$STAMP/etherport-logo-proxmox.png" "$PVE/images/proxmox_logo.png"
  # 2. Favicon
  cp "$STAMP/etherport-favicon.png" "$PVE/images/favicon.png" 2>/dev/null || true
  # 3. CSS: copy + inject <link> into the index template once
  cp "$STAMP/etherport.css" "$PVE/css/etherport.css"
  local TPL="$PVE/index.html.tpl"
  if ! grep -q etherport.css "$TPL"; then
    sed -i 's|</head>|  <link rel="stylesheet" type="text/css" href="/pve2/css/etherport.css">\n</head>|' "$TPL"
  fi
  echo "etherport branding applied."
}

# 4. Apt hook: re-apply after any dpkg run touching pve-manager
HOOK=/etc/apt/apt.conf.d/99-etherport-branding
if [ ! -f "$HOOK" ]; then
  cat > "$HOOK" <<EOF
DPkg::Post-Invoke { "if [ -x $STAMP/apply-branding.sh ]; then $STAMP/apply-branding.sh --apply-only || true; fi"; };
EOF
fi
cp "$0" "$STAMP/apply-branding.sh"
chmod +x "$STAMP/apply-branding.sh"

apply
echo "Done. Hard-refresh the web UI (Ctrl+Shift+R)."
