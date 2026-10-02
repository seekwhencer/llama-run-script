#!/bin/bash
#
# Sichere und optimierte Version mit:
# - set -euo pipefail für strenge Fehlerbehandlung
# - Array-basierter Befehlsausführung (keine eval)
# - Dynamische VRAM-Schätzung basierend auf KV-Quantisierung
# - Sauberes Caching & Cleanup via trap
# - TTY-Farbdetektion

set -euo pipefail

# Dieses script ist für zwei nvidia RTX mit insg. 32 GB (2x16GB) VRAM

# Model-Ordner im WSL2
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
MODELS_DIR="$SCRIPT_DIR/models"
CONFIG_FILE="$SCRIPT_DIR/.llama_load_last"
CACHE_DIR="$SCRIPT_DIR/meta"
DEFAULT_CONTEXT=32768
CONTEXT_STEP=16384
PRESET_CONTEXT=32768
NUM_STEPS=16
CUSTOM_OPTION=$((NUM_STEPS + 2))

# --- Farbdefinitionen (nur im Terminal aktivieren) ---
if [ -t 1 ]; then
    C_SIZE='\033[0;36m'    # Cyan für Größe
    C_FILE='\033[0;32m'    # Grün für Dateiname
    C_PATH='\033[0;33m'    # Gelb für Pfad
    C_TITLE='\033[1;34m'   # Fett Blau für Überschriften
    C_RESET='\033[0m'      # Standard zurücksetzen
    C_RED='\033[0;31m'     # Rot für Fehler/Warnung (>32GB)
    C_GREEN='\033[0;32m'   # Grün für VRAM OK (<=32GB)
    C_HIGHLIGHT='\033[7m'  # Invertiert/Hervorgehoben
else
    C_SIZE=C_FILE=C_PATH=C_TITLE=C_RESET=C_RED=C_GREEN=C_HIGHLIGHT=""
fi

# Letzte Auswahl sicher laden (ohne source, um Code-Injection zu vermeiden)
LAST_MODEL=""
LAST_CONTEXT=""
if [ -f "$CONFIG_FILE" ]; then
    LAST_MODEL=$(grep '^LAST_MODEL=' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2 || echo "")
    LAST_CONTEXT=$(grep '^LAST_CONTEXT=' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2 || echo "")
fi

# -----------------------------------------------------------------
# Modell-Auswahl über separates Skript einbinden
# -----------------------------------------------------------------

if [ -f "$SCRIPT_DIR/select_model.sh" ]; then
    source "$SCRIPT_DIR/select_model.sh"
else
    echo -e "${C_RED}FEHLER: select_model.sh wurde nicht im Verzeichnis $SCRIPT_DIR gefunden!${C_RESET}"
    exit 1
fi

# --- Cache-Dateien definieren ---
# WICHTIG: Wir trennen den Metadaten-Dump (.meta) von den Token-Empfehlungen (.tokens)
# um zu verhindern, dass load.sh den Dump überschreibt und check_kv.sh falsche Werte berechnet.
META_DUMP_FILE="${CACHE_DIR}/$(echo -n "$MODEL_PATH" | md5sum | awk '{print $1}').meta"
TOKEN_CACHE_FILE="${CACHE_DIR}/$(echo -n "$MODEL_PATH" | md5sum | awk '{print $1}').tokens"

# echo -e "\n${C_TITLE}=== Cache Files ===${C_RESET}" 
# echo -e "Dump:  ${META_DUMP_FILE}"
# echo -e "Token: ${TOKEN_CACHE_FILE}"

# Aktuelle Auswahl für das nächste Mal speichern
echo "LAST_MODEL=\"$MODEL_PATH\"" > "$CONFIG_FILE"

# Kapazitätscheck ausführen
if [ -f "$SCRIPT_DIR/check_kv.sh" ]; then
    echo -e "\n${C_TITLE}=== KV-Cache Kapazitätscheck ===${C_RESET}"
    # || true verhindert, dass set -e das Script abbricht, falls check_kv.sh einen Fehlercode liefert
    bash "$SCRIPT_DIR/check_kv.sh" "$MODEL_PATH" || true
    
    # Vorschlag berechnen und in separater Datei speichern
    bash "$SCRIPT_DIR/check_kv.sh" "--export" "$MODEL_PATH" > "${TOKEN_CACHE_FILE}" || true
fi

# Modellgröße in GB ermitteln für VRAM-Berechnung
MODEL_BYTES=$(stat -c%s "$MODEL_PATH" 2>/dev/null || echo 0)
MODEL_GB=$(awk -v b="$MODEL_BYTES" 'BEGIN {printf "%.2f", b/1073741824}')

if [ "$MODEL_PATH" == "$LAST_MODEL" ] && [ -n "$LAST_CONTEXT" ]; then
    PRESET_CONTEXT=$LAST_CONTEXT
else
    PRESET_CONTEXT=$DEFAULT_CONTEXT
fi

