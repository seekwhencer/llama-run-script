#!/bin/bash

# --- Konfiguration & Farben ---
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# Konfiguration aus .env laden (Fallback auf .env.default)
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
elif [ -f "$SCRIPT_DIR/.env.default" ]; then
    set -a
    source "$SCRIPT_DIR/.env.default"
    set +a
fi

MODELS_DIR="${MODELS_DIR}"
C_TITLE='\033[1;34m'   # Fett Blau
C_FILE='\033[0;32m'    # Grün
C_RESET='\033[0m'      # Reset
C_RED='\033[0;31m'     # Rot
C_GREEN='\033[0;32m'   # Grün (für MTP Erfolg)

# 1. Modell auswählen oder über Argument erhalten
if [ -n "$1" ]; then
    MODEL_PATH="$1"
else
    if [ -f "$SCRIPT_DIR/select_model.sh" ]; then
        source "$SCRIPT_DIR/select_model.sh"
    else
        echo -e "${C_RED}FEHLER: select_model.sh wurde nicht im Verzeichnis $SCRIPT_DIR gefunden!${C_RESET}"
        exit 1
    fi
fi

# Prüfen, ob MODEL_PATH jetzt gesetzt ist
if [ -z "$MODEL_PATH" ]; then
    echo -e "${C_RED}FEHLER: Kein Modell ausgewählt.${C_RESET}"
    exit 1
fi

# Prüfen, ob die Datei existiert
if [ ! -f "$MODEL_PATH" ]; then
    echo -e "${C_RED}FEHLER: Datei $MODEL_PATH nicht gefunden!${C_RESET}"
    exit 1
fi

# 2. Prüfen, ob gguf-dump installiert ist
if ! command -v gguf-dump &> /dev/null; then
    echo -e "${C_RED}FEHLER: 'gguf-dump' wurde nicht gefunden.${C_RESET}"
    echo -e "Bitte installiere es mit: ${C_FILE}pip install gguf${C_RESET}"
    exit 1
fi

# 3. Metadaten extrahieren und gezielt nach MTP (predict_layers) suchen
echo -e "\n${C_TITLE}=== GGUF MTP Check: $(basename "$MODEL_PATH") ===${C_RESET}"
echo -e "${C_FILE}$MODEL_PATH${C_RESET}"
echo -e "----------------------------------------------------------"

# Den Dump in einer Variable speichern, um ihn nur einmal zu berechnen
METADATA_DUMP=$(gguf-dump "$MODEL_PATH")

# Gezielte Suche nach predict_layers (case-insensitive)
MTP_LAYERS=$(echo "$METADATA_DUMP" | grep -i "predict_layers")

if [ -n "$MTP_LAYERS" ]; then
    echo -e "${C_GREEN}>>> MULTI-TOKEN PREDICTION (MTP) AKTIV <<<${C_RESET}"
    # Die Zeile farbig hervorheben
    echo -e "${C_GREEN}$MTP_LAYERS${C_RESET}"
else
    echo -e "${C_RED}>>> Keine 'predict_layers' gefunden (MTP nicht unterstützt/aktiv). <<<${C_RESET}"
fi

echo -e "----------------------------------------------------------"
echo -e "${C_TITLE}=== Ende der Analyse ===${C_RESET}"