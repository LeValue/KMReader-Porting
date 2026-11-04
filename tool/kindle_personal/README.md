# KMReader Kindle personale — prototipo Windows 0.1.0

Questo è il primo esperimento eseguibile per **Amazon.it**: accesso dal browser,
catalogo di acquisti e documenti personali, download completo e preparazione di
file da importare nel lettore di KMReader. Non richiede un accordo con Amazon.

È un programma separato dall'app: il lettore Android/Windows attuale non cambia.
Non è ancora il collegamento Kindle dentro le Impostazioni di KMReader. Prima
verifichiamo l'acquisizione di file reali; poi integriamo i protocolli confermati.
Il PC non è automaticamente una dipendenza permanente della futura integrazione.

## Prova sul tuo PC

1. Estrai **tutto** lo ZIP in una cartella; lascia insieme `Avvia-Kindle.cmd`,
   la cartella `KMReader-Kindle` e i suoi file. Serve Windows 10/11 x64 con Edge.
   Non servono Python, GitHub Runner, telefono collegato o installazione di KMReader nuova.
2. Apri `Avvia-Kindle.cmd` e scegli **1 — Collega Amazon.it**.
3. Nella finestra Amazon inserisci password ed eventuale verifica. Nessuno dei
   due viene richiesto nel terminale, salvato dal prototipo o inviato allo sviluppatore.
4. Torna al menu e scegli **2 — Sincronizza e mostra catalogo**. Controlla che
   siano presenti sia gli acquisti (`EBOK`) sia i documenti personali (`PDOC`).
5. Scegli **3 — Scarica un titolo** e indica il numero. Prova prima un documento
   personale e poi un acquisto recente. La libreria Amazon non viene modificata.
6. Se compare **FILE PRONTO PER L'IMPORTAZIONE**, importa il percorso indicato in
   **KMReader → Libri locali**. Controlla il testo, cambia qualche pagina, chiudi
   il libro e riaprilo senza rete. Questa è la verifica finale nel nostro motore.
7. Se qualcosa fallisce, usa **6 — Esporta diagnostica** e condividi soltanto
   `diagnostic.json` insieme alla fase in cui ti sei fermato. Non inviare la
   cartella dell'archivio, file di sessione, URL di ritorno o credenziali.

Il login parte dal flusso con **PKCE**, ancora da verificare per questo profilo
Kindle. Se Amazon lo rifiuta, il menu **8** permette di provare esplicitamente il
flusso storico con token nello stesso browser locale. Non avviene un passaggio
automatico fra profili/dispositivi. Entrambi usano un profilo Kindle iOS storico,
documentato nel rapporto di ricerca: l'accettazione attuale è una parte della prova.
Una pagina Amazon che continua a mostrare un errore non equivale a un login riuscito.

## Cosa significa il risultato del download

- **Importabile**: un EPUB/PDF è stato riconosciuto e verificato strutturalmente,
  oppure Calibre ha prodotto un EPUB che supera gli stessi controlli. Il file
  `ready.epub` / `ready.pdf` è il candidato per KMReader; non è una dichiarazione
  che abbiamo già visto e verificato le pagine del tuo libro.
- **Download completo, preparazione necessaria**: tutte le risorse dichiarate nel
  manifest sono presenti, ma il contenuto non è ancora pronto per il nostro
  lettore. Il motivo compare nel terminale e in `preparation.json`. Non importare
  una risorsa `.azw` rinominandola `.epub`.
- **Errore di download**: un manifest o una risorsa non sono stati ottenuti
  integralmente. Il titolo non viene segnato completato; una revisione già
  scaricata resta intatta. Un nuovo tentativo richiede un manifest fresco.

