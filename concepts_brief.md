# MacNTFS (Arbeitstitel): geprüfte Swift-Bibliothek zum Lesen von NTFS (Umbau statt Neubau)

* **Author:** Michael Katschko
* **Date:** 2026-11-03
* **Status:** Version 3, ergänzt um die Entscheidungen vom 2026-11-03 und um den Umsetzungsstand am Ende des Dokuments. E1 ist vom Assistenten im Auftrag des Autors entschieden und widerrufbar. Der Autor hat entschieden, den Ansatz zu ändern. Welche neue Richtung gilt, ist noch nicht bestätigt. Version 3 enthält die Befunde von zwei Review-Runden (zwölf Prüfungen) und vorgeschlagene Kürzungen.

## Overview

**Ausgangslage.** Das Repo `darkspike1988/MacNTFS` enthält eine reine Swift-Engine für NTFS mit Parser, Writer, Formatter, Checker, Forensik, CLI und SwiftUI-App. Der FSKit-Teil ist ein Gerüst. Die README nennt alle fünf Phasen "Done" und verspricht "100 % sicher". Der Autor wollte ursprünglich einen freien Treiber für Fremde, die kein Tuxera NTFS bezahlen können.

**Was die Prüfung ergeben hat.**
1. Kostenlose FSKit-Treiber mit Schreibzugriff gibt es schon mehrfach (siehe Analyse 1). Ein weiterer Treiber ließe sich nicht unterscheiden.
2. Ein nur lesendes Toolkit hat keine Endnutzer-Zielgruppe, weil macOS NTFS ohnehin liest. Es konkurriert mit reifen Werkzeugen (The Sleuth Kit, ntfsprogs und weitere, siehe Analyse 1). Der einzige belegte Unterschied ist "in Swift".
3. Der Code ist als Basis nur teilweise brauchbar. Der Leseweg liefert heute stille Falschdaten, und die CLI enthält schreibende Befehle.

**Wert in einem ehrlichen Absatz.** Für Endnutzer bringt das Projekt in dieser Form nichts Neues. Der Wert liegt (a) für Swift-Entwickler, die NTFS ohne C-Bibliothek in einem Swift-Prozess lesen wollen, und (b) als Vorzeigeprojekt, das gründliche Ingenieursarbeit zeigt: Parser mit nachgewiesener Korrektheit statt stiller Fehler. Ein zweiter, möglicherweise größerer Wert ist ein öffentlicher **Korrektheits-Testkorpus**: Windows-erzeugte NTFS-Images mit Manifest (Dateipfade, Größen, Hashes) und ein Vergleichswerkzeug, das auch anderen Projekten nützt. Ob (a) eine Ein-Satz-Antwort auf "wer braucht das und warum reicht libfsntfs per C-Anbindung nicht?" hat, ist offen und entscheidet über den Abbruch (siehe Stoppkriterium).

**Neue Arbeitshypothese (Vorschlag).** MacNTFS wird eine schmale, nur lesende Swift-Bibliothek `NTFSEngine` mit einer CLI (`ls`, `cat`) für Disk-Images, deren Korrektheit durch einen unabhängigen Test-Korpus und Vergleich gegen ntfs-3g, The Sleuth Kit und libfsntfs belegt ist. Alles, was Schreiben, Formatieren, Reparieren, eine App oder Wiederherstellung betrifft, verlässt v0.1.

## Analysis

*Belegung:* Konkurrenzzahlen stammen aus der GitHub-API vom 2026-11-03. Selbstaussagen der Projekte wurden nicht nachgemessen. Befunde am Code stammen von Reviewern. Die mit [V] markierten habe ich selbst im Code nachgeprüft, [W] heißt Fachwissen ohne Prüfung am Code. Nichts wurde auf einem echten Volume ausgeführt.

### 1. Marktlage

**Treiber (FSKit, Schreibzugriff):**

