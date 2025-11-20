#!/bin/bash

# Post-Clone Setup Script für Ubuntu VMs in Proxmox
# Ändert Hostnamen, IP-Adresse und regeneriert SSH-Host-Keys
# 
# Autor: FinEx Agents LLC
# Verwendung: sudo ./post-clone-setup.sh

set -e

# Farben für Ausgabe
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Prüfen ob als root ausgeführt
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Fehler: Dieses Skript muss als root ausgeführt werden!${NC}"
   echo "Bitte mit 'sudo $0' ausführen."
   exit 1
fi

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       Post-Clone Setup für Ubuntu VM (Proxmox)            ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Aktuelle Konfiguration anzeigen
CURRENT_HOSTNAME=$(hostname)
CURRENT_IP=$(hostname -I | awk '{print $1}')

echo -e "${YELLOW}Aktuelle Konfiguration:${NC}"
echo -e "  Hostname: ${GREEN}$CURRENT_HOSTNAME${NC}"
echo -e "  IP-Adresse: ${GREEN}$CURRENT_IP${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════
# HOSTNAME ÄNDERN
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}── Hostname Konfiguration ──${NC}"
read -p "Neuer Hostname (leer lassen für '$CURRENT_HOSTNAME'): " NEW_HOSTNAME

if [[ -n "$NEW_HOSTNAME" ]]; then
    # Hostname validieren
    if [[ ! "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        echo -e "${RED}Fehler: Ungültiger Hostname!${NC}"
        echo "Hostname darf nur Buchstaben, Zahlen und Bindestriche enthalten."
        exit 1
    fi
    
    echo -e "Ändere Hostname zu: ${GREEN}$NEW_HOSTNAME${NC}"
    
    # /etc/hostname aktualisieren
    echo "$NEW_HOSTNAME" > /etc/hostname
    
    # /etc/hosts aktualisieren
    sed -i "s/127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
    
    # Falls kein Eintrag existiert, hinzufügen
    if ! grep -q "127.0.1.1" /etc/hosts; then
        echo "127.0.1.1	$NEW_HOSTNAME" >> /etc/hosts
    fi
    
    # Hostname sofort setzen
    hostnamectl set-hostname "$NEW_HOSTNAME"
    
    echo -e "${GREEN}✓ Hostname erfolgreich geändert${NC}"
else
    echo -e "${YELLOW}Hostname wird beibehalten${NC}"
fi

echo ""

# ═══════════════════════════════════════════════════════════════
# IP-ADRESSEN ÄNDERN (Mehrere Interfaces)
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}── Netzwerk Konfiguration ──${NC}"

# Alle Netzwerk-Interfaces ermitteln (außer lo)
mapfile -t ALL_IFACES < <(ls /sys/class/net | grep -v lo)

echo -e "${YELLOW}Gefundene Netzwerk-Interfaces:${NC}"
for i in "${!ALL_IFACES[@]}"; do
    IFACE="${ALL_IFACES[$i]}"
    IFACE_IP=$(ip -4 addr show "$IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1)
    IFACE_MAC=$(cat /sys/class/net/"$IFACE"/address 2>/dev/null)
    if [[ -n "$IFACE_IP" ]]; then
        echo -e "  $((i+1)). ${GREEN}$IFACE${NC} - IP: $IFACE_IP - MAC: $IFACE_MAC"
    else
        echo -e "  $((i+1)). ${GREEN}$IFACE${NC} - IP: (keine) - MAC: $IFACE_MAC"
    fi
done
echo ""

# Sekundäre IPs erkennen und entfernen
echo -e "${BLUE}── Sekundäre IP-Adressen prüfen ──${NC}"
FOUND_SECONDARY=false

for IFACE in "${ALL_IFACES[@]}"; do
    # Alle sekundären IPs für dieses Interface finden
    SECONDARY_IPS=$(ip -4 addr show "$IFACE" 2>/dev/null | grep "secondary" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' || true)
    
    if [[ -n "$SECONDARY_IPS" ]]; then
        FOUND_SECONDARY=true
        echo -e "${YELLOW}Sekundäre IPs auf $IFACE gefunden:${NC}"
        while IFS= read -r SEC_IP; do
            echo -e "  - ${RED}$SEC_IP${NC}"
        done <<< "$SECONDARY_IPS"
    fi
done

if [[ "$FOUND_SECONDARY" == true ]]; then
    echo ""
    read -p "Alle sekundären IP-Adressen jetzt entfernen? (j/n): " REMOVE_SECONDARY
    
    if [[ "$REMOVE_SECONDARY" =~ ^[jJyY]$ ]]; then
        for IFACE in "${ALL_IFACES[@]}"; do
            SECONDARY_IPS=$(ip -4 addr show "$IFACE" 2>/dev/null | grep "secondary" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+')
            
            if [[ -n "$SECONDARY_IPS" ]]; then
                while IFS= read -r SEC_IP; do
                    echo -e "Entferne ${RED}$SEC_IP${NC} von $IFACE..."
                    ip addr del "$SEC_IP" dev "$IFACE" 2>/dev/null || true
                done <<< "$SECONDARY_IPS"
            fi
        done
        echo -e "${GREEN}✓ Sekundäre IP-Adressen entfernt${NC}"
    fi
else
    echo -e "${GREEN}Keine sekundären IP-Adressen gefunden${NC}"
fi

echo ""

# Prüfen ob Netplan oder ifupdown verwendet wird
NETPLAN_DIR="/etc/netplan"
INTERFACES_FILE="/etc/network/interfaces"

read -p "Netzwerk-Konfiguration ändern? (j/n): " CHANGE_IP

if [[ "$CHANGE_IP" =~ ^[jJyY]$ ]]; then
    
    # Arrays für Interface-Konfigurationen
    declare -A IFACE_CONFIG
    declare -a CONFIGURED_IFACES
    PRIMARY_IFACE=""
    GLOBAL_DNS=""
    
    echo ""
    echo -e "${YELLOW}Konfiguriere jetzt die einzelnen Interfaces:${NC}"
    echo -e "${YELLOW}(Leer lassen um Interface zu überspringen)${NC}"
    echo ""
    
    for IFACE in "${ALL_IFACES[@]}"; do
        echo -e "${BLUE}── Interface: $IFACE ──${NC}"
        
        # Aktuelle IP anzeigen
        CURRENT_IFACE_IP=$(ip -4 addr show "$IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1)
        if [[ -n "$CURRENT_IFACE_IP" ]]; then
            echo -e "  Aktuelle IP: ${GREEN}$CURRENT_IFACE_IP${NC}"
        fi
        
        read -p "  Neue IP für $IFACE (z.B. 192.168.1.100/24, leer=überspringen): " NEW_IP_CIDR
        
        if [[ -n "$NEW_IP_CIDR" ]]; then
            # IP und Prefix extrahieren
            if [[ "$NEW_IP_CIDR" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})/([0-9]{1,2})$ ]]; then
                IFACE_IP="${BASH_REMATCH[1]}"
                IFACE_PREFIX="${BASH_REMATCH[2]}"
            else
                echo -e "${RED}  Fehler: Ungültiges Format! Verwende IP/Prefix (z.B. 192.168.1.100/24)${NC}"
                continue
            fi
            
            # Gateway abfragen
            read -p "  Gateway für $IFACE (leer=kein Gateway): " IFACE_GW
            
            # Primäres Interface?
            if [[ -z "$PRIMARY_IFACE" && -n "$IFACE_GW" ]]; then
                read -p "  Als primäres Interface mit Default-Route? (j/n): " IS_PRIMARY
                if [[ "$IS_PRIMARY" =~ ^[jJyY]$ ]]; then
                    PRIMARY_IFACE="$IFACE"
                    read -p "  DNS-Server (z.B. 8.8.8.8,1.1.1.1): " GLOBAL_DNS
                fi
            fi
            
            # Konfiguration speichern
            IFACE_CONFIG["${IFACE}_ip"]="$IFACE_IP"
            IFACE_CONFIG["${IFACE}_prefix"]="$IFACE_PREFIX"
            IFACE_CONFIG["${IFACE}_gw"]="$IFACE_GW"
            CONFIGURED_IFACES+=("$IFACE")
            
            echo -e "  ${GREEN}✓ $IFACE konfiguriert${NC}"
        else
            echo -e "  ${YELLOW}$IFACE wird übersprungen${NC}"
        fi
        echo ""
    done
    
    # Konfiguration schreiben
    if [[ ${#CONFIGURED_IFACES[@]} -gt 0 ]]; then
        
        # Netplan Konfiguration
        if [[ -d "$NETPLAN_DIR" ]]; then
            echo -e "Verwende ${GREEN}Netplan${NC} für Netzwerkkonfiguration"
            
        # Alte Netplan-Configs sichern
            for f in "$NETPLAN_DIR"/*.yaml; do
                if [[ -f "$f" ]]; then
                    cp "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
                fi
            done
            
            # Alle IPs von den Interfaces flushen (entfernt auch sekundäre IPs)
            echo -e "${YELLOW}Entferne alle bestehenden IP-Adressen...${NC}"
            for IFACE in "${ALL_IFACES[@]}"; do
                ip addr flush dev "$IFACE" 2>/dev/null || true
            done
            
            # DNS-Server formatieren
            DNS_FORMATTED=$(echo "$GLOBAL_DNS" | sed 's/,/", "/g')
            
            # Netplan-Konfiguration erstellen
            cat > "$NETPLAN_DIR/01-netcfg.yaml" << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
EOF
            
            for IFACE in "${CONFIGURED_IFACES[@]}"; do
                IP="${IFACE_CONFIG[${IFACE}_ip]}"
                PREFIX="${IFACE_CONFIG[${IFACE}_prefix]}"
                GW="${IFACE_CONFIG[${IFACE}_gw]}"
                
                cat >> "$NETPLAN_DIR/01-netcfg.yaml" << EOF
    $IFACE:
      dhcp4: false
      dhcp6: false
      link-local: []
      addresses:
        - $IP/$PREFIX
EOF
                
                # Gateway nur für primäres Interface oder wenn gesetzt
                if [[ -n "$GW" ]]; then
                    if [[ "$IFACE" == "$PRIMARY_IFACE" ]]; then
                        cat >> "$NETPLAN_DIR/01-netcfg.yaml" << EOF
      routes:
        - to: default
          via: $GW
      nameservers:
        addresses: [$DNS_FORMATTED]
EOF
                    else
                        # Zusätzliche Route ohne default
                        cat >> "$NETPLAN_DIR/01-netcfg.yaml" << EOF
      routes:
        - to: ${IP%.*}.0/$PREFIX
          via: $GW
EOF
                    fi
                fi
            done
            
            # Nicht konfigurierte Interfaces auch ohne DHCP/IPv6 setzen
            for IFACE in "${ALL_IFACES[@]}"; do
                if [[ ! " ${CONFIGURED_IFACES[*]} " =~ " ${IFACE} " ]]; then
                    cat >> "$NETPLAN_DIR/01-netcfg.yaml" << EOF
    $IFACE:
      dhcp4: false
      dhcp6: false
      link-local: []
EOF
                fi
            done
            
            # Berechtigungen setzen
            chmod 600 "$NETPLAN_DIR/01-netcfg.yaml"
            
            echo -e "${GREEN}✓ Netplan-Konfiguration erstellt${NC}"
            echo ""
            echo -e "${YELLOW}Generierte Konfiguration:${NC}"
            cat "$NETPLAN_DIR/01-netcfg.yaml"
            
            # Netplan sofort anwenden
            echo ""
            echo -e "${YELLOW}Wende Netplan-Konfiguration an...${NC}"
            netplan apply 2>&1 || true
            echo -e "${GREEN}✓ Netzwerkkonfiguration angewendet${NC}"
            
        # ifupdown Konfiguration
        elif [[ -f "$INTERFACES_FILE" ]]; then
            echo -e "Verwende ${GREEN}ifupdown${NC} für Netzwerkkonfiguration"
            
            # Backup erstellen
            cp "$INTERFACES_FILE" "${INTERFACES_FILE}.bak.$(date +%Y%m%d%H%M%S)"
            
            # DNS-Server für ifupdown formatieren
            DNS_FORMATTED=$(echo "$GLOBAL_DNS" | sed 's/,/ /g')
            
            # Neue Konfiguration erstellen
            cat > "$INTERFACES_FILE" << EOF
# Loopback
auto lo
iface lo inet loopback

EOF
            
            for IFACE in "${CONFIGURED_IFACES[@]}"; do
                IP="${IFACE_CONFIG[${IFACE}_ip]}"
                PREFIX="${IFACE_CONFIG[${IFACE}_prefix]}"
                GW="${IFACE_CONFIG[${IFACE}_gw]}"
                
                cat >> "$INTERFACES_FILE" << EOF
# Interface $IFACE
auto $IFACE
iface $IFACE inet static
    address $IP/$PREFIX
EOF
                
                if [[ -n "$GW" ]]; then
                    if [[ "$IFACE" == "$PRIMARY_IFACE" ]]; then
                        cat >> "$INTERFACES_FILE" << EOF
    gateway $GW
    dns-nameservers $DNS_FORMATTED
EOF
                    fi
                fi
                
                echo "" >> "$INTERFACES_FILE"
            done
            
            echo -e "${GREEN}✓ interfaces-Konfiguration erstellt${NC}"
            echo ""
            echo -e "${YELLOW}Generierte Konfiguration:${NC}"
            cat "$INTERFACES_FILE"
        else
            echo -e "${RED}Fehler: Keine bekannte Netzwerkkonfiguration gefunden!${NC}"
            exit 1
        fi
        
        echo ""
        echo -e "${YELLOW}Hinweis: Netzwerkkonfiguration wird beim Neustart aktiv${NC}"
        
        # IPv6 systemweit deaktivieren
        echo ""
        echo -e "${BLUE}── IPv6 systemweit deaktivieren ──${NC}"
        
        # sysctl Konfiguration für IPv6
        cat > /etc/sysctl.d/99-disable-ipv6.conf << EOF
# IPv6 komplett deaktivieren
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
        
        # Sofort anwenden
        sysctl -p /etc/sysctl.d/99-disable-ipv6.conf > /dev/null 2>&1 || true
        
        # GRUB Konfiguration für IPv6-Deaktivierung beim Boot
        if [[ -f /etc/default/grub ]]; then
            if ! grep -q "ipv6.disable=1" /etc/default/grub; then
                sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 ipv6.disable=1"/' /etc/default/grub
                sed -i 's/GRUB_CMDLINE_LINUX="\([^"]*\)"/GRUB_CMDLINE_LINUX="\1 ipv6.disable=1"/' /etc/default/grub
                update-grub 2>/dev/null || true
            fi
        fi
        
        echo -e "${GREEN}✓ IPv6 systemweit deaktiviert${NC}"
    else
        echo -e "${YELLOW}Keine Interfaces konfiguriert${NC}"
    fi
else
    echo -e "${YELLOW}Netzwerk-Konfiguration wird beibehalten${NC}"
fi

echo ""

# ═══════════════════════════════════════════════════════════════
# SSH HOST KEYS REGENERIEREN
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}── SSH Host Keys regenerieren ──${NC}"

# Alte SSH-Keys entfernen
echo "Entferne alte SSH-Host-Keys..."
rm -f /etc/ssh/ssh_host_*

# Neue SSH-Keys generieren
echo "Generiere neue SSH-Host-Keys..."
ssh-keygen -A

# SSH-Dienst neustarten
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true

echo -e "${GREEN}✓ SSH-Host-Keys erfolgreich regeneriert${NC}"
echo ""

# Neue Key-Fingerprints anzeigen
echo -e "${YELLOW}Neue SSH-Key-Fingerprints:${NC}"
for key in /etc/ssh/ssh_host_*_key.pub; do
    if [[ -f "$key" ]]; then
        ssh-keygen -lf "$key"
    fi
done

echo ""

# ═══════════════════════════════════════════════════════════════
# MACHINE-ID REGENERIEREN (Optional aber empfohlen für Klone)
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}── Machine-ID regenerieren ──${NC}"
read -p "Machine-ID regenerieren? (empfohlen für Klone) (j/n): " REGEN_MACHINE_ID

if [[ "$REGEN_MACHINE_ID" =~ ^[jJyY]$ ]]; then
    # Alte Machine-ID entfernen
    rm -f /etc/machine-id
    rm -f /var/lib/dbus/machine-id 2>/dev/null || true
    
    # Neue Machine-ID generieren
    systemd-machine-id-setup
    
    # Symlink für dbus erstellen falls nötig
    if [[ -d /var/lib/dbus ]]; then
        ln -sf /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true
    fi
    
    echo -e "${GREEN}✓ Machine-ID erfolgreich regeneriert${NC}"
else
    echo -e "${YELLOW}Machine-ID wird beibehalten${NC}"
fi

echo ""

# ═══════════════════════════════════════════════════════════════
# ZUSAMMENFASSUNG
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                    Zusammenfassung                        ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ -n "$NEW_HOSTNAME" ]]; then
    echo -e "  Neuer Hostname: ${GREEN}$NEW_HOSTNAME${NC}"
else
    echo -e "  Hostname: ${GREEN}$CURRENT_HOSTNAME${NC} (unverändert)"
fi

if [[ "$CHANGE_IP" =~ ^[jJyY]$ ]] && [[ ${#CONFIGURED_IFACES[@]} -gt 0 ]]; then
    echo -e "  ${YELLOW}Netzwerk-Interfaces:${NC}"
    for IFACE in "${CONFIGURED_IFACES[@]}"; do
        IP="${IFACE_CONFIG[${IFACE}_ip]}"
        PREFIX="${IFACE_CONFIG[${IFACE}_prefix]}"
        GW="${IFACE_CONFIG[${IFACE}_gw]}"
        if [[ "$IFACE" == "$PRIMARY_IFACE" ]]; then
            echo -e "    ${GREEN}$IFACE${NC}: $IP/$PREFIX (Gateway: $GW) ${GREEN}[PRIMARY]${NC}"
        elif [[ -n "$GW" ]]; then
            echo -e "    ${GREEN}$IFACE${NC}: $IP/$PREFIX (Gateway: $GW)"
        else
            echo -e "    ${GREEN}$IFACE${NC}: $IP/$PREFIX"
        fi
    done
    echo -e "  DNS: ${GREEN}$GLOBAL_DNS${NC}"
else
    echo -e "  Netzwerk: ${GREEN}unverändert${NC}"
fi

echo -e "  SSH-Host-Keys: ${GREEN}Neu generiert${NC}"

if [[ "$REGEN_MACHINE_ID" =~ ^[jJyY]$ ]]; then
    echo -e "  Machine-ID: ${GREEN}Neu generiert${NC}"
fi

echo ""

# ═══════════════════════════════════════════════════════════════
# SYSTEM AKTUALISIEREN
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}── System aktualisieren ──${NC}"
echo -e "${YELLOW}Führe apt update aus...${NC}"
apt update

echo ""
echo -e "${YELLOW}Führe apt upgrade aus...${NC}"
apt upgrade -y

echo ""
echo -e "${YELLOW}Führe apt autoremove aus...${NC}"
apt autoremove -y

echo ""
echo -e "${GREEN}✓ System erfolgreich aktualisiert${NC}"

echo ""
echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║  WICHTIG: System muss neu gestartet werden!               ║${NC}"
echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

read -p "System jetzt neustarten? (j/n): " DO_REBOOT

if [[ "$DO_REBOOT" =~ ^[jJyY]$ ]]; then
    echo -e "${GREEN}System wird in 5 Sekunden neu gestartet...${NC}"
    sleep 5
    reboot
else
    echo -e "${YELLOW}Bitte das System manuell mit 'sudo reboot' neustarten.${NC}"
fi
