#!/usr/bin/env bash
# ================================================================
#  Suricata Auto Installer & Configurator (IPS Mode by default)
#  Yêu cầu: File ./suricata.env nằm cùng thư mục
# ================================================================

set -e

# --- 1. KIỂM TRA QUYỀN ROOT ---
if [ "$EUID" -ne 0 ]; then
  echo "Script cần quyền root. Hãy chạy bằng: sudo bash install_suricata.sh"
  exit 1
fi

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
echo "[Bước 1] Cài đặt Suricata từ PPA chính thức..."
apt update -y
apt install -y software-properties-common
add-apt-repository ppa:oisf/suricata-stable -y
apt update -y
apt install -y suricata suricata-update jq

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

# --- 6. KÍCH HOẠT LOCAL RULES TRONG YAML ---
if [ "$ENABLE_LOCAL_RULES" = "yes" ]; then
  if ! grep -q "local.rules" /etc/suricata/suricata.yaml; then
    sed -i "/rule-files:/a\  - local.rules" /etc/suricata/suricata.yaml
  fi
fi

# --- 7. CẤU HÌNH IPS MODE VÀ AF-PACKET ---
if [ "$MODE" = "IPS" ] && [ "$ENABLE_AF_PACKET" = "yes" ]; then
  echo "[Bước 4] Cấu hình Suricata chế độ IPS inline (AF-PACKET + NFQUEUE)..."
  sed -i 's|af-packet:.*|af-packet:|' /etc/suricata/suricata.yaml
  cat <<EOF >/etc/suricata/af-packet-config.yaml
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
EOF
  sed -i '/^af-packet:/,$d' /etc/suricata/suricata.yaml
  cat /etc/suricata/af-packet-config.yaml >> /etc/suricata/suricata.yaml
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