| Projekt | Sterne | Lizenz | Stand | Hinweise |
|---|---|---|---|---|
| ntfstool/ntfstool | 4.185 | MIT | Push 2026-11-01 | FSKit-Ausgabe, Schreiben ab macOS 26, Pro-Version Closed Source. Repo seit 2020, viele Sterne aus der älteren Electron/FUSE-Zeit. |
| dr-kbadawi/ttntfs | 22 | GPL-2.0 | Push 2026-09-23 | Notarisiertes DMG, macOS 26+, Apple Silicon. Eigene Aussage: mit Windows-chkdsk geprüft. |
| HuanchuanTech/xntfs | 21 | GPL-2.0 | Push 2026-10-30 | App Store, ntfs-3g, ab macOS 15.4. |
| whereteam/ntfskit | 8 | nicht angegeben | Push 2026-10-15 | Eigene Aussage: Kernel-Offloaded I/O. |
| prashantguleria/branchway-ntfs, rookiestudio1/MacNTFS und mehr als zehn weitere | 0 bis 9 | meist GPL/MIT | 2026-10 | Nur mit eigenem Signing nutzbar. |

Der Name "MacNTFS" ist bereits vergeben (rookiestudio1/MacNTFS und ähnliche).

**Signierung:** Die READMEs von ntfstool, Branchway und rookiestudio1/MacNTFS sagen übereinstimmend, ein FSKit-Modul brauche das Entitlement `com.apple.developer.fskit.fsmodule` über ein Provisioning Profile eines bezahlten Developer-Accounts. TT NTFS Native wird als "notarized by Apple" ausgeliefert. Für einen Treiber wäre der Account also nötig, für die Bibliothek nicht.

**Werkzeuge im Toolkit-Bereich (Lesen, Auflisten, Wiederherstellen), von Reviewern genannt:**
- The Sleuth Kit (`fls`, `icat`, `istat`): Homebrew-Formel `sleuthkit` 4.15.0 ist vorhanden [V].
- ntfs-3g mit `ntfsls`, `ntfscat`, `ntfsinfo`, `ntfsundelete`: Homebrew-Formel `ntfs-3g` 2026.9.28 (GPL-2.0-or-later und LGPL-2.0-or-later) existiert [V]. Ob sie auf macOS ohne macFUSE nutzbar ist, ist nicht geprüft. Lokal installiert ist davon nichts.
- libyal/libfsntfs: Es gibt keine Homebrew-Formel mit diesem Namen [V].
- Rust-Crate `ntfs`, `dissect.ntfs`, MFTECmd: von Reviewern genannt, ungeprüft [W].
- Eine reife Swift-NTFS-Bibliothek fand die GitHub-Suche nicht (nur Treffer ohne Reife). Das ist ein schwacher Beleg.

**Folgerung:** Als Treiber ist das Projekt eine Doppelung. Als Toolkit ist es ebenfalls eine Doppelung, mit "Swift" als einzigem Unterschied.

### 2. Zustand des Codes

