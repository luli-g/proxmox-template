#!/bin/bash

# Docker & QEMU Guest Agent Installation Script
# Installiert Docker, Docker Compose und QEMU Guest Agent
# 
# Autor: FinEx Agents LLC
# Verwendung: sudo ./install-docker-qemu.sh

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

# Aktuellen Benutzer ermitteln (für Docker-Gruppe)
if [[ -n "$SUDO_USER" ]]; then
    CURRENT_USER="$SUDO_USER"
else
    CURRENT_USER="$USER"
fi

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     Docker & QEMU Guest Agent Installation                ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════
# SYSTEM AKTUALISIEREN
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}── System aktualisieren ──${NC}"
apt update
apt upgrade -y
apt autoremove -y
echo -e "${GREEN}✓ System aktualisiert${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════
# VORAUSSETZUNGEN INSTALLIEREN
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}── Notwendige Pakete installieren ──${NC}"
apt install -y \
    curl \
    apt-transport-https \
    ca-certificates \
    software-properties-common \
    gnupg \
    lsb-release
echo -e "${GREEN}✓ Pakete installiert${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════
# DOCKER INSTALLIEREN
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}── Docker installieren ──${NC}"

# Alte Docker-Versionen entfernen (falls vorhanden)
apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# Docker GPG-Key hinzufügen
echo "Füge Docker GPG-Key hinzu..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg --yes

# Docker-Repository hinzufügen
echo "Füge Docker-Repository hinzu..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
| tee /etc/apt/sources.list.d/docker.list > /dev/null

# Paketquellen aktualisieren
apt update

# Docker installieren
echo "Installiere Docker..."
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Benutzer zur Docker-Gruppe hinzufügen
echo "Füge $CURRENT_USER zur Docker-Gruppe hinzu..."
usermod -aG docker "$CURRENT_USER"

# Docker-Dienst aktivieren und starten
systemctl enable docker
systemctl start docker

echo -e "${GREEN}✓ Docker installiert${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════
# DOCKER COMPOSE (STANDALONE) INSTALLIEREN
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}── Docker Compose (standalone) installieren ──${NC}"

# Neueste Version ermitteln
COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f 4)

echo "Installiere Docker Compose $COMPOSE_VERSION..."
curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/bin/docker-compose

chmod +x /usr/local/bin/docker-compose

echo -e "${GREEN}✓ Docker Compose installiert${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════
# QEMU GUEST AGENT INSTALLIEREN
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}── QEMU Guest Agent installieren ──${NC}"

apt install -y qemu-guest-agent

# Dienst aktivieren und starten
systemctl enable qemu-guest-agent
systemctl start qemu-guest-agent

echo -e "${GREEN}✓ QEMU Guest Agent installiert${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════
# ZUSAMMENFASSUNG
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                    Zusammenfassung                        ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Versionen anzeigen
DOCKER_VERSION=$(docker --version 2>/dev/null | cut -d ' ' -f 3 | tr -d ',')
COMPOSE_VERSION_INSTALLED=$(docker-compose --version 2>/dev/null | cut -d ' ' -f 4 || docker compose version --short 2>/dev/null)
QEMU_STATUS=$(systemctl is-active qemu-guest-agent)

echo -e "  Docker Version: ${GREEN}$DOCKER_VERSION${NC}"
echo -e "  Docker Compose: ${GREEN}$COMPOSE_VERSION_INSTALLED${NC}"
echo -e "  QEMU Guest Agent: ${GREEN}$QEMU_STATUS${NC}"
echo -e "  Docker-Gruppe: ${GREEN}$CURRENT_USER hinzugefügt${NC}"
echo ""

echo -e "${GREEN}✅ Installation erfolgreich abgeschlossen!${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════
# REBOOT
# ═══════════════════════════════════════════════════════════════

echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║  Neustart erforderlich für Docker-Gruppenrechte!          ║${NC}"
echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

read -p "System jetzt neustarten? (j/n): " DO_REBOOT

if [[ "$DO_REBOOT" =~ ^[jJyY]$ ]]; then
    echo -e "${GREEN}System wird in 5 Sekunden neu gestartet...${NC}"
    sleep 5
    reboot
else
    echo -e "${YELLOW}Bitte das System manuell mit 'sudo reboot' neustarten.${NC}"
    echo -e "${YELLOW}Erst nach dem Neustart kann $CURRENT_USER Docker ohne sudo nutzen.${NC}"
fi
