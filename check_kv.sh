#!/usr/bin/env bash

# Wir entfernen set -e für den kritischen Teil, um Fehlermeldungen nicht zu unterdrücken
set -uo pipefail

# ================= KONFIGURATION =================
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CACHE_DIR="$SCRIPT_DIR/meta"

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
# =================================================

mkdir -p "$CACHE_DIR"

EXPORT_MODE=false
if [[ "${1:-}" == "--export" ]]; then
    EXPORT_MODE=true
    shift
fi

if [ -z "${1:-}" ]; then
    echo "Verwendung: $0 [--export] <pfad-zur-modelldatei.gguf>"
    exit 1
fi

MODEL_PATH="$1"

if [ ! -f "$MODEL_PATH" ]; then
    echo "Fehler: Datei '$MODEL_PATH' nicht gefunden."
    exit 1
fi

META_CACHE_FILE="${CACHE_DIR}/$(echo -n "$MODEL_PATH" | md5sum | awk '{print $1}').meta"

# Modellgröße ermitteln
MODEL_BYTES=$(stat -c%s "$MODEL_PATH" 2>/dev/null || stat -f%z "$MODEL_PATH")
MODEL_GB=$(awk "BEGIN {printf \"%.2f\", $MODEL_BYTES / (1024^3)}")
FREE_VRAM_GB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_VRAM_GB - $SYSTEM_OVERHEAD_GB - $MODEL_GB}")

if [ "$EXPORT_MODE" = "false" ]; then
    echo "================ SPEICHERÜBERSICHT ================"
    echo "Gesamter VRAM:         ${TOTAL_VRAM_GB}.00 GB"
    echo "System- / CUDA-Puffer: ${SYSTEM_OVERHEAD_GB}.00 GB"
    echo "Modellgröße:           ${MODEL_GB} GB"
    echo "---------------------------------------------------"
    echo "Verfügbar für KV:      ${FREE_VRAM_GB} GB"
    echo "==================================================="
fi

# --- METADATEN GENERIERUNG ---
if [ ! -f "$META_CACHE_FILE" ] || [ ! -s "$META_CACHE_FILE" ]; then
    echo "Erzeuge Metadaten-Cache..."
    
    # Finde den Befehl (nutze 'command', um Aliases zu umgehen)
    GGUF_CMD=""
    if command -v gguf-dump &> /dev/null; then
        GGUF_CMD="command gguf-dump"
    elif python3 -c "import gguf" &> /dev/null; then
        GGUF_CMD="python3 -m gguf.dump"
    fi

    if [ -z "$GGUF_CMD" ]; then
        echo "Fehler: 'gguf-dump' nicht gefunden."
        exit 1
    fi

    # Nutze eine temporäre Datei für den Dump
    TMP_FILE=$(mktemp)
    
    # Führe den Befehl aus und fange stderr ab
    if ! $GGUF_CMD "$MODEL_PATH" > "$TMP_FILE" 2>&1; then
        echo "!!! FEHLER beim Ausführen von $GGUF_CMD !!!"
        cat "$TMP_FILE"
        rm -f "$TMP_FILE"
        exit 1
    fi

    # Prüfe, ob die Datei wirklich Inhalt hat
    if [ ! -s "$TMP_FILE" ]; then
        echo "!!! FEHLER: Der Dump ist leer !!!"
        echo "Versuche Notfall-Test (direkt in Terminal):"
        $GGUF_CMD "$MODEL_PATH" | head -n 10
        rm -f "$TMP_FILE"
        exit 1
    fi

    # Wenn alles okay ist, verschiebe die Datei in den Cache
    mv "$TMP_FILE" "$META_CACHE_FILE"
    echo "Cache erfolgreich erstellt."
fi