- **Versprechen ohne Deckung:** README, Website und UI sagen "Full Read & Write", "zero data loss", "100 % sicher".
- **Die CLI ist nicht lesend** [V]: `format`, `create-image`, `write` und `check` mit Reparatur stehen in `Sources/MacNTFSCli/main.swift`. `FileBlockDevice` öffnet standardmäßig nur lesend, bietet aber einen `writable`-Parameter und `pwrite` [V]. `MemoryBlockDevice` ist standardmäßig beschreibbar [V]. Die App öffnet laut Reviewer an drei Stellen beschreibbar, auch nur zum Anzeigen.
- **Der Leseweg liefert stille Falschdaten** (Reviewer): fehlende `$DATA` ergibt leere Daten, Kompression und Verschlüsselung werden nur als Flag geparst, `initializedSize` wird ignoriert, Attributlisten und Reparse Points sind nicht behandelt. Die Funktion `readFromRuns` existiert laut Reviewer mehrfach als Kopie.
- **Fixup-Schrittweite** [V für den Code, W für die Regel]: `Fixup.swift` rechnet mit `bytesPerSector`. NTFS nutzt für die Update-Sequence nach Fachwissen immer 512-Byte-Schritte. Auf Platten mit 4096-Byte-Sektoren würde das stille Fehler erzeugen. Wie der Aufrufer den Wert übergibt, habe ich nicht geprüft.
- **Parser trappen bei manipulierten Boot-Daten** (Reviewer): Überlauf bei `-signedMftVal`, ungeprüfte Multiplikationen in `readFromRuns` und `BootSector`. Eine Division durch 0 im Bootsektor fand der Reviewer nicht, der frühere Brief hatte sie fälschlich genannt.
- **Der Checker prüft nur Bootsektor, Backup-Bootsektor, MFT-Record 0 und das Dirty-Flag.** Die Ausgabe "HEALTHY" ist irreführend. `repair` löscht nur das Dirty-Flag.
- **Writer und Formatter:** Von der ersten Runde berichtet: unvollständige Systemdateien im Formatter, feste Layout-Konstanten (MFT ab Cluster 4, `$Bitmap` ab Cluster 32), Schreibpfad ohne `$LogFile`. Dass der Writer das MFT-Bitmap nicht aktualisiert und Indexeinträge unsortiert einfügt, hat ein Reviewer behauptet, ein zweiter nicht bestätigen können. Das gilt als unverifiziert. Da diese Teile aus v0.1 fallen, ist die Frage nachrangig.
- **`PrivilegedDiskBridge`** [V]: fest verdrahteter Pfad im Home-Verzeichnis des Autors, `sudo` aus einer GUI, `unmountDisk force` ohne Rückfrage.
- **Verzeichnissuche:** `caseInsensitiveCompare` statt `$UpCase`, lineares Durchsuchen statt B-Baum, keine Tiefen- und Zyklusgrenze.
- **Tests:** 17 Tests ohne unabhängiges Orakel, CI auf `macos-14`.
- **Wiederverwendbar** (Reviewer): `BinaryReader`, Runlist-Dekoder, Aufbau von `MFTRecord` und Attributen, die Lesepfade von `FileBlockDevice`. Neu schreiben: `readFromRuns`, Größenberechnung im Bootsektor, Fixup-Schrittweite, Index-Logik, Feature-Erkennung. Der Aufwand gleicht eher einem halben Neuschreiben der Lesepfade als einer Politur.
- **Rechteinhaber:** Das Repo gehört dem GitHub-Konto `darkspike1988`, mit dem `gh` auf diesem Mac angemeldet ist [V]. Die `LICENSE` nennt aber nur "MacNTFS Open Source Project".

### 3. Anforderungen an ein Lese-Toolkit (Design-Befunde)

