#!/bin/bash

# Disk Expansion Script für Ubuntu VMs in Proxmox
# Deaktiviert Swap, erkennt LVM/direkte Partitionen, erweitert auf Maximum
# 
# Autor: FinEx Agents LLC
# Verwendung: sudo ./expand-disk.sh

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
echo -e "${BLUE}║         Disk Expansion Script für Ubuntu (Proxmox)        ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════
# SYSTEM ANALYSIEREN
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}── System analysieren ──${NC}"

# Root-Partition finden
ROOT_SOURCE=$(findmnt -n -o SOURCE /)
ROOT_FSTYPE=$(findmnt -n -o FSTYPE /)

echo -e "Root-Dateisystem: ${GREEN}$ROOT_SOURCE${NC}"
echo -e "Dateisystem-Typ: ${GREEN}$ROOT_FSTYPE${NC}"

# Prüfen ob LVM
IS_LVM=false
LVM_VG=""
LVM_LV=""
LVM_PV=""
DISK=""
PARTITION=""

if [[ "$ROOT_SOURCE" == /dev/mapper/* ]] || [[ "$ROOT_SOURCE" == /dev/dm-* ]]; then
    IS_LVM=true
    
    # LV-Name ermitteln
    if [[ "$ROOT_SOURCE" == /dev/dm-* ]]; then
        LVM_LV=$(lvs --noheadings -o lv_name,lv_dm_path | grep "$ROOT_SOURCE" | awk '{print $1}')
        LVM_VG=$(lvs --noheadings -o vg_name,lv_dm_path | grep "$ROOT_SOURCE" | awk '{print $1}')
    else
        # Format: /dev/mapper/vgname-lvname
        LVM_PATH=$(basename "$ROOT_SOURCE")
        LVM_VG=$(lvs --noheadings -o vg_name,lv_path | grep "$ROOT_SOURCE" | awk '{print $1}' || echo "${LVM_PATH%%-*}")
        LVM_LV=$(lvs --noheadings -o lv_name,lv_path | grep "$ROOT_SOURCE" | awk '{print $1}' || echo "${LVM_PATH##*-}")
    fi
    
    # PV ermitteln
    LVM_PV=$(pvs --noheadings -o pv_name,vg_name | grep "$LVM_VG" | awk '{print $1}' | head -1)
    
    # Disk und Partition aus PV ermitteln
    if [[ "$LVM_PV" =~ ^/dev/([a-z]+)([0-9]+)$ ]] || [[ "$LVM_PV" =~ ^/dev/(nvme[0-9]+n[0-9]+)p([0-9]+)$ ]]; then
        PARTITION="$LVM_PV"
        # Disk ohne Partitionsnummer
        DISK=$(lsblk -no pkname "$LVM_PV" | head -1)
        DISK="/dev/$DISK"
    fi
    
    echo -e "LVM erkannt: ${GREEN}Ja${NC}"
    echo -e "  Volume Group: ${GREEN}$LVM_VG${NC}"
    echo -e "  Logical Volume: ${GREEN}$LVM_LV${NC}"
    echo -e "  Physical Volume: ${GREEN}$LVM_PV${NC}"
else
    # Direkte Partition
    PARTITION="$ROOT_SOURCE"
    DISK=$(lsblk -no pkname "$ROOT_SOURCE" | head -1)
    DISK="/dev/$DISK"
    
    echo -e "LVM erkannt: ${YELLOW}Nein${NC}"
fi

echo -e "Disk: ${GREEN}$DISK${NC}"
echo -e "Partition: ${GREEN}$PARTITION${NC}"

# Partitionsnummer ermitteln
PART_NUM=$(echo "$PARTITION" | grep -oE '[0-9]+$')

echo -e "Partitionsnummer: ${GREEN}$PART_NUM${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════
# SWAP ERKENNEN
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}── Swap-Konfiguration prüfen ──${NC}"

SWAP_DEVICES=$(swapon --show=NAME --noheadings 2>/dev/null || true)
SWAP_IN_FSTAB=$(grep -E "^\s*[^#].*\sswap\s" /etc/fstab 2>/dev/null || true)
SWAP_LV=""
SWAP_PARTITION=""

if [[ -n "$SWAP_DEVICES" ]]; then
    echo -e "${YELLOW}Aktive Swap-Geräte gefunden:${NC}"
    echo "$SWAP_DEVICES" | while read -r swap; do
        SIZE=$(swapon --show=NAME,SIZE --noheadings | grep "$swap" | awk '{print $2}')
        echo -e "  - ${RED}$swap${NC} ($SIZE)"
    done
    
    # Swap-Typ ermitteln
    for swap in $SWAP_DEVICES; do
        if [[ "$swap" == /dev/mapper/* ]] || [[ "$swap" == /dev/dm-* ]]; then
            SWAP_LV="$swap"
        else
            SWAP_PARTITION="$swap"
        fi
    done
else
    echo -e "${GREEN}Kein aktiver Swap gefunden${NC}"
fi

if [[ -n "$SWAP_IN_FSTAB" ]]; then
    echo -e "${YELLOW}Swap-Einträge in /etc/fstab:${NC}"
    echo "$SWAP_IN_FSTAB" | while read -r line; do
        echo -e "  ${RED}$line${NC}"
    done
fi

echo ""

# ═══════════════════════════════════════════════════════════════
# AKTUELLE GRÖßEN ANZEIGEN
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}── Aktuelle Speichergrößen ──${NC}"

# Disk-Größe
DISK_SIZE=$(lsblk -bno SIZE "$DISK" | head -1)
DISK_SIZE_HR=$(numfmt --to=iec-i --suffix=B "$DISK_SIZE")

echo -e "Disk-Größe ($DISK): ${GREEN}$DISK_SIZE_HR${NC}"

# Partition-Größe
PART_SIZE=$(lsblk -bno SIZE "$PARTITION" 2>/dev/null || echo "0")
PART_SIZE_HR=$(numfmt --to=iec-i --suffix=B "$PART_SIZE")

echo -e "Partition-Größe ($PARTITION): ${GREEN}$PART_SIZE_HR${NC}"

# Root-Dateisystem Größe
ROOT_SIZE=$(df -B1 --output=size / | tail -1 | tr -d ' ')
ROOT_SIZE_HR=$(numfmt --to=iec-i --suffix=B "$ROOT_SIZE")
ROOT_USED=$(df -B1 --output=used / | tail -1 | tr -d ' ')
ROOT_USED_HR=$(numfmt --to=iec-i --suffix=B "$ROOT_USED")
ROOT_AVAIL=$(df -B1 --output=avail / | tail -1 | tr -d ' ')
ROOT_AVAIL_HR=$(numfmt --to=iec-i --suffix=B "$ROOT_AVAIL")

echo -e "Root-Dateisystem: ${GREEN}$ROOT_SIZE_HR${NC} (Belegt: $ROOT_USED_HR, Frei: $ROOT_AVAIL_HR)"

if [[ "$IS_LVM" == true ]]; then
    # LV-Größe
    LV_SIZE=$(lvs --noheadings --units b -o lv_size "/dev/$LVM_VG/$LVM_LV" | tr -d ' ' | sed 's/B$//')
    LV_SIZE_HR=$(numfmt --to=iec-i --suffix=B "$LV_SIZE")
    echo -e "LV-Größe (/dev/$LVM_VG/$LVM_LV): ${GREEN}$LV_SIZE_HR${NC}"
    
    # VG freier Platz
    VG_FREE=$(vgs --noheadings --units b -o vg_free "$LVM_VG" | tr -d ' ' | sed 's/B$//')
    VG_FREE_HR=$(numfmt --to=iec-i --suffix=B "$VG_FREE")
    echo -e "Freier Platz in VG: ${GREEN}$VG_FREE_HR${NC}"
fi

echo ""

# ═══════════════════════════════════════════════════════════════
# FREIEN SPEICHERPLATZ AUF DISK PRÜFEN
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}── Ungenutzter Speicherplatz auf Disk ──${NC}"

# parted verwenden um freien Platz zu finden
FREE_SPACE_INFO=$(parted "$DISK" --script unit B print free 2>/dev/null | grep "Free Space" | tail -1 || true)

if [[ -n "$FREE_SPACE_INFO" ]]; then
    FREE_START=$(echo "$FREE_SPACE_INFO" | awk '{print $1}' | sed 's/B$//')
    FREE_END=$(echo "$FREE_SPACE_INFO" | awk '{print $2}' | sed 's/B$//')
    FREE_SIZE=$(echo "$FREE_SPACE_INFO" | awk '{print $3}' | sed 's/B$//')
    FREE_SIZE_HR=$(numfmt --to=iec-i --suffix=B "$FREE_SIZE" 2>/dev/null || echo "$FREE_SIZE")
    
    if [[ "$FREE_SIZE" -gt 1048576 ]]; then  # > 1MB
        echo -e "Ungenutzter Speicher: ${GREEN}$FREE_SIZE_HR${NC}"
    else
        echo -e "${YELLOW}Kein signifikanter ungenutzter Speicher auf der Disk${NC}"
        echo -e "${YELLOW}Bitte zuerst die Disk in Proxmox vergrößern!${NC}"
    fi
else
    echo -e "${YELLOW}Konnte freien Speicherplatz nicht ermitteln${NC}"
fi

echo ""

# ═══════════════════════════════════════════════════════════════
# AKTIONSPLAN ANZEIGEN
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                    Aktionsplan                            ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

ACTIONS=()

# Swap deaktivieren
if [[ -n "$SWAP_DEVICES" ]] || [[ -n "$SWAP_IN_FSTAB" ]]; then
    echo -e "1. ${YELLOW}Swap deaktivieren und entfernen${NC}"
    if [[ -n "$SWAP_LV" ]]; then
        echo -e "   - Swap-LV entfernen: $SWAP_LV"
        ACTIONS+=("swap_lv")
    fi
    if [[ -n "$SWAP_PARTITION" ]]; then
        echo -e "   - Swap-Partition deaktivieren: $SWAP_PARTITION"
        ACTIONS+=("swap_part")
    fi
    echo -e "   - Swap-Einträge aus /etc/fstab entfernen"
    ACTIONS+=("swap_fstab")
else
    echo -e "1. ${GREEN}Swap bereits deaktiviert${NC}"
fi

# Partition erweitern
echo -e "2. ${YELLOW}Partition erweitern${NC}"
echo -e "   - Partition $PARTITION auf Maximum vergrößern"
ACTIONS+=("partition")

# LVM erweitern
if [[ "$IS_LVM" == true ]]; then
    echo -e "3. ${YELLOW}LVM erweitern${NC}"
    echo -e "   - Physical Volume $LVM_PV erweitern"
    echo -e "   - Logical Volume /dev/$LVM_VG/$LVM_LV auf 100% erweitern"
    ACTIONS+=("lvm")
fi

# Dateisystem erweitern
echo -e "4. ${YELLOW}Dateisystem erweitern${NC}"
echo -e "   - $ROOT_FSTYPE Dateisystem auf Maximum vergrößern"
ACTIONS+=("filesystem")

echo ""
echo -e "${RED}WARNUNG: Diese Aktionen können nicht rückgängig gemacht werden!${NC}"
echo ""

read -p "Aktionen ausführen? (j/n): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[jJyY]$ ]]; then
    echo -e "${YELLOW}Abgebrochen.${NC}"
    exit 0
fi

echo ""

# ═══════════════════════════════════════════════════════════════
# SWAP DEAKTIVIEREN UND ENTFERNEN
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}── Swap deaktivieren ──${NC}"

# Alle Swaps deaktivieren
if [[ -n "$SWAP_DEVICES" ]]; then
    echo "Deaktiviere alle Swap-Geräte..."
    swapoff -a
    echo -e "${GREEN}✓ Swap deaktiviert${NC}"
fi

# Swap-LV entfernen
if [[ -n "$SWAP_LV" ]]; then
    echo "Entferne Swap Logical Volume..."
    # LV-Name aus Pfad extrahieren
    SWAP_LV_NAME=$(lvs --noheadings -o lv_name,lv_path 2>/dev/null | grep "swap" | awk '{print $1}' || true)
    SWAP_VG_NAME=$(lvs --noheadings -o vg_name,lv_path 2>/dev/null | grep "swap" | awk '{print $1}' || true)
    
    if [[ -n "$SWAP_LV_NAME" ]] && [[ -n "$SWAP_VG_NAME" ]]; then
        lvremove -f "/dev/$SWAP_VG_NAME/$SWAP_LV_NAME" 2>/dev/null || true
        echo -e "${GREEN}✓ Swap-LV entfernt${NC}"
    fi
fi

# fstab bereinigen
if [[ -n "$SWAP_IN_FSTAB" ]]; then
    echo "Entferne Swap-Einträge aus /etc/fstab..."
    cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d%H%M%S)
    sed -i '/\sswap\s/d' /etc/fstab
    echo -e "${GREEN}✓ Swap aus fstab entfernt${NC}"
fi

# Swap systemd-Unit deaktivieren
if systemctl list-unit-files | grep -q "swap.target"; then
    systemctl mask swap.target 2>/dev/null || true
fi

echo ""

# ═══════════════════════════════════════════════════════════════
# PARTITION ERWEITERN
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}── Partition erweitern ──${NC}"

# growpart verwenden falls verfügbar
if command -v growpart &> /dev/null; then
    echo "Erweitere Partition mit growpart..."
    growpart "$DISK" "$PART_NUM" || true
    echo -e "${GREEN}✓ Partition erweitert${NC}"
else
    # Fallback: parted verwenden
    echo "Erweitere Partition mit parted..."
    parted "$DISK" --script resizepart "$PART_NUM" 100%
    echo -e "${GREEN}✓ Partition erweitert${NC}"
fi

# Kernel über Änderungen informieren
partprobe "$DISK" 2>/dev/null || true

echo ""

# ═══════════════════════════════════════════════════════════════
# LVM ERWEITERN
# ═══════════════════════════════════════════════════════════════

if [[ "$IS_LVM" == true ]]; then
    echo -e "${BLUE}── LVM erweitern ──${NC}"
    
    # PV erweitern
    echo "Erweitere Physical Volume..."
    pvresize "$LVM_PV"
    echo -e "${GREEN}✓ PV erweitert${NC}"
    
    # LV erweitern
    echo "Erweitere Logical Volume auf 100%..."
    lvextend -l +100%FREE "/dev/$LVM_VG/$LVM_LV"
    echo -e "${GREEN}✓ LV erweitert${NC}"
    
    echo ""
fi

# ═══════════════════════════════════════════════════════════════
# DATEISYSTEM ERWEITERN
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}── Dateisystem erweitern ──${NC}"

case "$ROOT_FSTYPE" in
    ext4|ext3|ext2)
        echo "Erweitere $ROOT_FSTYPE Dateisystem..."
        resize2fs "$ROOT_SOURCE"
        echo -e "${GREEN}✓ Dateisystem erweitert${NC}"
        ;;
    xfs)
        echo "Erweitere XFS Dateisystem..."
        xfs_growfs /
        echo -e "${GREEN}✓ Dateisystem erweitert${NC}"
        ;;
    *)
        echo -e "${RED}Unbekanntes Dateisystem: $ROOT_FSTYPE${NC}"
        echo -e "${RED}Bitte manuell erweitern!${NC}"
        ;;
esac

echo ""

# ═══════════════════════════════════════════════════════════════
# ERGEBNIS ANZEIGEN
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                    Ergebnis                               ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Neue Größen anzeigen
NEW_ROOT_SIZE=$(df -h --output=size / | tail -1 | tr -d ' ')
NEW_ROOT_USED=$(df -h --output=used / | tail -1 | tr -d ' ')
NEW_ROOT_AVAIL=$(df -h --output=avail / | tail -1 | tr -d ' ')
NEW_ROOT_PCENT=$(df -h --output=pcent / | tail -1 | tr -d ' ')

echo -e "Root-Dateisystem (/):"
echo -e "  Größe: ${GREEN}$NEW_ROOT_SIZE${NC}"
echo -e "  Belegt: ${GREEN}$NEW_ROOT_USED${NC} ($NEW_ROOT_PCENT)"
echo -e "  Verfügbar: ${GREEN}$NEW_ROOT_AVAIL${NC}"
echo ""

echo -e "${GREEN}✓ Disk-Erweiterung erfolgreich abgeschlossen!${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════
# REBOOT
# ═══════════════════════════════════════════════════════════════

echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║  Neustart empfohlen für vollständige Übernahme            ║${NC}"
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