# 3. MTP (Multi-Token Prediction) konfigurieren
MTP_PARAMS=""
echo -e "\n${C_TITLE}=== 3. MTP (Multi-Token Prediction) ===${C_RESET}"
echo -n "Anzahl Vorhersagen pro Schritt (--spec-draft-n-max)? (0 = aus): "
read -r -t 30 mtp_n || true

if [[ "$mtp_n" =~ ^[0-9]+$ ]] && [ "$mtp_n" -ge 1 ]; then
    MTP_PARAMS=" --spec-type draft-mtp --spec-draft-n-max $mtp_n"
    echo -e "${C_GREEN}MTP aktiviert mit $mtp_n Vorhersagen.${C_RESET}"

    # --spec-draft-p-min nach --spec-draft-n-max
    echo -n "Minimale Wahrscheinlichkeit (--spec-draft-p-min)? (z. B. 0.1, leer = Standard): "
    read -r -t 30 mtp_pmin || true
    if [[ "$mtp_pmin" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v v="$mtp_pmin" 'BEGIN {exit !(v >= 0 && v < 1)}'; then
        MTP_PARAMS="$MTP_PARAMS --spec-draft-p-min $mtp_pmin"
        echo -e "${C_GREEN}--spec-draft-p-min auf $mtp_pmin gesetzt.${C_RESET}"
    elif [ -n "$mtp_pmin" ]; then
        echo -e "${C_PATH}Ungültiger Wert ($mtp_pmin), --spec-draft-p-min wird übersprungen.${C_RESET}"
    fi
else
    echo -e "${C_PATH}MTP wird nicht verwendet (0 oder keine Eingabe).${C_RESET}"
fi

# 4. Preserve Reasoning / Thinking konfigurieren
REASONING_PARAMS=""
echo -e "\n${C_TITLE}=== 4. Enable Reasoning / Thinking ===${C_RESET}"
echo -n "Parameter --reasoning aktivieren? [J/n]: "
read -r -t 30 reason_choice || true
reason_choice=$(echo "$reason_choice" | tr '[:upper:]' '[:lower:]')

if [ -z "$reason_choice" ] || [ "$reason_choice" == "j" ] || [ "$reason_choice" == "ja" ] || [ "$reason_choice" == "y" ] || [ "$reason_choice" == "yes" ]; then
    REASONING_PARAMS=" --reasoning on"
    echo -e "${C_GREEN}Reasoning/Thinking wird aktiviert.${C_RESET}"
else
    echo -e "${C_PATH}Reasoning/Thinking wird nicht verwendet.${C_RESET}"
    REASONING_PARAMS=" --reasoning off"
fi

# 5. Temperature konfigurieren
TEMP_PARAMS=""
echo -e "\n${C_TITLE}=== 5. Temperature ===${C_RESET}"
echo -n "Temperature (--temp) Wert eingeben (z. B. 0.6 oder 0.7, Enter für Standard/aus): "
read -r -t 30 temp_val || true

if [ -n "$temp_val" ]; then
    TEMP_PARAMS=" --temp $temp_val"
    echo -e "${C_GREEN}Temperature auf $temp_val gesetzt.${C_RESET}"
else
    echo -e "${C_PATH}Standard-Temperature wird verwendet.${C_RESET}"
fi

# KV-Cache Quantisierung erfragen
KV_QUANT_PARAMS=""
KV_FACTOR=2.0 # Standard f16

echo -e "\n${C_TITLE}=== KV-Cache Quantisierung ===${C_RESET}"
echo -e "  0) Keine"
echo -e "  1) 4 Bit (q4_0)"
echo -e "  2) 8 Bit (q8_0)"
echo -e "  3) 16 Bit (f16)"
echo -n "Wähle KV-Cache Quantisierung (0-3) [Enter für 2 (8 Bit)]: "
read -r -t 30 kv_choice || true

case "$kv_choice" in
    1)
        KV_QUANT_PARAMS=" -ctk q4_0 -ctv q4_0"
        KV_FACTOR=0.5625
        echo -e "${C_GREEN}KV-Cache Quantisierung (4 Bit / q4_0) wird verwendet.${C_RESET}"
        ;;
    2|"")
        KV_QUANT_PARAMS=" -ctk q8_0 -ctv q8_0"
        KV_FACTOR=1.0625
        echo -e "${C_GREEN}KV-Cache Quantisierung (8 Bit / q8_0) wird verwendet.${C_RESET}"
        ;;
    3)
        KV_QUANT_PARAMS=" -ctk f16 -ctv f16"
        KV_FACTOR=2.0
        echo -e "${C_GREEN}KV-Cache Quantisierung (16 Bit / f16) wird verwendet.${C_RESET}"
        ;;
    0|*)
        KV_QUANT_PARAMS=""
        KV_FACTOR=2.0
        echo -e "${C_PATH}Standard KV-Cache (keine explizite Quantisierung) wird verwendet.${C_RESET}"
        ;;
esac