- **Schichten:** (a) reine Parser und Werttypen ohne Darwin-Abhängigkeit, (b) Lesen und Pfadauflösung mit einem Protokoll, das nur lesen kann und Streaming für große Dateien erlaubt, (c) ein Darwin-Teil für Geräte, ioctl und Mount-Erkennung.
- **Read-only vom Typ erzwingen:** Protokoll ohne Schreibmethode, `O_RDONLY` fest, kein `pwrite` im Engine-Target. Test: Hash eines schreibgeschützten Images vor und nach jedem CLI-Befehl. CI-Prüfung per `nm`, dass das Binary kein `pwrite` enthält.
- **Fehlermodell:** getrennte Kategorien für beschädigt, gültig aber nicht unterstützt, Ein-/Ausgabefehler und Ressourcenlimit, jeweils mit Kontext (Record, Attribut, Offset). Teilergebnisse mit Befunden pro Eintrag statt Abbruch beim ersten Fehler. Harte Grenzen für Speicher, Rekursion und Zyklen.
- **Nicht unterstützt heißt Fehler,** nie Leerdaten oder Rohbytes (Kompression, Verschlüsselung, Attributlisten, Reparse Points).
- **Live-Volumes:** Wenn ein Volume gerade schreibbar gemountet ist, liefert rohes Lesen inkonsistente Daten. Mount-Zustand erkennen, Abbruch bei schreibbarem Mount. Hibernation und `$LogFile`-Zustand melden.
- **Namensauflösung:** `$UpCase` laden, Namensräume (Win32, DOS, POSIX) beachten, DOS-8.3-Duplikate ausblenden.
- **Swift 6 Sprachmodus,** unveränderliche Testgeräte (`MemoryBlockDevice` hat laut Reviewer einen Data Race).
- **Auslieferung:** Ein unsigniertes Binary bekommt Gatekeeper-Warnungen (Quarantäne). Daher nur Bau aus dem Quellcode oder eine Homebrew-Formel, die aus dem Quellcode baut. Eine App mit privilegiertem Helper braucht praktisch Developer ID und Notarisierung, das entfällt, solange es keine App gibt.
- **Physische Laufwerke:** Lesen von `/dev/rdiskN` braucht root, Sektor-Ausrichtung und Verhalten bei gleichzeitigem Mount sind zu klären. In v0.1 nur Images; `sudo`-Zugriff auf Laufwerke ist ein späterer Meilenstein.

### 4. Testmethode (Orakel)

- **Wahrheit ist ein Manifest,** das beim Erzeugen der Images in Windows geschrieben wird (Pfad, Größe, SHA-256, ADS, Links). Dagegen werden ntfs-3g, The Sleuth Kit und libfsntfs per Vergleich gemessen. Ein mit `mkntfs` erzeugtes und mit `ntfscat` geprüftes Image stammt aus derselben Codebasis, Fehler würden korrelieren.
- **Images sind nicht bitgleich reproduzierbar** (Seriennummer, Zeitstempel, GUIDs). Verglichen wird über Inhalts-Hashes. Windows-Images werden einmal erzeugt und versioniert abgelegt (Release-Asset oder Git LFS, mit Skript und Windows-Build-Nummer, Lizenz z. B. CC0, Evaluierungs-Bedingungen der Windows-VM vorher prüfen). Nur reine Datenvolumes mit selbst erzeugtem Inhalt.
- **Testmatrix:** 512- und 4096-Byte-Sektoren, fragmentierter `$MFT`, Attributlisten, Kompression, ADS, Hardlinks, Symlinks und Junctions, Sparse-Dateien, Unicode (NFC/NFD), gelöschte Dateien, Windows-Schnellstart-Zustand.
- **Windows-chkdsk** wird nur beim Erzeugen der Images genutzt, um die Referenz zu bestätigen. Es läuft nicht in der CI.
- **Fuzzing:** Der Kern muss unter Linux bauen, damit libFuzzer verfügbar ist, oder es laufen auf macOS XCTest-Mutationstests mit AddressSanitizer. Dass die Xcode-Toolchain keinen libFuzzer mitbringt, wurde nicht geprüft [W]. Die echte Fehlerklasse in Swift sind Traps, Endlosschleifen und Speicherexplosionen.
- **CI:** Images und Soll-Hashes entstehen in einem Linux-Job mit festgepinntem ntfs-3g und gehen als Artefakt an den macOS-Job. Ein Runner mit macOS 27 existiert vielleicht noch nicht; das Label ist festzuschreiben und die Abweichung zu Swift 6.4 lokal zu dokumentieren.

### 5. Wo die Reviewer uneins sind

