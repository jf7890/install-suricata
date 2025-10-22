#!/usr/bin/env bash
# ================================================================
#  Suricata Auto Installer & Configurator (IPS Mode by default)
#  Yêu cầu: File ./suricata.env nằm cùng thư mục
# ================================================================

# [CHANGED] Khắt khe hơn để tránh lỗi âm thầm
set -Eeuo pipefail

# ---------- Helpers ----------
die() { echo "[-] $*" >&2; exit 1; }
bak() { local f="$1"; [[ -f "$f" ]] && cp -a "$f" "$f.bak.$(date +%s)" || true; }

# [NEW] Xóa đúng block YAML top-level theo key (vd: 'af-packet:')
remove_yaml_block() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || die "Missing $file"
  awk -v key="$key" '
    BEGIN{inblk=0}
    # bắt đầu block khi khớp top-level: ^key:
    $0 ~ "^[[:space:]]*"key":" && match($0, "^[^[:space:]]") { inblk=1; next }
    # kết thúc block khi gặp key top-level khác
    inblk && match($0, "^[A-Za-z0-9_-]+:") { inblk=0 }
    !inblk { print }
  ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# [NEW] Đảm bảo (re)build block rule-files + default-rule-path
ensure_rulefiles_block() {
  local file="$1"
  [[ -f "$file" ]] || die "Missing $file"
  bak "$file"

  # Xóa toàn bộ block rule-files nếu có
  awk '
    BEGIN{inblk=0}
    /^rule-files:/ && match($0, "^[^[:space:]]") { inblk=1; next }
    inblk && /^[^[:space:]]/ { inblk=0 }
    !inblk { print }
  ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"

  # Đặt default-rule-path
  if grep -q '^default-rule-path:' "$file"; then
    sed -i 's#^default-rule-path:.*#default-rule-path: /var/lib/suricata/rules#' "$file"
  else
    # thêm cuối file (an toàn vì YAML thứ tự top-level không bắt buộc)
    echo 'default-rule-path: /var/lib/suricata/rules' >> "$file"
  fi

  # Thêm block rule-files chuẩn
  cat >> "$file" <<'EOF'
rule-files:
  - suricata.rules
  - /etc/suricata/rules/local.rules
EOF
}

# [NEW] Reset về file mẫu chuẩn của package nếu file hiện tại lỗi/thiếu phần quan trọng
reset_config_from_template_if_needed() {
  local file="/etc/suricata/suricata.yaml"
  if [[ ! -f "$file" ]] || ! grep -q '^rule-files:' "$file"; then
    echo "[!] Config missing or malformed. Restoring from package template..."
    local tmpl=""
    for c in /usr/share/suricata/config/suricata.yaml /usr/share/doc/suricata/examples/suricata.yaml; do
      [[ -f "$c" ]] && tmpl="$c" && break
    done
    [[ -n "$tmpl" ]] || die "Cannot find suricata.yaml template in package."
    install -m 0640 -o root -g suricata "$tmpl" "$file"
  fi
}

# ---------- 0. KIỂM TRA QUYỀN ROOT ----------
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Script cần quyền root. Hãy chạy: sudo bash install-suricata.sh"
  exit 1
fi

# ---------- 1. GỠ SURICATA HOÀN TOÀN ----------
echo "[+] Removing any existing Suricata..."
if command -v suricata >/dev/null 2>&1; then
  systemctl stop suricata 2>/dev/null || true
  systemctl disable suricata 2>/dev/null || true
fi
systemctl daemon-reload || true
apt purge -y suricata suricata-update 2>/dev/null || true
apt autoremove --purge -y || true
apt autoclean -y || true

if [[ -d "/usr/local/src/suricata" ]]; then
  echo "[+] Removing source-built Suricata..."
  make uninstall -C /usr/local/src/suricata 2>/dev/null || true
fi
rm -rf /usr/local/bin/suricata* /usr/local/lib/libhtp* 2>/dev/null || true
ldconfig || true
rm -rf /etc/suricata /var/lib/suricata /var/log/suricata /usr/local/etc/suricata /etc/default/suricata 2>/dev/null || true
rm -rf /usr/local/src/suricata* ~/suricata* ~/Downloads/suricata* 2>/dev/null || true
echo "[✓] Cleanup done."

# ---------- 2. TẢI FILE ENV ----------
ENV_FILE="./suricata.env"
[[ -f "$ENV_FILE" ]] || die "Không tìm thấy $ENV_FILE"
# shellcheck disable=SC1090
source "$ENV_FILE"
echo "[OK] Loaded env from $ENV_FILE"

CURRENT_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
echo "[INFO] Will set permissions for user: $CURRENT_USER"

# ---------- 3. CÀI SURICATA & CÔNG CỤ ----------
UBUNTU_VERSION="$(lsb_release -rs | cut -d'.' -f1)"
echo "[INFO] Ubuntu major version: $UBUNTU_VERSION"

apt update -y
# [CHANGED] Cài suricata-update cho mọi version
if [[ "$UBUNTU_VERSION" -ge 24 ]]; then
  echo "[INFO] Installing from Ubuntu repo..."
  apt install -y suricata suricata-update jq
else
  echo "[INFO] Enabling OISF PPA for stable Suricata..."
  apt install -y software-properties-common
  add-apt-repository -y ppa:oisf/suricata-stable
  apt update -y
  apt install -y suricata suricata-update jq
fi

