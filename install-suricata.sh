#!/usr/bin/env bash
# ================================================================
#  Suricata Auto Installer & Configurator (IPS Mode by default)
#  Yêu cầu: File ./suricata.env nằm cùng thư mục
# ================================================================

set -e

# --- 0. KIỂM TRA QUYỀN ROOT ---
if [ "$EUID" -ne 0 ]; then
  echo "Script cần quyền root. Hãy chạy bằng: sudo bash install_suricata.sh"
  exit 1
fi

# --- 1. GỠ SURICATA HOÀN TOÀN ---
echo "[+] Checking and completely removing any existing Suricata installations..."
if command -v suricata >/dev/null 2>&1; then
  echo "[!] Suricata detected! Proceeding with full cleanup..."
  systemctl stop suricata 2>/dev/null || true
  systemctl disable suricata 2>/dev/null || true
  systemctl daemon-reload
  apt purge -y suricata suricata-update || true
  apt autoremove --purge -y || true
  apt autoclean || true
  if [ -d "/usr/local/src/suricata" ]; then
    echo "[+] Removing Suricata installed from source..."
    make uninstall -C /usr/local/src/suricata 2>/dev/null || true
  fi
  rm -rf /usr/local/bin/suricata* /usr/local/bin/suri* 2>/dev/null
  rm -rf /usr/local/lib/libhtp* 2>/dev/null
  ldconfig
  rm -rf /etc/suricata \
         /var/lib/suricata \
         /var/log/suricata \
         /usr/local/etc/suricata \
         /etc/default/suricata
  rm -rf /usr/local/src/suricata* ~/suricata* ~/Downloads/suricata* 2>/dev/null
  echo "[✓] All Suricata files, services, and configurations have been removed."
else
  echo "[+] No Suricata installation found. Proceeding..."
fi
if command -v suricata >/dev/null 2>&1; then
  echo "[✗] Suricata still detected! Please check manually."
else
  echo "[✓] Suricata removal confirmed. System is clean."
fi
echo "[DONE] Ready for fresh installation."


# --- 2. TẢI FILE ENV ---
ENV_FILE="./suricata.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "Không tìm thấy file $ENV_FILE. Hãy tạo file trước."
  exit 1
fi
source "$ENV_FILE"
echo "[OK] Đã load file môi trường: $ENV_FILE"

CURRENT_USER=$(logname)
echo "[INFO] User đang chạy (sẽ được gán quyền): $CURRENT_USER"

# --- 3. CÀI ĐẶT SURICATA VÀ CÁC CÔNG CỤ ---
UBUNTU_VERSION=$(lsb_release -rs | cut -d'.' -f1)
echo "[INFO] Detected Ubuntu version: $UBUNTU_VERSION"
if [ "$UBUNTU_VERSION" -ge 24 ]; then
  echo "[INFO] Using official Ubuntu repository (no PPA needed)"
  apt update -y
  apt install -y suricata jq
else
  echo "[INFO] Using OISF PPA repository for Suricata"
  apt update -y
  apt install -y software-properties-common
  add-apt-repository ppa:oisf/suricata-stable -y
  apt update -y
  apt install -y suricata suricata-update jq
fi

# --- 4. TẠO FILE LOCAL RULES TRỐNG ---
if [ "$ENABLE_LOCAL_RULES" = "yes" ]; then
  echo "[+] Creating local.rules file..."
  mkdir -p /etc/suricata/rules
  touch /etc/suricata/rules/local.rules
  echo '[local] alert icmp any any -> any any (msg:"LOCAL ICMP DETECTED"; sid:1000001; rev:1;)' > /etc/suricata/rules/local.rules
fi

# --- 5. CHẠY SURICATA-UPDATE TRƯỚC TIÊN ---
echo "[+] Updating rulesets with suricata-update..."
suricata-update update-sources
if [ "$RULESET" = "emerging-threats" ]; then
  suricata-update enable-source et/open
fi
suricata-update --no-test # Chạy update nhưng không test

# --- 6. ÁP DỤNG CÁC CẤU HÌNH TÙY CHỈNH (SAU KHI UPDATE) ---
echo "[+] Applying custom configurations to suricata.yaml..."

# Sửa lỗi config mặc định (bittorrent-dht)
echo "[FIX] Removing problematic 'bittorrent-dht' from default config..."
sed -i '/- bittorrent-dht/d' /etc/suricata/suricata.yaml

# Cấu hình HOME_NET
if [ "$HOME_NET_USE_ENV" = "yes" ]; then
  HOME_NET_VALUE="$NETWORK_CIDR"
else
  HOME_NET_VALUE="any"
fi
sed -i "s|HOME_NET:.*|HOME_NET: \"$HOME_NET_VALUE\"|g" /etc/suricata/suricata.yaml

# Kích hoạt local.rules
if [ "$ENABLE_LOCAL_RULES" = "yes" ]; then
  if ! grep -q "/etc/suricata/rules/local.rules" /etc/suricata/suricata.yaml; then
    echo "[+] Adding local.rules to suricata.yaml..."
    sed -i "/- suricata.rules/a \ \ - /etc/suricata/rules/local.rules" /etc/suricata/suricata.yaml
  fi
fi

# Cấu hình IPS Mode (AF-PACKET)
if [ "$MODE" = "IPS" ] && [ "$ENABLE_AF_PACKET" = "yes" ]; then
  echo "[+] Configuring IPS mode (AF-PACKET)..."
  AF_PACKET_CONFIG="
af-packet:
  - interface: $WAN_IFACE
    cluster-id: 99
    cluster-type: cluster_flow
    defrag: yes
    copy-mode: ips
    copy-iface: $LAN_IFACE
  - interface: $LAN_IFACE
    cluster-id: 98
    cluster-type: cluster_flow
    defrag: yes
    copy-mode: ips
    copy-iface: $WAN_IFACE
"
  if grep -q "^af-packet:" /etc/suricata/suricata.yaml; then
    sed -i '/^af-packet:/,$d' /etc/suricata/suricata.yaml
  fi
  echo "$AF_PACKET_CONFIG" >> /etc/suricata/suricata.yaml
fi


# --- 7. GÁN QUYỀN USER ---
echo "[+] Setting permissions..."
chown -R suricata:suricata /etc/suricata /var/log/suricata /var/lib/suricata
chmod -R 750 /etc/suricata /var/log/suricata /var/lib/suricata

# --- 8. KHỞI ĐỘNG VÀ KIỂM TRA ---
echo "[+] Starting and testing Suricata..."
# Test lại lần cuối sau khi đã cấu hình xong
suricata -T

# Khởi động dịch vụ
systemctl enable suricata
systemctl restart suricata

# --- 9. HIỂN THỊ THÔNG TIN ---
echo "[Hoàn tất] Suricata đã được cài đặt và chạy."
echo "=========================================="
echo "Interface WAN: $WAN_IFACE"
echo "Interface LAN: $LAN_IFACE"
echo "HOME_NET: $HOME_NET_VALUE"
echo "Ruleset đã kích hoạt: $RULESET"
echo "Log file: /var/log/suricata/eve.json"
echo "=========================================="
echo "Lệnh kiểm tra log:"
echo "  sudo tail -f /var/log/suricata/eve.json"
echo "Lệnh kiểm tra service:"
echo "  sudo systemctl status suricata"
echo "=========================================="
echo "[DONE] Hệ thống đã sẵn sàng giám sát & chặn tấn công (IPS mode)."