| Thema | Positionen |
|---|---|
| Wann M0? | Zoom-out: sofort, egal welche Richtung, weil die README heute "100 % sicher" verspricht. Umsetzbarkeit und Struktur: erst nach E1, E2, E4, sonst wird M0 wiederholt. Auflösung als Vorschlag: M0a (Texte korrigieren, Knöpfe abschalten, reversibel über Git) sofort, Umbenennung vor dem ersten Release. |
| Schicksal des Writers | Löschen (Git-Historie bewahrt ihn), in ein unveröffentlichtes Target `Experimental` schieben, oder hinter ein Flag. Einig: nicht in Releases. |
| Inspektor-App | Zoom-out und Design: raus aus v0.1. Umsetzbarkeit: App nur für Images. |
| chkdsk | Zoom-out: nicht nötig. Umsetzbarkeit: manuell außerhalb der CI. Design: nur beim Erzeugen der Images. |
| Hauptprodukt | Bibliothek, oder der öffentliche Korrektheits-Testkorpus (Design), oder eine Testsuite, die fremde Treiber gegen chkdsk misst (Zoom-out). |
| Fuzzing | Linux-fähiger Kern mit libFuzzer, oder macOS-Mutationstests mit ASan. |
| Treiberempfehlungen | Ein Satz mit Links (Zoom-out), oder eine Seite mit Prüfdatum und "Selbstauskunft, nicht geprüft" (Design). Gemeinsam: keine eigenen Urteile über fremde Software. |
| Name | Zoom-out: Umbenennung nach der Minimalversion. Umsetzbarkeit: vor dem ersten Toolkit-Release, damit Bundle-ID, Paketname und URL nur einmal brechen. |

## Goals vs. Non-Goals

*Vorschlag unter Vorbehalt von E1.*

* **In-Scope Goals (v0.1):**
  * Nur lesende Swift-Bibliothek `NTFSEngine` (Produktname offen), nutzbar als SwiftPM-Paket, nur Foundation für den Kern.
  * CLI mit `ls` und `cat`, nur für Disk-Images.
  * Korrektheitsnachweis: Jede Datei der Referenz-Images ist hash-gleich zum Manifest oder liefert einen ausdrücklichen "nicht unterstützt"-Fehler, nie stille Falschdaten. Fuzz-Lauf über mehrere Stunden ohne Trap.
  * Wahrheitsgemäße README, `SAFETY.md`, `STATUS.md` und Hinweis für Nutzer von 0.1.x.
  * Reproduzierbare Testbasis (Skripte, Manifeste, gehashte Images).
* **Out-of-Scope Non-Goals (v0.1):**
  * Eigener Treiber, FSKit, ntfs-3g als Engine, GPL-Auslieferung.
  * Schreiben, Formatieren, Reparieren, Wiederherstellen gelöschter Dateien.
  * Inspektor-App, Hex-Ansicht, Surface-Scan, Boot-Diff, `check`-Befehl mit "HEALTHY"-Ausgabe, Website, Issue-Template.
  * Zugriff auf physische Laufwerke.
  * Eigene Binärdateien zum Herunterladen, Mac App Store.
  * Eine Seite, die fremde Treiber bewertet. Höchstens ein Absatz mit Links, Prüfdatum und dem Vermerk "Selbstauskunft, nicht geprüft".
* **Später, falls Bedarf von außen belegt ist:** Gerätezugriff per `sudo`, `undelete` mit eigenem Orakel, App auf demselben Kern, `check` als `probe`.

## Alternatives Weighed

**Vom Autor verworfen:**

- **Eigene Swift-Engine als Schreib-Engine für einen Treiber.** Rejected by author: Zeitaufwand. Sicheres Schreiben würde laut gemeinsamer Schätzung 2 bis 4 Monate bis "experimentell schreibend" brauchen, der Sicherheitsnachweis ist der Engpass.
- **Treiber mit FSKit und ntfs-3g, GPL, als v1.** Rejected by author: Der Autor wollte nach der ersten Review-Runde den Ansatz ändern. Die Konkurrenzprüfung stützt diese Wahl, sie ist aber nicht seine Begründung.

**Noch nicht entschieden:**