# Hilfsfunktion zum Extrahieren
extract_meta() {
    local key="$1"
    # Wir greifen direkt auf die Datei zu, um RAM-Probleme zu vermeiden
    # GGUF-Dump-Zeilen beginnen mit Offset/Typ-Spalte, daher nach dem | - Trenner suchen
    grep -i "[|][[:space:]]*${key}[[:space:]]*[=:]" "$META_CACHE_FILE" | head -n 1 | sed -E 's/^[^=]*=[[:space:]]*//' | tr -d ' '"'"' "[:space:]'
}

# --- PARSING ---
ARCH=$(extract_meta "general.architecture")
ARCH=${ARCH:-llama}

LAYERS=$(extract_meta "${ARCH}.block_count")
LAYERS=${LAYERS:-32}

HEADS_KV=$(extract_meta "${ARCH}.attention.head_count_kv")
if [ -z "$HEADS_KV" ]; then
    HEADS_KV=$(extract_meta "${ARCH}.attention.head_count")
fi
HEADS_KV=${HEADS_KV:-8}

HEAD_DIM=$(extract_meta "${ARCH}.attention.key_length")
if [ -z "$HEAD_DIM" ]; then
    EMBEDDING_LEN=$(extract_meta "${ARCH}.embedding_length")
    HEADS_ALL=$(extract_meta "${ARCH}.attention.head_count")
    if [ -n "$EMBEDDING_LEN" ] && [ -n "$HEADS_ALL" ] && [ "$HEADS_ALL" -ne 0 ] 2>/dev/null; then
        HEAD_DIM=$((EMBEDDING_LEN / HEADS_ALL))
    else
        HEAD_DIM=128
    fi
fi

MAX_TRAINED_CTX=$(extract_meta "${ARCH}.context_length")
MAX_TRAINED_CTX=${MAX_TRAINED_CTX:-131072}

if [ "$EXPORT_MODE" = "false" ]; then
    echo "Modell-Metadaten:"
    echo " - Architektur:               $ARCH"
    echo " - Schichten (Layers):        $LAYERS"
    echo " - KV-Heads:                  $HEADS_KV"
    echo " - Head Dimension:            $HEAD_DIM"
    echo " - Max. trainierter Kontext:  $MAX_TRAINED_CTX Tokens"
    echo "---------------------------------------------------"
    echo "Berechnete maximale Kontextgrößen (-c):"
fi

# --- BERECHNUNG ---
calc_tokens() {
    local bpe="$2"
    awk -v free_gb="$FREE_VRAM_GB" \
        -v layers="$LAYERS" \
        -v heads_kv="$HEADS_KV" \
        -v head_dim="$HEAD_DIM" \
        -v bpe="$bpe" \
        -v max_ctx="$MAX_TRAINED_CTX" '
    BEGIN {
        free_bytes = free_gb * 1073741824
        bytes_per_token = (2 * layers * heads_kv * head_dim) * bpe
        if (bytes_per_token <= 0) { print 0; exit }
        tokens = int(free_bytes / bytes_per_token)
        tokens_rounded = int(tokens / 512) * 512
        if (tokens_rounded > max_ctx) tokens_rounded = max_ctx
        if (tokens_rounded < 0) tokens_rounded = 0
        print tokens_rounded
    }'
}

if [ "$EXPORT_MODE" = "true" ]; then
    V1=$(calc_tokens "f16" 2.0)
    V2=$(calc_tokens "q8_0" 1.0625)
    V3=$(calc_tokens "q4_0" 0.5625)
    echo "$V1 $V2 $V3"
else
    for entry in "Standard (f16):2.0" "q8_0 (-ctk/-ctv):1.0625" "q4_0 (-ctk/-ctv):0.5625"; do
        NAME="${entry%%:*}"
        BPE="${entry#*:}"
        VAL=$(calc_tokens "$NAME" "$BPE")
        printf "  * %-20s -> max. %7d Tokens (-c %d)\n" "$NAME" "$VAL" "$VAL"
    done
    echo "==================================================="
fi