# Hilfsfunktion zur VRAM-Berechnung und farbigen Formatierung
get_vram_info() {
    local ctx=$1
    # VRAM Formel: Modellgröße + KV Cache (basierend auf Faktor) + Buffer (1.5GB)
    local vram=$(awk -v m="$MODEL_GB" -v c="$ctx" -v f="$KV_FACTOR" \
        'BEGIN {printf "%.1f", m + (c * 2 * 32 * 8 * 128 * f / 1073741824) + 1.5}' 2>/dev/null || echo "0.0")
    
    # Prüfen, ob VRAM > 32GB ist
    local is_over=$(awk -v v="$vram" 'BEGIN {if (v > 32.0) print 1; else print 0}' 2>/dev/null || echo 0)
    is_over=${is_over:-0}
    
    if [ "$is_over" -eq 1 ]; then
        echo -e "${C_RED}~${vram} GB VRAM [>32GB!]${C_RESET}"
    else
        echo -e "${C_GREEN}~${vram} GB VRAM [OK]${C_RESET}"
    fi
}

# 6. Kontext-Größe auswählen
echo -e "\n${C_TITLE}=== 6. Kontext-Größe (-c) wählen (Schrittweite: ${CONTEXT_STEP}) ===${C_RESET}"

# Vorschlag anzeigen
if [ -f "${TOKEN_CACHE_FILE}" ]; then
    read -r SUGGEST_F16 SUGGEST_Q8 SUGGEST_Q4 < "${TOKEN_CACHE_FILE}" || true
    # Nur anzeigen, wenn Werte plausibel sind (nicht 0 oder leer)
    if [ -n "$SUGGEST_F16" ] && [ "$SUGGEST_F16" -gt 0 ] 2>/dev/null; then
        echo -e "${C_PATH}Empfohlene Maxima basierend auf VRAM:${C_RESET}"
        echo -e "  - f16: ${C_SIZE}$SUGGEST_F16${C_RESET} | q8_0: ${C_SIZE}$SUGGEST_Q8${C_RESET} | q4_0: ${C_SIZE}$SUGGEST_Q4${C_RESET}"
        echo ""
    fi
fi

preset_vram_tag=$(get_vram_info "$PRESET_CONTEXT")
echo -e "  1) Vorgabe / Letzter Wert ($PRESET_CONTEXT) -> $preset_vram_tag"

for i in $(seq 1 $NUM_STEPS); do
    ctx=$((i * CONTEXT_STEP))
    vram_tag=$(get_vram_info "$ctx")
    printf " %2d) %-7d -> %b\n" $((i+1)) "$ctx" "$vram_tag"
done

echo -e " ${CUSTOM_OPTION}) Benutzerdefinierter Wert"

echo -e "\nBitte wähle den Kontext (1-${CUSTOM_OPTION}) [Enter für $PRESET_CONTEXT]: "
read -r -t 30 ctx_choice || true

if [ -z "$ctx_choice" ] || [ "$ctx_choice" -eq 1 ]; then
    FINAL_CONTEXT=$PRESET_CONTEXT
elif [ "$ctx_choice" -eq "$CUSTOM_OPTION" ]; then
    echo -n "Eigener Kontext-Wert: "
    read -r -t 30 FINAL_CONTEXT || true
    if ! [[ "$FINAL_CONTEXT" =~ ^[0-9]+$ ]]; then
        FINAL_CONTEXT=$PRESET_CONTEXT
    fi
elif [[ "$ctx_choice" =~ ^[0-9]+$ ]] && [ "$ctx_choice" -ge 2 ] && [ "$ctx_choice" -le $((NUM_STEPS + 1)) ]; then
    FINAL_CONTEXT=$(( (ctx_choice - 1) * CONTEXT_STEP ))
else
    FINAL_CONTEXT=$PRESET_CONTEXT
fi

# Aktuelle Auswahl für das nächste Mal speichern
# echo "LAST_MODEL=\"$MODEL_PATH\"" > "$CONFIG_FILE"
echo "LAST_CONTEXT=\"$FINAL_CONTEXT\"" >> "$CONFIG_FILE"

# Befehl definieren (Array für sichere Ausführung)
CMD_ARGS=(
    llama serve
    -ngl 99 -ts 1,1 -mg 1 -fa on -sm layer
    -c "$FINAL_CONTEXT"
    --repeat-penalty 1.0
    --repeat-last-n 128
    $KV_QUANT_PARAMS $MTP_PARAMS $REASONING_PARAMS $TEMP_PARAMS
    --port 11434 --host 0.0.0.0
    -m "$MODEL_PATH"
)

# 7. Llama Server ausführen & Befehl anzeigen
echo -e "\n${C_TITLE}=== 7. Starte llama server ===${C_RESET}"
echo -e "Modell:  ${C_FILE}$MODEL_PATH${C_RESET}"
echo -e "Kontext: ${C_SIZE}$FINAL_CONTEXT${C_RESET}"
echo -e "Befehl:  ${C_PATH}${CMD_ARGS[*]}${C_RESET}\n"

# Sichere Ausführung ohne eval
exec "${CMD_ARGS[@]}"