- **Testkorpus und Vergleichswerkzeug als Hauptprodukt,** die Bibliothek nur als Beleg dafür. Nützt auch ntfs-3g, The Sleuth Kit und den Treibern. Nachteil: Windows-VM nötig, gehashte Images müssen gepflegt werden.
- **Testsuite, die fremde Treiber auf Images gegen chkdsk prüft** und Ergebnisse veröffentlicht. Echte Lücke laut Zoom-out-Prüfer, aber verlangt, fremde Treiber zu installieren und zu bewerten.
- **Mitarbeit an einem bestehenden Treiber** (TT NTFS Native GPL-2.0, ntfstool MIT) mit Tests und Fehlerberichten. Nutzer bekommen echten Schreibzugriff, kein eigenes Vorzeigeprojekt.
- **Treiber trotzdem bauen** (FSKit, ntfs-3g, GPL, bezahlter Account, Spike mit Pass/Fail-Kriterien). Die Befunde dazu stehen in Version 1 des Briefs.
- **Nach M0 archivieren,** falls die Wertfrage keine Ein-Satz-Antwort hat. Das Repo bleibt mit ehrlicher README stehen.

## Key Decisions & Staging for Next Steps

**Entschieden (Chat, 2026-11-03):**

1. Der Treiber-Ansatz (FSKit plus ntfs-3g als v1) wird geändert und neu formuliert.
2. Das Projekt soll offen, kostenlos und ein Vorzeigeprojekt für Fremde sein.

**Entschieden am 2026-11-03.** Der Autor hat die Wahl dem Assistenten überlassen ("entscheide du"). Die Entscheidungen sind vom Autor jederzeit widerrufbar:

- **E1:** Schmale, nur lesende Swift-Bibliothek, mit dem Stoppkriterium aus diesem Abschnitt. Treiber und Mitarbeit bleiben Alternativen für später.
- **E2:** Writer, Formatter, Repair, `PrivilegedDiskBridge` und `FSKitAdapter` werden aus dem Produkt entfernt (Löschung in M2, Git-Historie bewahrt sie). Bis dahin sind sie hinter `ExperimentalGate` gesperrt.
- **E3:** v0.1 nur für Images. Zugriff auf physische Laufwerke später per `sudo`.
- **E4 (teilweise):** Rechteinhaber in `LICENSE` ist eingetragen (Michael Katschko, auf Basis des Git-Namens, bitte prüfen). Die Umbenennung bleibt offen und ist vor dem ersten Toolkit-Release zu klären.
- **Veröffentlichung:** Nichts davon ist committet, gepusht oder als Release veröffentlicht. Der Hinweistext für die alten Releases liegt als Entwurf bereit.

**Entscheidungsvorlage E1 bis E8 (Stand vor der Entscheidung; E5 bis E8 sind weiter offen):**

| Nr. | Frage | Vorschlag der Prüfer |
|---|---|---|
| E1 | Richtung: schmale Lese-Bibliothek, Testkorpus als Hauptprodukt, Mitarbeit an Treiber, Treiber doch bauen, oder nach M0 archivieren? | Schmale Bibliothek plus Korpus, mit Stoppkriterium |
| E2 | Writer, Formatter, Repair, `PrivilegedDiskBridge`, `FSKitAdapter`: löschen oder in unveröffentlichtes Target? | Löschen, Git-Historie bewahrt sie |
| E3 | App und Geräte: nur Images in v0.1? | Ja |
| E4 | Name (Kollision, "Mac" passt nicht, wenn der Kern unter Linux baut) und Rechteinhaber in `LICENSE` | Rechteinhaber sofort eintragen, Umbenennung vor dem ersten Release |
| E5 | Kern Linux-fähig? (hängt Fuzzing und Orakel-CI daran) | Ja |
| E6 | Paketname `NTFSEngine` oder `NTFSCore`, Semver (0.x ohne Zusage), Swift 6, Mindest-macOS | ADR vor M2 |
| E7 | Ort und Lizenz der Referenz-Images | Release-Asset oder LFS, CC0 |
| E8 | Umgang mit 0.1.x: Hinweis, alte Releases als unsicher markieren, nächste Version als Bruch | Advisory: "mit 0.1.x beschriebene Volumes unter Windows mit `chkdsk /f` prüfen" |

