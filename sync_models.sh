#!/bin/bash

# Konfiguration aus .env laden (Fallback auf .env.default)
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
elif [ -f "$SCRIPT_DIR/.env.default" ]; then
    set -a
    source "$SCRIPT_DIR/.env.default"
    set +a
fi

# Quell-Ordner (LM Studio Modelle)
SOURCE_DIR="${SOURCE_DIR}"

# Ziel-Ordner ist der Unterordner "models" im selben Verzeichnis wie dieses Skript
TARGET_DIR="$SCRIPT_DIR/models"

# Farbdefinitionen
C_TITLE='\033[1;34m'
C_PATH='\033[0;33m'
C_GREEN='\033[0;32m'
C_RED='\033[0;31m'
C_RESET='\033[0m'

echo -e "${C_TITLE}=== Modell-Ordner Synchronisation (Einweg) ===${C_RESET}"
echo -e "Quelle: ${C_PATH}${SOURCE_DIR}${C_RESET}"
echo -e "Ziel:   ${C_PATH}${TARGET_DIR}${C_RESET}\n"

# Prüfen, ob Quellordner existiert
if [ ! -d "$SOURCE_DIR" ]; then
    echo -e "${C_RED}FEHLER: Quellordner '$SOURCE_DIR' wurde nicht gefunden!${C_RESET}"
    exit 1
fi

# Zielordner erstellen, falls nicht vorhanden
mkdir -p "$TARGET_DIR"

# Synchronisation ausführen:
# -a          : Archiv-Modus (Rechte, Datumsstempel, Unterordner beibehalten)
# -v          : Ausführliche Ausgabe
# -h          : Menschenlesbare Dateigrößen (GB, MB)
# --delete    : Löscht Dateien im Ziel, die in der Quelle gelöscht wurden
# --progress  : Fortschrittsanzeige für große Dateien
rsync -avh --exclude 'downloading_*' --delete --progress "$SOURCE_DIR/" "$TARGET_DIR/"

if [ $? -eq 0 ]; then
    echo -e "\n${C_GREEN}Synchronisation erfolgreich abgeschlossen!${C_RESET}"
else
    echo -e "\n${C_RED}Synchronisation mit Fehlern beendet.${C_RESET}"
fi