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

# --- 1. GỠ SURICATA HOÀN TOÀN (APT + SOURCE + FILE THỦ CÔNG) ---
echo "[+] Checking and completely removing any existing Suricata installations..."

if command -v suricata >/dev/null 2>&1; then
  echo "[!] Suricata detected! Proceeding with full cleanup..."

  # Stop & disable service
  systemctl stop suricata 2>/dev/null || true
  systemctl disable suricata 2>/dev/null || true
  systemctl daemon-reload

  # Remove APT packages
  apt purge -y suricata suricata-update || true
  apt autoremove --purge -y || true
  apt autoclean || true

  # Remove source-based installation (if exists)
  # Try to uninstall via make if source directory exists
  if [ -d "/usr/local/src/suricata" ]; then
    echo "[+] Removing Suricata installed from source..."
    make uninstall -C /usr/local/src/suricata 2>/dev/null || true
  fi

  # Remove binary and libraries from local
  rm -rf /usr/local/bin/suricata* /usr/local/bin/suri* 2>/dev/null
  rm -rf /usr/local/lib/libhtp* 2>/dev/null
  ldconfig

  # Remove configuration, logs, and rules
  rm -rf /etc/suricata \
         /var/lib/suricata \
         /var/log/suricata \
         /usr/local/etc/suricata \
         /etc/default/suricata

  # Remove any remaining source directories
  rm -rf /usr/local/src/suricata* ~/suricata* ~/Downloads/suricata* 2>/dev/null

  echo "[✓] All Suricata files, services, and configurations have been removed."
else
  echo "[+] No Suricata installation found. Proceeding..."
fi

# Final check
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

# --- 3. CẬP NHẬT HỆ THỐNG VÀ CÀI SURICATA ---
UBUNTU_VERSION=$(lsb_release -rs | cut -d'.' -f1)

echo "[INFO] Detected Ubuntu version: $UBUNTU_VERSION"

# Decide installation path
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

# --- 4. TẠO LOCAL RULES ---
if [ "$ENABLE_LOCAL_RULES" = "yes" ]; then
  echo "[Bước 2] Tạo file local.rules nếu chưa có..."
  mkdir -p /etc/suricata/rules
  touch /etc/suricata/rules/local.rules
  echo '[local] alert icmp any any -> any any (msg:"LOCAL ICMP DETECTED"; sid:1000001; rev:1;)' > /etc/suricata/rules/local.rules
fi

# --- 5. CẤU HÌNH HOME_NET ---
echo "[Bước 3] Cấu hình HOME_NET..."
if [ "$HOME_NET_USE_ENV" = "yes" ]; then
  HOME_NET_VALUE="$NETWORK_CIDR"
else
  HOME_NET_VALUE="any"
fi

sed -i "s|HOME_NET:.*|HOME_NET: \"$HOME_NET_VALUE\"|g" /etc/suricata/suricata.yaml

# --- 6. KÍCH HOẠT LOCAL RULES TRONG YAML (ĐÃ SỬA CHO SURICATA 7+) ---
if [ "$ENABLE_LOCAL_RULES" = "yes" ]; then
  # Kiểm tra xem dòng đã tồn tại chưa để tránh thêm nhiều lần
  if ! grep -q "/etc/suricata/rules/local.rules" /etc/suricata/suricata.yaml; then
    echo "[+] Adding local.rules to suricata.yaml..."
    # Thêm đường dẫn đầy đủ của local.rules vào sau dòng "- suricata.rules"
    sed -i "/- suricata.rules/a \ \ - /etc/suricata/rules/local.rules" /etc/suricata/suricata.yaml
  fi
fi

# --- 7. CẤU HÌNH IPS MODE VÀ AF-PACKET (ĐÃ SỬA) ---
if [ "$MODE" = "IPS" ] && [ "$ENABLE_AF_PACKET" = "yes" ]; then
  echo "[Bước 4] Cấu hình Suricata chế độ IPS inline (AF-PACKET)..."
  
  # Tạo khối cấu hình af-packet đúng và đối xứng
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
    copy-mode: ips      # <-- ĐÃ THÊM
    copy-iface: $WAN_IFACE  # <-- ĐÃ THÊM
"
  # Tìm và thay thế toàn bộ khối af-packet trong suricata.yaml
  # Bằng cách này, chúng ta không cần dùng file tạm và sed nhiều lần
  if grep -q "^af-packet:" /etc/suricata/suricata.yaml; then
    # Xóa khối cũ nếu nó tồn tại
    sed -i '/^af-packet:/,$d' /etc/suricata/suricata.yaml
  fi
  # Nối khối mới vào cuối file
  echo "$AF_PACKET_CONFIG" >> /etc/suricata/suricata.yaml
fi

# --- 8. CẬP NHẬT RULES ---
echo "[Bước 5] Cập nhật rules mới nhất từ Emerging Threats..."
suricata-update update-sources
if [ "$RULESET" = "emerging-threats" ]; then
  suricata-update enable-source et/open
fi
suricata-update
suricata-update list-enabled-sources

# --- 9. GÁN QUYỀN USER ---
echo "[Bước 6] Gán quyền user $CURRENT_USER..."
chown -R $CURRENT_USER:$CURRENT_USER /etc/suricata
chown -R $CURRENT_USER:$CURRENT_USER /var/log/suricata
chmod -R 755 /etc/suricata
chmod -R 755 /var/log/suricata

# --- 10. KHỞI ĐỘNG SURICATA ---
echo "[Bước 7] Khởi động Suricata..."
systemctl enable suricata
systemctl restart suricata

# --- 11. KIỂM TRA TRẠNG THÁI ---
echo "[Hoàn tất] Suricata đã được cài đặt và chạy."
echo "=========================================="
echo "Interface WAN: $WAN_IFACE"
echo "Interface LAN: $LAN_IFACE"
echo "HOME_NET: $HOME_NET_VALUE"
echo "Ruleset đã kích hoạt: $RULESET"
echo "Log file: /var/log/suricata/eve.json"
echo "=========================================="
echo "Lệnh kiểm tra log:"
echo "   sudo tail -f /var/log/suricata/eve.json"
echo "Lệnh kiểm tra service:"
echo "   sudo systemctl status suricata"
echo "=========================================="
echo "[DONE] Hệ thống đã sẵn sàng giám sát & chặn tấn công (IPS mode)."