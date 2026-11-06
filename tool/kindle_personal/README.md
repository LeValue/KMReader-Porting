# KMReader Kindle personale — prototipo Windows 0.1.2

Questo è il primo esperimento eseguibile per **Amazon.it**: accesso dal browser,
catalogo di acquisti e documenti personali, download completo e preparazione di
file da importare nel lettore di KMReader. Non richiede un accordo con Amazon.

È un programma separato dall'app: il lettore Android/Windows attuale non cambia.
Non è ancora il collegamento Kindle dentro le Impostazioni di KMReader. Prima
verifichiamo l'acquisizione di file reali; poi integriamo i protocolli confermati.
Il PC non è automaticamente una dipendenza permanente della futura integrazione.

## Aggiornamento dalla 0.1.0 / 0.1.1

Chiudi il vecchio prototipo, estrai il nuovo ZIP in una cartella separata e avvia `Avvia-Kindle.cmd`.
La sessione protetta e i download sono conservati nello stesso archivio locale:
**non serve rifare il login**. Scegli **2 — Sincronizza e mostra catalogo**, poi
riprova il documento con **3**. La prima sincronizzazione aggiorna anche la
classificazione dei vecchi metadati memorizzati dalla 0.1.0.

Se invece il collegamento sul nuovo PC non era riuscito (`register / HTTP 400`),
scegli **1** e completa nuovamente login e OTP. La 0.1.2 intercetta il ritorno
Amazon anche con `/` nei parametri o nel codice opaco; quel risultato non viene
più lasciato arrivare alla pagina Amazon `/ap/maplanding` prima dell'app.
La registrazione avviene prima di chiudere Edge, evitando attese di pulizia sul
percorso di scambio del codice monouso. Non vengono ripetuti tentativi con lo
stesso codice né cambiate automaticamente identità o modalità di autenticazione.

I dizionari Amazon contrassegnati `DICT` / `FREE_DICT` sono nascosti dall'elenco
principale; **9** permette di mostrarli. Non usiamo parole come "Dictionary" nel
titolo per nascondere un libro. Un dizionario acquistato e identificato come tale
dal catalogo e un documento personale rimangono nell'elenco principale.

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

Usa il flusso **PKCE del menu 1**, già riuscito nella prima prova reale.
Il menu **8** resta una modalità storica facoltativa, che Amazon può non rendere
disponibile: non è necessario usarlo per il problema corretto nella 0.1.2.
Non avviene un passaggio automatico fra profili/dispositivi. Il profilo Kindle
iOS storico è documentato nel rapporto di ricerca; la compatibilità continua a
richiedere la verifica sul proprio account e dispositivo.
Una pagina Amazon che continua a mostrare un errore non equivale a un login riuscito.

Per gli errori HTTP di registrazione, la diagnostica distingue inoltre categorie
note come `invalid_grant` e `invalid_authentication_data`, quando Amazon le
restituisce, oppure `unknown`. Non copia messaggi, corpi di risposta, codici di
accesso, URL o valori di errore sconosciuti. Non inviare mai l'URL di ritorno.

## Cosa significa il risultato del download

- **Importabile**: un EPUB/PDF è stato riconosciuto e verificato strutturalmente,
  oppure Calibre ha prodotto un EPUB che supera gli stessi controlli. Il file
  `ready.epub` / `ready.pdf` è il candidato per KMReader; non è una dichiarazione
  che abbiamo già visto e verificato le pagine del tuo libro.
- **Download completo, preparazione necessaria**: le risorse necessarie alla
  lettura sono presenti, ma il contenuto non è ancora pronto per il nostro
  lettore. Il motivo compare nel terminale e in `preparation.json`. Non importare
  una risorsa `.azw` rinominandola `.epub`.
- **Errore di download**: un manifest o una risorsa non sono stati ottenuti
  integralmente. Il titolo non viene segnato completato; una revisione già
  scaricata resta intatta. Un nuovo tentativo richiede un manifest fresco.

Le annotazioni facoltative (`KINDLE_USER_ANOT` con requisito `DEFERRED` o
`PREFERRED`) possono essere XML o JSON validi: non sono considerate pagine
d'errore solo per il tipo MIME. Se il servizio non le rende disponibili, il
prototipo segnala l'assenza e continua con il documento; il dettaglio è nella
ricevuta `optional_resources_skipped`. Risorse di testo, allegati, metadati,
voucher e qualsiasi risorsa dichiarata obbligatoria devono comunque riuscire.
Pagine HTML, payload malformati ed errori di servizio non vengono accettati come
metadati validi. La diagnostica aggiunge tipo e numero della risorsa e stato HTTP,
senza includerne il contenuto o gli identificativi.

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
