# KMReader Kindle personale — prototipo Windows 0.1.5

Questo è il primo esperimento eseguibile per **Amazon.it**: accesso dal browser,
catalogo di acquisti e documenti personali, download completo e preparazione di
file da importare nel lettore di KMReader. Non richiede un accordo con Amazon.

È un programma separato dall'app: il lettore Android/Windows attuale non cambia.
Non è ancora il collegamento Kindle dentro le Impostazioni di KMReader. Prima
verifichiamo l'acquisizione di file reali; poi integriamo i protocolli confermati.
Il PC non è automaticamente una dipendenza permanente della futura integrazione.

## Aggiornamento alla 0.1.4: documento scaricato ma illeggibile

I documenti personali possono arrivare come **KFX**, anche se il file si chiama
`.azw`. La 0.1.3 non riconosceva la firma `CONT` e richiedeva Calibre: un download
completo poteva quindi rimanere `unknown / calibre_missing` e non essere leggibile.

La 0.1.4 include la conversione locale dei **KFX non cifrati** in EPUB con kfxlib,
senza installare Calibre o plugin. Verifica il file prodotto prima di dichiararlo
importabile. Conserva tutte le risorse necessarie, anche per i contenitori divisi.

Chiudi il vecchio prototipo, estrai tutto il nuovo ZIP e avvia `Avvia-Kindle.cmd`.
Per il documento già scaricato scegli **4 — Riprova preparazione**, selezionalo
e importa il `ready.epub` indicato in **KMReader → Libri locali**. Non occorre
rifare il login o riscaricare il documento. I nuovi download con **3** vengono
preparati automaticamente. La conversione avviene offline sul PC.

## Aggiornamenti precedenti

Chiudi il vecchio prototipo, estrai il nuovo ZIP in una cartella separata e avvia `Avvia-Kindle.cmd`.
La sessione protetta e i download sono conservati nello stesso archivio locale:
**non serve rifare il login**. Scegli **2 — Sincronizza e mostra catalogo**, poi
riprova il documento con **3**. La prima sincronizzazione aggiorna anche la
classificazione dei vecchi metadati memorizzati dalla 0.1.0.

Se invece il collegamento sul nuovo PC non era riuscito (`register / HTTP 400`),
scegli **1** e completa nuovamente login e OTP. La 0.1.3 usa l'ingresso italiano
per dispositivi `amzn_device_it` / `amzn_device_common_dark`, anziché quello
del vecchio client iOS. Allinea anche la richiesta completa di registrazione:
dominio dei cookie, token richiesti e nome dispositivo con gestione dei duplicati.
Non copia i cookie dal browser e non conserva quelli aggiuntivi ricevuti:
l'archivio DPAPI mantiene soltanto le credenziali necessarie al connettore.

Il codice opaco nel risultato del login viene percent-decodificato una sola volta:
un `+` letterale rimane `+`, senza diventare uno spazio come accadeva usando un
parser per moduli HTML. Rimangono l'intercettazione prima della pagina di ritorno
Amazon e lo scambio prima della chiusura di Edge. Identità del dispositivo,
sessioni e libri già salvati non vengono eliminati; il codice non viene ritentato.

Il percorso è stato confrontato con il client dispositivo di
[whispersync, revisione 7b5527b](https://github.com/bunkford/whispersync.koplugin/blob/7b5527b464c4e67a3b76838682bcfc0b2c98290d/whispersync.koplugin/amazon.lua#L554).
Questo è un riferimento del protocollo, non una prova del login sul tuo account.

I dizionari Amazon contrassegnati `DICT` / `FREE_DICT` sono nascosti dall'elenco
principale; **9** permette di mostrarli. Non usiamo parole come "Dictionary" nel
titolo per nascondere un libro. Un dizionario acquistato e identificato come tale
dal catalogo e un documento personale rimangono nell'elenco principale.

## Prova sul tuo PC

1. Estrai **tutto** lo ZIP in una cartella; lascia insieme `Avvia-Kindle.cmd`,
   la cartella `KMReader-Kindle` e i suoi file. Serve Windows 10/11 x64 con Chrome o Edge installato.
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

**Chrome è il browser predefinito per i nuovi collegamenti.** Il menu **10**
permette di scegliere Chrome o Edge e ricorda la scelta per gli avvii successivi.
La preferenza riguarda solo il login del prototipo e non cambia il browser
predefinito di Windows. Le sessioni già collegate restano valide qualunque sia
il browser selezionato. `login --browser chrome` / `login --browser msedge`
permettono invece di scegliere il browser per il singolo comando.

Usa il flusso **PKCE del menu 1**. Le sessioni già collegate con l'ingresso
precedente vengono riutilizzate: non sono costrette a un nuovo login.
Il menu **8** resta una modalità storica facoltativa, che Amazon può non rendere
disponibile: non serve usarlo per la nuova prova con la 0.1.3.
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
  oppure il convertitore ha prodotto un EPUB che supera gli stessi controlli. Il file
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

Per **KFX non cifrati**, il convertitore incluso usa kfxlib in un processo separato,
senza passargli credenziali Amazon. Riconosce il contenuto reale invece di affidarsi
all'estensione. Un file non supportato non viene segnato importabile.

Per **MOBI/KF8** rimane disponibile `ebook-convert.exe` di un'installazione locale
di [Calibre](https://calibre-ebook.com/download_windows). Il parametro `--converter`
permette anche di scegliere esplicitamente un convertitore esterno per KFX.
La compatibilità dei titoli protetti va verificata separatamente: il convertitore
incluso non li decifra. In ogni caso puoi usare **4 — Riprova preparazione** senza
riscaricare le risorse. La conversione non invia i file a terzi.

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

L'app Flutter rimane MIT e non dipende da questo programma. L'eseguibile separato
del prototipo include **kfxlib di John Howell, GPL-3.0-or-later** ed è distribuito
nel suo insieme sotto GPL-3.0-or-later; il codice originale mantiene gli avvisi MIT.
Lo ZIP contiene `LICENSE`, `MIT-LICENSE` e gli avvisi delle dipendenze. Nella stessa
release si trova `KMReader-Kindle-0.1.5-source.zip`, con sorgenti corrispondenti del
prototipo, sorgenti kfxlib della revisione fissata e istruzioni di ricompilazione.

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

## Probe progressivo 0.1.5

Il menu **11** misura letture Range del KFX originale e disponibilità dei dati
Kindle di posizione/annotazioni, usando esclusivamente GET. `progressive-probe.json`
contiene contatori, tempi e categorie, senza contenuto, titoli, identificativi,
credenziali o URL. La risorsa deve avere una versione verificabile (ETag forte o
Last-Modified); intervalli errati, cambiamenti e trasferimenti troncati falliscono.
Un server che restituisce il file completo viene dichiarato come tale.

`probe-file documento.kfx --output report.json` confronta l'estrazione parziale
con la decodifica completa, verificando testo e posizioni originali. La misura
di memoria è delle sole allocazioni Python tracciate, non della memoria totale
del processo; i tempi locali non predicono quelli del telefono. Gli offset del
DOM UTF-16 vengono mappati sulle posizioni Kindle per carattere Unicode senza
normalizzare il testo. Il probe non riproduce ancora l'impaginazione editoriale
e non abilita scritture di sincronizzazione.
