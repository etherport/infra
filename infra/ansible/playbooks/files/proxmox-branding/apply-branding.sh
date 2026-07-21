#!/usr/bin/env bash
# Etherport branding for Proxmox VE — run as root on each PVE node.
# Re-run safe (idempotent). Installs an apt hook so branding survives
# pve-manager updates, which overwrite these files.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
PVE=/usr/share/pve-manager
STAMP="/usr/local/share/etherport-branding"

mkdir -p "$STAMP"
# copy source assets to the stamp dir (unless already running from it)
if [ "$SRC_DIR" != "$STAMP" ]; then
  cp "$SRC_DIR/etherport-logo-proxmox.png" "$STAMP/"
  cp "$SRC_DIR/etherport-logo-proxmox-light.png" "$STAMP/" 2>/dev/null || true
  cp "$SRC_DIR/etherport-favicon.png" "$STAMP/"
  cp "$SRC_DIR/etherport-logo.svg" "$STAMP/" 2>/dev/null || true
  cp "$SRC_DIR/etherport.css" "$STAMP/"
fi

apply() {
  # 1. Header logo. ⚠️ PVE 9's masthead uses `proxmoxLogoSvg` with `prefix: 'pwt'`,
  #    so the HEADER logo loads from /pwt/images/proxmox_logo.svg =
  #    proxmox-widget-toolkit's copy — NOT pve-manager's. Replace ALL of them:
  #    the widget-toolkit SVG (header), the pve-manager SVG (login/other), + the
  #    PNG (PVE 8). The 99-etherport-branding apt Post-Invoke re-applies after any
  #    dpkg run, so widget-toolkit upgrades don't revert it.
  cp "$STAMP/etherport-logo.svg" /usr/share/javascript/proxmox-widget-toolkit/images/proxmox_logo.svg 2>/dev/null || true
  cp "$STAMP/etherport-logo.svg" "$PVE/images/proxmox_logo.svg" 2>/dev/null || true
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
