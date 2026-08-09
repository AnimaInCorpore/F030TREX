# T-Rex-DSP-Kern

`trex_dsp.lod` ist der DSP56001-Geometrie- und Triangle-Setup-Kern des
Falcon030-Ports. Der aktive Pfad übernimmt pro Bild:

1. Aufbau der exakten PS1-Morphpose aus Basisvertex, dedupliziertem Gangdelta
   und den aktiven Q12-Zielgewichten,
2. Transformation der 1.376 Vertices mit der extrahierten Szenenmatrix,
3. Perspektivprojektion auf das 300×224-Renderziel,
4. Near-Plane-, Flächen-, Backface- und Bildschirm-Culling,
5. derzeitiges 4-Bit-Flat-Lighting, Z-/OT-Schlüssel und den vollständigen DDA-Span-Setup-Record
   für jedes sichtbare Dreieck.

Der M68030 liest die 64-Byte-Choreografierecords, erweitert die gespeicherten
XYZ16-Deltas zu nativen Host-Port-Wörtern, baut die Host-Pakete, verknüpft die
Ordering Table und rasterisiert die vorbereiteten Spans. Er berechnet weder
Morphprodukte noch Vertexmatrizen, Projektion, Culling oder Span-Divisionen.
Das Flat-Lighting ist noch keine exakte PS1-Nachbildung: Das TMD referenziert
drei Normalen pro Dreieck und die Demo verwendet drei farbige Lichter plus
rötliches Ambient-Licht. Diese Quelldaten sind inzwischen extrahiert; das
aktuelle Wire-/Rasterformat transportiert aber nur einen Helligkeitswert pro
Fläche.

## Speicherbilanz

Der Falcon stellt dem DSP 32K Wörter externes 24-Bit-RAM bereit. P- und
Y-Adressraum überlagern sich ab `$0200`; deshalb beginnen die residenten
Y-Arrays erst oberhalb des Programms.

| Bereich | Wörter | Zweck |
|---|---:|---|
| `X:$0040-$0043` | 4 | Kommando und Translation |
| `X:$0044-$1063` | 4.128 | statische Basisvertices |
| `X:$1064-$25E3` | 5.504 | Objekt-/Kamerapose, danach projizierte Vertices in-place |
| `X:$25E4-$3B2B` | 5.448 | residente UV-Paare |
| `X:$3B2C-$3CEB` | 448 | 32 gepackte Span-Records à 14 Wörter |
| `Y:$09C0-$1F07` | 5.448 | gepackte residente Dreiecksindizes |
| `Y:$1F08-$3EF3` | 8.172 | residente Flächennormalen |

Das Frontend reserviert `X:$0000-$3DFF` und `Y:$0000-$3EF7`. Der aktuelle LOD
belegt P ab `$0040`; die erste freie P-Adresse ist `$075B`. Bis zum Beginn der
Y-Indizes bei `$09C0` bleiben damit 613 Wörter Code-Reserve. Diese Grenze muss
nach jeder DSP-Änderung kontrolliert werden, weil ein Überlauf ohne
Assemblerfehler die Indexliste überschreibt.

Die vollständigen Animationsziele sind nicht DSP-resident. Das Frontend sendet
pro Bild genau eine von 46 vollständigen Gangposen und nur die tatsächlich
aktiven, sparsamen Ziele 5-8. Die vorhandene `camera_vertices`-Allokation dient
zuerst als Objektpose, danach als Kamera- und Projektionspuffer; es ist kein
weiteres Vertexarray nötig.

## Host-Protokoll

Alle Transportwerte sind native 24-Bit-DSP-Wörter. Animationsdaten werden in
bestätigten Teiltransaktionen übertragen; ein Chunk enthält höchstens 512
Vertices.

```text
LOAD_VERTICES:
    cmd, count, count * (x, y, z)

SET_ANIMATED_FRAME:
    cmd, matrix[9], translation[3], focal_x, focal_y, centre_x, centre_y,
    near, light[3]
    -> ACK_ANIMATION_BEGIN

LOAD_ANIMATION_GAIT:
    cmd, first_vertex, count, count * (delta_x, delta_y, delta_z)
    -> ACK_ANIMATION_GAIT

APPLY_ANIMATION_TARGET:
    cmd, signed_q12_weight, first_vertex, count,
    count * (delta_x, delta_y, delta_z)
    -> ACK_ANIMATION_TARGET

FINISH_ANIMATED_FRAME:
    cmd -> ACK_FRAME, vertex_count

LOAD_NORMALS:
    cmd, count, count * (nx, ny, nz) -> ACK_NORMALS, count

LOAD_TRIANGLES:
    cmd, count, count * (i0 | i1<<12, i2) -> ACK_LOAD_TRIANGLES, count

LOAD_UVS:
    cmd, count, count * (u0 | v0<<8 | u1<<16,
                         v1 | u2<<8 | v2<<16)
    -> ACK_LOAD_UVS, count

BUILD_TRIANGLES:
    cmd, count, first_triangle -> ACK_TRIANGLES, survivor_count

GET_TRIANGLES:
    cmd -> ACK_GET_TRIANGLES, survivor_count,
           survivor_count * 14-word packed span record
```

`BUILD_TRIANGLES`/`GET_TRIANGLES` laufen in 32-Dreiecks-Chunks. Das Frontend
startet Chunk N+1, bevor es Chunk N entpackt; der DSP arbeitet dadurch während
Framebuffer-Clear und Host-Paketaufbau weiter. Der 14-Wort-Wirerecord wird auf
dem M68030 wieder zum semantischen 17-Feld-DDA-Record erweitert. Format,
Validierung und Messwerte stehen in `OPTIMIZATION.md`.

Das ältere `SET_FRAME`/`GET_VERTICES`-Protokoll bleibt für den unabhängigen
Protokolltest und den Host-Fallback vorhanden, ist aber nicht der normale
Animations- und Rasterpfad.

## Bauen und testen

```sh
make DOSBOX=/Applications/dosbox.app/Contents/MacOS/DOSBox trex_dsp
make trex_m68030
make trex_dsp_test
```

Der unabhängige TOS-Test reserviert das produktive X/Y-Layout und prüft
`RESET`, die einmaligen Vertex-/Index-/UV-Uploads, `SET_FRAME`, Projektion,
Survivors-only-Culling und einen vollständigen 14-Wort-Span-Datensatz. Der
Culling-Fall enthält ausdrücklich eine negative Vorderfläche und eine positive
Rückfläche, passend zur Händigkeit der PS1-Kameramatrix. Ein headless
Hatari-2.6.1-Lauf am 2026-08-06 schrieb `P` nach `dsp_test.res`; zusätzlich
verglich der aktivierte Span-Validator 9.003 Datensätze mit null Feldfehlern.
Das ist Emulatorvalidierung; ein Lauf auf echter Falcon-Hardware steht aus.

Der DSP-Assembler läuft in DOSBox; das Ergebnis ist
`TREX/dsp/trex_dsp.lod` und wird als Laufzeitkopie nach
`TREX/m68030/trex_dsp.lod` übernommen. `make run_trex_headless` startet die
TOS-Datei über ein gemountetes GEMDOS-Laufwerk, damit DSP-LOD, Statistiken und
Framebufferdump im selben Verzeichnis liegen. Hatari-Messwerte und Messungen
auf echter Falcon-Hardware sind strikt getrennt zu dokumentieren.