# Đảm bảo user/group tồn tại & thư mục
id -u suricata &>/dev/null || adduser --system --group --no-create-home suricata
install -d -o suricata -g suricata -m 0750 /etc/suricata /var/log/suricata /var/lib/suricata

# ---------- 4. TẠO local.rules ----------
if [[ "${ENABLE_LOCAL_RULES:-yes}" == "yes" ]]; then
  echo "[+] Creating /etc/suricata/rules/local.rules..."
  install -d -o root -g suricata -m 0750 /etc/suricata/rules
  cat > /etc/suricata/rules/local.rules <<'EOF'
alert icmp any any -> any any (msg:"LOCAL ICMP DETECTED"; sid:1000001; rev:1;)
EOF
  chgrp suricata /etc/suricata/rules/local.rules
  chmod 0640 /etc/suricata/rules/local.rules
fi

# ---------- 5. UPDATE RULESETS ----------
echo "[+] Updating sources & rules with suricata-update..."
suricata-update update-sources || true
if [[ "${RULESET:-emerging-threats}" == "emerging-threats" ]]; then
  suricata-update enable-source et/open || true
fi
suricata-update --no-test || true

# ---------- 6. ÁP DỤNG CUSTOM CONFIG ----------
echo "[+] Applying customizations to /etc/suricata/suricata.yaml ..."
reset_config_from_template_if_needed

# [CHANGED] Xóa bittorrent-dht an toàn theo phạm vi
# (chỉ xóa dòng có "- bittorrent-dht" ở bất kỳ indentation)
sed -i -E '/^[[:space:]]*-[[:space:]]*bittorrent-dht[[:space:]]*$/d' /etc/suricata/suricata.yaml

# [CHANGED] HOME_NET: dùng NETWORK_CIDR nếu bật, theo kiểu chuỗi "[10.10.100.0/24]"
if [[ "${HOME_NET_USE_ENV:-yes}" == "yes" ]]; then
  HOME_NET_VALUE="[${NETWORK_CIDR}]"
else
  HOME_NET_VALUE="any"
fi
# thay đúng dòng HOME_NET top-level trong vars.address-groups
sed -i -E 's#^([[:space:]]*HOME_NET:[[:space:]]*).*$#\1"'"$HOME_NET_VALUE"'"#' /etc/suricata/suricata.yaml || true

# [NEW] Bảo đảm block rule-files tồn tại & có local.rules
ensure_rulefiles_block "/etc/suricata/suricata.yaml"

# [CHANGED] Thiết lập IPS với AF-PACKET nhưng không cắt đuôi file
if [[ "${MODE:-IPS}" == "IPS" && "${ENABLE_AF_PACKET:-yes}" == "yes" ]]; then
  echo "[+] Configuring AF-PACKET inline (IPS)..."

  # Kiểm tra tồn tại interface
  ip link show "$WAN_IFACE" >/dev/null 2>&1 || die "WAN_IFACE $WAN_IFACE not found"
  ip link show "$LAN_IFACE" >/dev/null 2>&1 || die "LAN_IFACE $LAN_IFACE not found"

  bak /etc/suricata/suricata.yaml
  remove_yaml_block "/etc/suricata/suricata.yaml" "af-packet"

  cat >> /etc/suricata/suricata.yaml <<EOF

af-packet:
  - interface: ${WAN_IFACE}
    cluster-id: 99
    cluster-type: cluster_flow
    defrag: yes
    copy-mode: ips
    copy-iface: ${LAN_IFACE}
  - interface: ${LAN_IFACE}
    cluster-id: 98
    cluster-type: cluster_flow
    defrag: yes
    copy-mode: ips
    copy-iface: ${WAN_IFACE}
EOF
fi

# ---------- 7. /etc/default/suricata để tránh ép '-i $IFACE' ----------
# [NEW] Ngăn xung đột giữa systemd ExecStart và cấu hình af-packet trong YAML
echo "[+] Adjusting /etc/default/suricata ..."
cat > /etc/default/suricata <<'EOF'
# Managed by install-suricata.sh
RUN=yes
LISTENMODE="af-packet"
IFACE=""
# Leave other options empty to let suricata.yaml drive the setup
EOF
chmod 0644 /etc/default/suricata

# ---------- 8. QUYỀN THƯ MỤC ----------
echo "[+] Fixing permissions..."
chown -R suricata:suricata /var/log/suricata /var/lib/suricata
chgrp -R suricata /etc/suricata
chmod -R 750 /etc/suricata /var/log/suricata /var/lib/suricata
chmod 640 /etc/suricata/*.yaml || true

# ---------- 9. KHỞI ĐỘNG & KIỂM TRA ----------
echo "[+] Testing configuration..."
suricata -T -c /etc/suricata/suricata.yaml

echo "[+] Enabling & restarting service..."
systemctl daemon-reload
systemctl enable suricata
systemctl restart suricata

# ---------- 10. THÔNG TIN ----------
echo "[Hoàn tất] Suricata đã được cài & chạy."
echo "=========================================="
echo "Interface WAN: ${WAN_IFACE}"
echo "Interface LAN: ${LAN_IFACE}"
echo "HOME_NET: ${HOME_NET_VALUE}"
echo "Ruleset: ${RULESET}"
echo "Log: /var/log/suricata/eve.json"
echo "=========================================="
echo "Theo dõi log:"
echo "  sudo tail -f /var/log/suricata/eve.json"
echo "Kiểm tra service:"
echo "  sudo systemctl status suricata"
echo "=========================================="
echo "[DONE] Hệ thống sẵn sàng IPS (AF-PACKET inline)."