Per **MOBI/KF8/KFX**, il prototipo cerca `ebook-convert.exe` di un'installazione
locale di [Calibre](https://calibre-ebook.com/download_windows). La conversione
dipende dal formato e dai plugin che hai installato, compreso KFX Input quando
necessario. Il prototipo non installa plugin e non include un convertitore né una
soluzione universale alle protezioni dei titoli acquistati. Il percorso recente
**acquisto → risorse → conversione → lettura** va verificato sul libro reale.
Puoi installare/configurare il convertitore e scegliere **4 — Riprova preparazione**
senza riscaricare le risorse. La conversione non invia i file a terzi.

## Archivio locale

`%LOCALAPPDATA%\KMReader\KindlePrototype`

- `session.dpapi`: token e chiave del solo dispositivo del prototipo, cifrati con
  **Windows DPAPI per il tuo utente**, senza copia in chiaro.
- `identity.json`: seriale stabile del dispositivo logico; nessuna password.
- `accounts/.../catalog.json`: metadati della tua libreria, da tenere privati.
- `accounts/.../downloads/...`: risorse, ricevute con SHA-256 e file preparati.
- `diagnostic.json`: versione, conteggi, codici d'errore e stato HTTP, senza
  titoli, identificativi dei libri/account, token, chiavi, cookie o URL firmati.

Il menu **7** rimuove soltanto la sessione locale protetta. Mantiene i file e non
scollega dispositivi dal tuo account Amazon. Per revocare anche il dispositivo
logico usa la pagina dispositivi Amazon: il programma non ha un comando che
rimuova associazioni esterne o modifichi gli acquisti.

Il catalogo può essere aggiornato e includere rimozioni. Se la risposta indica
ulteriori risultati oppure raggiunge il limite di 10.000 elementi, l'elenco è
dichiarato **parziale**: non fingiamo di aver completato una paginazione non
ancora verificata. In questa versione il catalogo è testuale, senza copertine;
non è ancora l'interfaccia della futura libreria Kindle nell'app.

Nessuna progressione di lettura viene scritta su Amazon. Lo streaming è rimandato;
questa versione acquisisce i file completi prima della lettura, come il percorso
EPUB attuale di KMReader da Komga.

## Comandi facoltativi

Da PowerShell, nella cartella estratta:

```powershell
.\KMReader-Kindle\KMReader-Kindle.exe login --browser chrome
.\KMReader-Kindle\KMReader-Kindle.exe library --full
.\KMReader-Kindle\KMReader-Kindle.exe download 1
.\KMReader-Kindle\KMReader-Kindle.exe download 'EBOK:IDENTIFICATIVO' --no-convert
.\KMReader-Kindle\KMReader-Kindle.exe prepare 'C:\percorso\della\revisione'
.\KMReader-Kindle\KMReader-Kindle.exe status
.\KMReader-Kindle\KMReader-Kindle.exe self-test --browser
```

`self-test` usa dati sintetici e non contatta Amazon. Il pacchetto è sperimentale
e non ha una firma Authenticode. Non contiene le tue credenziali o libri.

## Sviluppo e verifica

Sorgenti nel repository, senza importare i progetti GPL/AGPL nell'app MIT.
Per eseguire i sorgenti su Windows usa Python 3.11 x64: il parser Ion fissato
nelle dipendenze ha un pacchetto binario per questa versione e non richiede CMake.
I campi del protocollo sono stati implementati separatamente sulla base delle
[fonti esaminate](https://github.com/LeValue/KMReader-Porting/blob/fix/android-epub-recovery/docs/KINDLE_UNOFFICIAL_ARCHITECTURE.md). Nessun accesso
Amazon autenticato è stato eseguito durante i test automatici o la compilazione.

```bash
python -m pip install -r tool/kindle_personal/requirements.txt
python -m tool.kindle_personal --help
python -m unittest discover -s tool/kindle_personal/tests -v
python -m playwright install chromium
KMREADER_KINDLE_BROWSER_TEST=1 python -m unittest discover -s tool/kindle_personal/tests -v
```

Il programma interattivo conserva le credenziali soltanto su Windows. I test
Linux usano sessioni sintetiche in memoria; nessun archivio in chiaro è attivabile
dall'interfaccia o dai comandi del programma.
