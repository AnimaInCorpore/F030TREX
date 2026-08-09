# F030TREX

Alles, was zum Bauen von `trex.tos` nötig ist: ein Falcon030-Port (16 MHz,
DSP56001) des T-Rex-Renderers aus PS1 Demo One (SCES-00048). Dieses
Repository ist ein schlanker Build-Auszug aus dem Forschungs-/Messrepo
`f030dsp3d` -- siehe unten, was bewusst fehlt.

## Bauen

Voraussetzungen: `node`, `python3`, ein C-Compiler/`make` für vasm und vlink
(werden aus den mitgelieferten Tarballs gebaut), optional DOSBox für einen
DSP-Neubau.

```sh
make trex_m68030
```

Ergebnis: `TREX/m68030/trex_m68030.tos`. Zwei weitere Varianten aus derselben
Quelle:

```sh
make trex_m68030_run    # ohne GEMDOS-Schreibzugriffe pro Bild (Betrachtung)
make trex_m68030_full   # ungekürztes 2.724-Dreiecks-Mesh statt des 1.600er-LOD
```

`TREX/dsp/trex_dsp.lod` ist vorgebaut eingecheckt; `make trex_m68030` braucht
dafür kein DOSBox. Ein DSP-Neubau nach einer Änderung an `trex_dsp.asm`
braucht es:

```sh
make DOSBOX=/Applications/dosbox.app/Contents/MacOS/DOSBox trex_dsp
```

## Pflichtlektüre

[AGENTS.md](AGENTS.md) und [OPTIMIZATION.md](OPTIMIZATION.md) sind Teil der
Implementierung, nicht optionale Notizen: Architektur, Protokollformate,
Speicherbudgets und jede performance-relevante Änderung sind dort
dokumentiert und müssen es bleiben. [TREX/dsp/README.md](TREX/dsp/README.md)
beschreibt den DSP-Kern, sein Host-Protokoll und seine Speicherbilanz im
Detail.

## Ziel

Atari Falcon030, 16 MHz, DSP56001. Renderziel 240x224 in einem
256x224-Videl-Modus. Der aktuelle Stand (siehe OPTIMIZATION.md) erreicht
3,13 FPS auf der ausgelieferten 1.600-Dreiecks-LOD und 2,05 FPS auf dem
vollen 2.724-Dreiecks-Mesh -- Hatari-Emulatorzeiten, keine Messung auf
echter Hardware.

## Was hier bewusst fehlt

Dieses Repository enthält nur, was `trex.tos` tatsächlich erzeugt, plus die
oben genannten Dokumente. Nicht übernommen aus `f030dsp3d`:

- **Mess- und Analysewerkzeuge** (`occl_*.py`, `opaque_selftest.py`,
  `ssi_stream_model.py`, `decode_*.py`, `fb2png.py`) -- die Kampagnen, die sie
  gefahren haben, stehen in OPTIMIZATION.md, aber die Werkzeuge selbst laufen
  gegen Messbinaries (`-DTREX_OCCL`, `-DTREX_PREPASS`, ...), die dieses Repo
  nicht baut. Einzelne Abschnitte in OPTIMIZATION.md verweisen dadurch auf
  Pfade, die es hier nicht gibt -- das ist bewusst in Kauf genommen, siehe
  Bemerkung dort.
- **PS1-Disassembly/Reverse-Engineering** (`TREX/disassembly/`,
  `TREX/tools/unecm.py`) -- die Herleitung von Modell, Textur- und
  Animationsdaten aus dem Original. Die Ergebnisse (`TREX/model/*.o3d`,
  `*.tmd`, `*.bin`, `TREX/textures/*.tim`) sind hier direkt vorhanden.
  Weder das Originaldisc-Image noch die BIOS-Datei, die dafür nötig wären,
  sind je in `f030dsp3d` eingecheckt gewesen.
- **Hatari** (Emulator-Submodul, ~100 MB) und **`tos402.rom`** (Atari-TOS-
  Firmware) -- zum Testen/Ausführen nötig, nicht zum Bauen.
- Der ältere, unabhängige `solvalou`/`dsp3d`-Demo-Code, der im selben Repo
  lag, aber nichts mit TREX zu tun hat.

Für alles davon: `f030dsp3d`.

## Historie

Frischer Anfang ohne übernommene Commit-Historie -- siehe `f030dsp3d` für die
Entwicklungsgeschichte der hier enthaltenen Dateien.