**Stoppkriterium (Vorschlag Zoom-out):** Abbruch nach M0, wenn die Wertfrage aus der Übersicht keine Ein-Satz-Antwort bekommt. Abbruch auch, wenn der Vergleichstest nach festem Zeitbudget (Vorschlag 4 Wochen) nicht grün ist. Wird er grün: Release 0.1, danach erweitern nur auf Anfrage von außen.

**Meilensteine mit Abnahme** (Zeitangaben sind grobe Schätzungen ohne Messgrundlage, KI-unterstützt):

| Nr. | Inhalt | Fertig, wenn | Abhängig von | Grobe Dauer |
|---|---|---|---|---|
| M0a | README, Roadmap, Website, UI-Texte auf Ist-Stand. Schreib-, Format- und Repair-Knöpfe sowie `PrivilegedDiskBridge` in Releases abschalten. Warnhinweis. Rechteinhaber in `LICENSE`. Versionsdrift (Skript 0.1.5, Website 0.1.4) bereinigen. `SAFETY.md`, `STATUS.md` | Suche nach "100 %" und "zero data loss" liefert nichts mehr | keine | etwa 1 Tag |
| M0b | Umbenennung, Bundle-ID, Paketname, URL | Alle Verweise geändert | E4 | etwa 0,5 Tag |
| M1 | Eine einzige Run-Resolver-Implementierung (beachtet `initializedSize`, Kompression), Bereichsprüfungen in Bootsektor, MFT-Record, Attributen, Runlists, Index, fester 512-Byte-Fixup, Fehlerkategorien | Jede Eingabe liefert Daten oder einen benannten Fehler. Unbekannte Features werfen `unsupported` mit je einem Test. Fuzz-Lauf ohne Trap über die vereinbarte Zeit | E2, E5, E6 | 1 bis 2 Wochen |
| M2 | Paketschnitt: Kern ohne FSKit und AppKit, Schreibcode und App aus dem Paket, Swift 6, CI-Labels | `swift build` und `swift test` grün, `nm` zeigt kein `pwrite` im Engine-Target | E2, E6 | 2 bis 3 Tage |
| M3 | Korpus: Windows-Images mit Manifesten, Skripte, Linux-Job mit ntfs-3g, Vergleich gegen ntfs-3g, The Sleuth Kit und libfsntfs | 0 Hash-Abweichungen auf allen Fixtures oder ein dokumentierter `unsupported`-Fehler | E7 | 2 bis 3 Wochen |
| M4 | CLI `ls` und `cat` auf Images, Schreibschutz-Test (Hash vor und nach jedem Aufruf) | Alle CLI-Befehle bestehen den Schreibschutz-Test | M1, M2 | 2 bis 3 Tage |
| M5 | Release 0.1 (Quellcode, Homebrew-Formel aus Quellcode), `CONTRIBUTING.md`, Hinweis für Nutzer von 0.1.x | Tag gesetzt, Release-Notes nennen Bruch und bekannte Grenzen | M3, M4, E8 | 2 Tage |

