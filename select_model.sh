#!/bin/bash

# Dieses Skript ist für die Suche und Auswahl von .gguf Modell-Dateien zuständig.
# Es setzt die Variable MODEL_PATH für das aufrufende Skript.

echo -e "${C_TITLE}=== 1. Prüfe Modell-Ordner ===${C_RESET}"
if [ ! -d "$MODELS_DIR" ]; then
    echo -e "${C_RED}FEHLER: Ordner $MODELS_DIR existiert nicht oder WSL2 hat keinen Zugriff!${C_RESET}"
    exit 1
fi

echo -e "${C_TITLE}=== 2. Suche .gguf Dateien (neueste zuerst) ===${C_RESET}"

# Suche .gguf Dateien, sortiere nach Datum, aber schließe "mmproj-" Dateien aus
mapfile -t models < <(find "$MODELS_DIR" -type f -name "*.gguf" ! -name "mmproj-*" -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)

if [ ${#models[@]} -eq 0 ]; then
    echo -e "${C_RED}FEHLER: Keine .gguf Dateien in $MODELS_DIR gefunden!${C_RESET}"
    exit 1
fi

LAST_MODEL_INDEX=""

echo -e "\nGefundene Modelle:\n"
for i in "${!models[@]}"; do
    file="${models[$i]}"
    filename=$(basename "$file")
    
    # Dateigröße in GB berechnen
    bytes=$(stat -c%s "$file" 2>/dev/null || echo 0)
    size_gb=$(awk -v b="$bytes" 'BEGIN {printf "%.2f GB", b/1073741824}')
    
    # Pfad ohne Basis-Ordner ermitteln
    rel_path="${file#$MODELS_DIR/}"
    dir_path=$(dirname "$rel_path")
    if [ "$dir_path" == "." ]; then
        dir_path="Hauptverzeichnis"
    fi

    # Prüfen, ob dies das zuletzt genutzte Modell ist
    latest_tag=""
    if [ "$file" == "$LAST_MODEL" ]; then
        latest_tag=" ${C_HIGHLIGHT}[Zuletzt verwendet]${C_RESET}"
        LAST_MODEL_INDEX=$((i+1))
    fi

    echo -e "  \033[1;33m[$((i+1))]${C_RESET} ${C_SIZE}[${size_gb}]${C_RESET} ${C_FILE}${filename}${C_RESET} ${C_PATH}(${dir_path})${C_RESET}${latest_tag}"
done

# Modell-Auswahl
if [ -n "$LAST_MODEL_INDEX" ]; then
    echo -e "\nBitte wähle eine Modell-Nummer (1-${#models[@]}) [Enter für Zuletzt verwendet (${LAST_MODEL_INDEX})]: "
else
    echo -e "\nBitte wähle eine Modell-Nummer (1-${#models[@]}): "
fi
read -r choice

# Standard auf letzte Auswahl setzen bei leerer Eingabe
if [ -z "$choice" ] && [ -n "$LAST_MODEL_INDEX" ]; then
    choice=$LAST_MODEL_INDEX
fi

if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#models[@]}" ]; then
    echo -e "${C_RED}Ungültige Auswahl! Abbruch.${C_RESET}"
    exit 1
fi

MODEL_PATH="${models[$((choice-1))]}"
echo -e "\nGewähltes Modell: ${C_FILE}$(basename "$MODEL_PATH")${C_RESET}"