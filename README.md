# Llama Server Launcher

Ein Satz von Bash-Skripten zum Verwalten, Auswählen und Starten von GGUF-Modellen über den [`llama.cpp`](https://github.com/ggml-org/llama.cpp) Server (`llama serve`) auf einem System mit NVIDIA RTX Grafikkarten (konfiguriert für 2×16 GB = 32 GB VRAM).

Die Skripte sind für die Nutzung unter **WSL2** ausgelegt und greifen auf Modelle zu, die mit [LM Studio](https://lmstudio.ai/) heruntergeladen wurden.

---

## Funktionen

- **Interaktive Modell-Auswahl** aus allen gefundenen `.gguf`-Dateien (neueste zuerst), sortiert nach Änderungsdatum.
- **VRAM-basierte Kontext-Berechnung**: Schätzt die maximale Kontextgröße (`-c`) basierend auf der Modellgröße, der verfügbaren VRAM-Kapazität und der gewählten KV-Cache-Quantisierung.
- **MTP-Support** (Multi-Token Prediction): Konfiguration von `--spec-type draft-mtp` für beschleunigtes Inferenz bei MTP-Modellen.
- **Reasoning/Thinking**: Optionales Aktivieren von `--reasoning on` für reasoning-fähige Modelle.
- **KV-Cache-Quantisierung**: Wähle zwischen 4 Bit (`q4_0`), 8 Bit (`q8_0`) und 16 Bit (`f16`) für den KV-Cache (`-ctk`/`-ctv`).
- **Persistierte Einstellungen**: Das zuletzt verwendete Modell und der zuletzt gewählte Kontext werden gespeichert und beim nächsten Start vorgeschlagen.
- **Caching von Metadaten**: GGUF-Metadaten werden einmalig gecacht, um wiederholtes Parsen zu vermeiden.
- **Modell-Synchronisation**: Einweg-Synchronisation von LM-Studio-Modellen in den lokalen `models/`-Ordner.
- **Cache-Leeren**: Skript zum Freigeben von System-Speicher (`drop_caches`).

---

## Verzeichnisstruktur

```
.
├── README.md                 # Diese Datei
├── load.sh                   # Hauptskript: Modell starten (llama serve)
├── select_model.sh           # Interaktive Auswahl einer .gguf-Datei
├── check_kv.sh               # KV-Cache-Kapazitätscheck & Kontext-Empfehlung
├── gguf.sh                   # GGUF-MTP-Check (predict_layers)
├── sync_models.sh            # Synchronisation von LM-Studio-Modellen
├── free_mem.sh               # Leert System-Caches (drop_caches)
├── models/                   # Lokale Modell-Instanz via sync_models.sh 
├── meta/                     # Gecachte GGUF-Metadaten
├── .gitignore                # Ignoriert models/, meta/, .llama_load_last und .env
└── .llama_load_last          # Persistierte Auswahl (LAST_MODEL, LAST_CONTEXT)
```

---

## Skripte im Detail

### `load.sh` — Server starten

Das Hauptskript führt die interaktive Modell-Auswahl aus und startet den `llama serve`-Prozess mit den gewählten Parametern.

```bash
bash load.sh
```

**Interaktive Schritte:**

1. **Modell-Auswahl** (via `select_model.sh`) — wähle eine `.gguf`-Datei aus der Liste.
2. **KV-Cache-Kapazitätscheck** (via `check_kv.sh`) — zeigt Speicherübersicht und empfohlene Maxima.
3. **MTP (Multi-Token Prediction)** — Anzahl Vorhersagen pro Schritt (`--spec-draft-n-max`) und optionale minimale Wahrscheinlichkeit (`--spec-draft-p-min`). `0` oder leer deaktiviert MTP.
4. **Reasoning/Thinking** — `--reasoning on/off`.
5. **Temperature** — `--temp` Wert (leer = Standard).
6. **KV-Cache-Quantisierung** — `0` keine, `1` q4_0, `2` q8_0 (Standard), `3` f16.
7. **Kontext-Größe** (`-c`) — Vorgabe/letzter Wert, feste Stufen (Schrittweite 16384 Tokens, 16 Stufen) oder benutzerdefinierter Wert.

**Erstellter Befehl** (Beispiel):

```bash
llama serve \
  -ngl 99 -ts 1,1 -mg 1 -fa on -sm layer \
  -c 32768 -ctk q8_0 -ctv q8_0 \
  --port 11434 --host 0.0.0.0 \
  -m "/path/to/model.gguf"
```

Die gewählte Kontextgröße wird in `.llama_load_last` gespeichert und beim nächsten Start vorgeschlagen.

---

### `select_model.sh` — Modell auswählen

Wird von `load.sh` eingebunden (`source`). Listet alle `.gguf`-Dateien in `models/` auf (sortiert nach Änderungsdatum, absteigend) und schließt `mmproj-*`-Dateien (Vision-Projektoren) aus. Das zuletzt verwendete Modell wird mit `[Zuletzt verwendet]` markiert.

Setzt die Variable `MODEL_PATH` für das aufrufende Skript.

---

### `check_kv.sh` — KV-Cache-Kapazitätscheck

Berechnet, wie viele Tokens bei gegebener VRAM-Kapazität und KV-Cache-Quantisierung speicherbar sind.

```bash
# Interaktive Anzeige (Speicherübersicht + Metadaten + Empfehlungen)
bash check_kv.sh /path/to/model.gguf

# Export-Modus (nur die drei Token-Werte: f16 q8_0 q4_0)
bash check_kv.sh --export /path/to/model.gguf
```

**Berechnungsgrundlage:**

- `TOTAL_VRAM_GB` und `SYSTEM_OVERHEAD_GB` sind in `.env` (oder `.env.default`) konfiguriert (Standard: 32 GB / 2 GB).
- Der KV-Cache pro Token wird aus Architektur-Metadaten abgeleitet:
  `bytes_per_token = 2 × layers × heads_kv × head_dim × bpe_factor`
- Das Ergebnis wird auf 512 Tokens aufgerundet und auf den trainierten Maximalkontext (`context_length`) begrenzt.

**Ergebnis (interaktiv):**

```
Empfohlene Maxima basierend auf VRAM:
  - Standard (f16):        -> max.  32768 Tokens (-c 32768)
  - q8_0 (-ctk/-ctv):      -> max.  65536 Tokens (-c 65536)
  - q4_0 (-ctk/-ctv):      -> max. 131072 Tokens (-c 131072)
```

**Ergebnis (`--export`):**

```
32768 65536 131072
```

Metadaten werden in `meta/<md5>.meta` gecacht; die Token-Empfehlungen in `meta/<md5>.tokens`.

---

### `gguf.sh` — MTP-Check

Prüft, ob ein GGUF-Modell Multi-Token Prediction unterstützt, indem es nach der Metadaten-Option `predict_layers` sucht.

```bash
bash gguf.sh /path/to/model.gguf
# oder ohne Argument (wählt über select_model.sh)
bash gguf.sh
```

> **Hinweis:** `gguf.sh` liest `MODELS_DIR` aus `.env` (Fallback auf `.env.default`).

Erfordert `gguf-dump` (via `pip install gguf`).

---

### `sync_models.sh` — Modelle synchronisieren

Einweg-Synchronisation von LM-Studio-Modellen in den lokalen `models/`-Ordner (mit `rsync --delete`). Exkludiert `downloading_*`-Temporärdateien.

```bash
bash sync_models.sh
```

Die Konfiguration wird aus `.env` geladen (Fallback auf `.env.default`). Dort kann `SOURCE_DIR` angepasst werden:

```bash
SOURCE_DIR="/change/me"
```

---

### `free_mem.sh` — Speicher freigeben

Leert die System-Caches, um mehr RAM für das Modell zur Verfügung zu haben.

```bash
bash free_mem.sh
```

Erfordert `sudo`-Privilegien (`sync` + `drop_caches`).

---

## Voraussetzungen

- **WSL2** mit Zugriff auf die NVIDIA-Grafikkarte.
- [`llama.cpp`](https://github.com/ggml-org/llama.cpp) mit `llama serve` auf dem `PATH`.
- `gguf-dump` für Metadaten-Analysen:

  ```bash
  pip install gguf
  ```

- `rsync` für die Modell-Synchronisation.
- Optional: `ollama` mit Embedding-Modell (z. B. `bge-m3`)

---

## Konfiguration

Werte, die ggf. an das eigene System angepasst werden sollten:

| Variable | Standard | Bedeutung |
|---|---|---|
| `TOTAL_VRAM_GB` | `32` | Gesamter VRAM in GB (in `.env`) |
| `SYSTEM_OVERHEAD_GB` | `2` | Puffer für System/CUDA (in `.env`) |
| `DEFAULT_CONTEXT` | `32768` | Standard-Kontext in Tokens (in `.env`) |
| `CONTEXT_STEP` | `16384` | Schrittweite der Kontext-Stufen (in `.env`) |
| `SOURCE_DIR` | `/change/me` | Quellordner der LM-Studio-Modelle (in `.env`) |

---

## Typischer Workflow

1. **Modelle synchronisieren** (einmalig oder regelmäßig):

   ```bash
   bash sync_models.sh
   ```

2. **Speicher freigeben** (optional, vor dem Start):

   ```bash
   bash free_mem.sh
   ```

3. **MTP-Support prüfen** (bei neuen Modellen):

   ```bash
   bash gguf.sh models/peculiar-ragdoll/Tiel-Coder-35B-A3B-GGUF-MTP/Tiel-Coder-35B-A3B-MTP-UD-Q4_K_S.gguf
   ```

4. **Server starten**:

    ```bash
    bash load.sh
    ```

---
