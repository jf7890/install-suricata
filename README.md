# Suricata Installation Script README

## Supported Operating System

This script is designed for **Ubuntu 20.04 and Ubuntu 22.04**.

## Description

This README provides instructions for using the Suricata installation script with environment configuration stored in `suricata.env`. The script sets up Suricata in IPS inline mode using AF-PACKET and NFQUEUE, based on values defined in the environment file.

## Environment File (`suricata.env`)

You must adjust the following variables before running the script:

| Variable  | Description                                | Example Value  |
| --------- | ------------------------------------------ | -------------- |
| WAN_IFACE | External (WAN) network interface           | ens18          |
| LAN_IFACE | Internal (LAN) network interface           | ens19          |
| HOME_NET  | Internal protected network range           | 10.10.100.0/24 |
| GATEWAY   | Default gateway IP used by both interfaces | 10.10.100.1    |
| MODE      | Operation mode of Suricata                 | IPS            |

Ensure the file is in the same directory as the script and named: `suricata.env`

Example `suricata.env`:

```
WAN_IFACE=ens18
LAN_IFACE=ens19
HOME_NET=10.10.100.0/24
GATEWAY=10.10.100.1
MODE=IPS
```

## How to Run the Script

1. Make the script executable:

   ```bash
   chmod +x install_suricata.sh
   ```

2. Run the installation script:

   ```bash
   ./install_suricata.sh
   ```

## What the Script Does

* Installs Suricata if not already installed
* Loads environment variables from `suricata.env`
* Configures AF-PACKET inline mode
* Sets HOME_NET and interfaces
* Enables IPS (blocking) mode using NFQUEUE
* Updates Suricata rules from Emerging Threats (ET Open)
* Enables Suricata to start automatically on boot

## Notes

* You must run the script as **root** or with **sudo** privileges
* Ensure the network interfaces are correct
* Make sure the gateway exists and routes traffic properly

## Uninstallation (Optional)

To remove Suricata:

```bash
sudo apt remove --purge suricata -y
sudo rm -rf /etc/suricata
```

## Support

For further customization or troubleshooting, consult the official Suricata documentation: [https://suricata.io/documentation/](https://suricata.io/documentation/)