**Stand M0a (umgesetzt in Pull Request #2):**
- Schreibende Funktionen sind zentral gesperrt (`ExperimentalGate`, Entsperren nur mit `MACNTFS_EXPERIMENTAL_UNSAFE=1`): `NTFSVolumeWriter.writeFile`, `NTFSFormatter.format`, `NTFSVolumeChecker.repair`, beide Funktionen von `PrivilegedDiskBridge`, `create-image` im CLI und in der App. Knöpfe und Dropzonen sind ausgeblendet, solange gesperrt. Der fest verdrahtete Helper-Pfad aus dem Home-Verzeichnis des Autors ist entfernt. Die App öffnet Geräte nur noch lesend.
- README, `docs/index.html`, `LICENSE` sind korrigiert. Neu: `docs/SAFETY.md`, `docs/STATUS.md`, `docs/advisories/2026-11-03-releases-up-to-0.2.2.md` (Entwurf).
- Geprüft: Build grün, 18 Tests grün (neuer Test: gesperrt als Standard). Im CLI per Hand geprüft: gesperrte Befehle melden einen Fehler und lassen das Image unverändert (Hash gleich), lesende Befehle ändern kein Byte.
- **Nicht geprüft:** App-Oberfläche (nicht gestartet, nur kompiliert). `check --repair` auf einem beschädigten Image wurde nicht getestet, die Sperre sitzt aber in `repair()`.
- **Wichtig:** Auf GitHub gibt es bereits zehn oder mehr öffentliche Releases bis v0.2.2 (alle vom 2026-10-21), deren DMGs schreiben, formatieren und "reparieren". Diese Releases zu kennzeichnen oder zurückzuziehen ist Sache des Autors (E8). Vorschlag: Hinweistext in die Release-Notes, dann das nächste Release als 0.3.0 mit Bruch kennzeichnen. Das Skript `scripts/build_dmg.sh` hat noch den Standardwert 0.1.5, die Website nannte 0.1.4, beides passt nicht zum Stand v0.2.2.

**Nicht geprüft:** Selbstaussagen der Konkurrenzprojekte, ob diese auf macOS 27 laufen, die Reife von libfsntfs, der Rust-Crate, MFTECmd und dissect.ntfs, ob ntfs-3g über Homebrew auf macOS ohne macFUSE nutzbar ist, ob die Xcode-Toolchain libFuzzer mitbringt, ob es ein GitHub-Runner-Image für macOS 27 gibt, die Bedingungen der Windows-Evaluierungs-VM, Teile des Codes (Verzeichnis-Index, Forensik, die meisten Views) wurden nur per grep oder gar nicht gelesen.

## Umsetzungsstand (2026-11-03, Abend)

Umgesetzt in Pull Request #3 (enthält die Commits von #2), noch nicht gemergt:

| Meilenstein | Stand | Beleg |
|---|---|---|
| M0a Texte und Sperre | erledigt | PR #2 |
| M1 Parser härten | erledigt | `ParserHardeningTests`; der Mutationstest stürzte den alten Parser bei Iteration 242 ab und läuft jetzt über 3000 Images durch |
| M3 Korpus und Vergleich | erledigt für ntfs-3g-Images | 13 Korpus-Images plus `mini.img`: 0 falsche Ausgaben. Gefunden und behoben: NFC/NFD-Namen, Junction-Fehler, Attributlisten-Fehler, quadratische Suche |
| M2 Entfernen | erledigt | Schreibcode, Formatter, Prüfer, Forensik, FSKit-Gerüst, App, DMG-Skript, Release-Workflow gelöscht; `BlockDevice` ohne Schreibmethode |
| M4 CLI | erledigt | `probe`, `ls`, `cat`, `info`; `scripts/readonly-check.sh`; Symbolprüfung im CI |
| M5 Release 0.3.0 | vorbereitet | `CHANGELOG.md`; Veröffentlichung wartet auf grüne CI, Merge und Freigabe des Autors |

**Abweichungen von der Planung:** M3 lief vor M2, weil die Unit-Tests ein echtes Image statt des eigenen Formatters brauchten. Der Produktname bleibt `NTFSCore` (E6), die Umbenennung (E4) ist weiter offen.

**Noch offen:** die neue CI ist auf GitHub noch nicht gelaufen; Windows-erzeugte Images fehlen (braucht eine Windows-VM); `$ATTRIBUTE_LIST` wird abgelehnt, was große Verzeichnisse und stark fragmentierte Dateien betrifft (nächster sinnvoller Schritt, das Orakel dafür ist da); kein abdeckungsgesteuerter Fuzzer; E4 und E7 bis E8 aus der Entscheidungsvorlage.
