# Kindle in KMReader: fattibilità e integrazione

Ricerca del 4 novembre 2026. Analisi di documentazione pubblica e codice sorgente;
nessun accesso a un account Amazon e nessuna verifica autenticata dei servizi.
Il requisito è una libreria nativa e la lettura nel motore di KMReader. Incorporare
Kindle for Web come lettore non soddisfa questo requisito.

## Risultato

L'integrazione è realizzabile per i contenuti ottenibili in un formato leggibile,
ma collegare l'account non rende automaticamente leggibili tutti i libri Kindle.
Occorre separare autenticazione, catalogo, consegna del file, eventuale conversione
e lettura. Non ho trovato un'API pubblica Amazon documentata che conceda a una
generica applicazione accesso completo alla libreria Kindle e la lettura dei libri
protetti con un motore indipendente.

Una novità cambia la soluzione preferibile: Amazon documenta che **dal 20 gennaio
2026 gli acquirenti verificati possono scaricare EPUB e PDF dei libri per cui è
stata confermata l'esportazione senza DRM**, da Gestisci i tuoi contenuti e
dispositivi. L'abilitazione dipende dal titolo/editore; i vecchi titoli richiedono
la conferma dell'editore. Non comprende automaticamente tutti i libri senza DRM
preesistenti e non comprende i prestiti tramite abbonamenti, anche quando il libro
è senza DRM. Questi EPUB/PDF possono essere letti direttamente da KMReader.

Fonte primaria: [Amazon KDP: Digital Rights Management](https://kdp.amazon.com/en_US/help/topic/GDDXGH9VR22ACM8U).

| Contenuto consegnato | Lettura in KMReader | Lavoro necessario |
|---|---|---|
| EPUB/PDF esportato ufficialmente da Amazon | Compatibile con i motori esistenti | Accesso al file, importazione e collegamento al catalogo Kindle |
| Documento personale consegnato come EPUB/PDF | Compatibile se il file è effettivamente disponibile | Verificare formato e disponibilità; PDOC è una categoria, non un formato |
| Documento personale MOBI/KF8/AZW3 senza protezione | Non supportato direttamente oggi | Conversione verificata in EPUB, con immagini, indice e metadati |
| Documento personale KFX senza protezione | Non supportato direttamente oggi | Manifest e risorse complete, decodifica KFX e conversione EPUB |
| Libro acquistato consegnato con DRM | Il login e il download non bastano | Un percorso autorizzato per il contenuto leggibile; nessun supporto universale dimostrato dai progetti analizzati |
| Prestito/abbonamento Kindle | Non assimilabile a un EPUB acquistato esportabile | Gestione delle disponibilità e dei vincoli del servizio; escluso dal percorso ufficiale EPUB/PDF descritto sopra |

## ksync

Sorgente verificato: [fc00a7b](https://github.com/kafkasl/ksync/tree/fc00a7b7a04badfbd61f3e42aaaa5e45e1d0cfd7),
aggiornato il 20 ottobre 2026, licenza GPL-3.0-or-later.

È principalmente uno strumento di sincronizzazione delle annotazioni dei documenti
personali. Il suo README esclude esplicitamente i libri acquistati protetti e i
documenti che Amazon consegna soltanto nel vecchio formato MOBI. Non è un SDK di
lettura o un connettore completo pronto per un'app Android/Windows.

Dal codice di `ksync/core.py`:

- `_library` interroga `FionaTodoListProxy/syncMetaData` con richieste firmate come
  dispositivo Kindle. `sync` seleziona soltanto gli elementi di tipo PDOC.
- `_manifest` richiede il manifest del documento e seleziona la risorsa KFX
  principale. Il codice non rappresenta un downloader generale di tutti i tipi
  di manifest e risorse possibili.
- `_chunks` usa kfxlib per ricostruire le posizioni del testo. `books` espone i
  documenti con annotazioni, non l'intera libreria nativa richiesta da KMReader.
- La richiesta della libreria usa un limite di 1000 elementi senza una gestione
  generale di paginazione visibile in questa implementazione.

L'accesso iniziale **non è implementato**: il README richiede di acquisire una
registrazione dell'app Kindle per Mac tramite un proxy TLS, poi conservare chiave
del dispositivo, token ADP e token di accesso/rinnovo. Descrive un possibile flusso
OAuth con PKCE ma lo lascia fuori dal progetto. Quella procedura manuale non è il
login Amazon utilizzabile nell'app richiesto dall'utente.

È un riferimento recente utile per metadati, manifest PDOC e annotazioni. Non
dimostra la lettura dei libri acquistati protetti e non risolve il login.

## Kindle_download_helper

Sorgente verificato: [141928a](https://github.com/yihong0618/Kindle_download_helper/tree/141928ac7965f8c770f6309e608139d4c87c2aba),
ultimo aggiornamento del repository il 15 febbraio 2025, GPL-3.0-or-later.

Contiene due percorsi distinti:

- `kindle.py`: cookie/CSRF della pagina dei contenuti, inventario e dispositivi,
  download tramite il servizio storico FSDownloadContent. Dipende dai dati di
  un dispositivo e dalle risposte di servizi privati Amazon.
- `no_kindle.py` e `amazon_api.py`: registrazione/rinnovo come applicazione Kindle,
  firma delle richieste, metadati e manifest digitali. Il codice comprende anche
  elaborazione dei voucher e conversione: l'EPUB finale non è semplicemente il
  file ottenuto da un normale login web.

Le credenziali applicative/dispositivo non coincidono con i cookie del browser.
Il codice dichiara identità/versioni di applicazioni Amazon, contiene assunzioni
legate ai marketplace e ai formati di allora, e non è una libreria Dart mobile.
La configurazione del percorso web esaminata non include Amazon.it. L'implementazione
del catalogo costruisce parametri di sincronizzazione che nel metodo esaminato non
vengono poi passati alla richiesta: il solo README non basta a valutare completezza
e affidabilità di una sincronizzazione.

Le issue riportano accesso alla lista senza download, errori sui dispositivi e
403 sui documenti personali: [#181](https://github.com/yihong0618/Kindle_download_helper/issues/181),
[#184](https://github.com/yihong0618/Kindle_download_helper/issues/184) e
[#185](https://github.com/yihong0618/Kindle_download_helper/issues/185).
La [#182](https://github.com/yihong0618/Kindle_download_helper/issues/182) segnala
inoltre il cambiamento del download storico nel 2025; è una segnalazione del
progetto, non una verifica autenticata attuale per ogni marketplace.

È utile come descrizione di protocolli e formati. Non lo considero una base da
incorporare e presentare come compatibilità Kindle completa nel 2026.

## Alternative e confini dei formati

- [Login with Amazon: Customer Profile](https://developer.amazon.com/docs/login-with-amazon/customer-profile.html)
  documenta gli ambiti profile, profile:user_id e postal_code. Un'autenticazione
  LWA riuscita non concede, attraverso questi ambiti, libreria o download Kindle.
  Il collegamento deve quindi dimostrare separatamente l'accesso ai servizi
  effettivamente necessari; un pulsante di login generico sarebbe ingannevole.
- [libmobi](https://github.com/bfabiszewski/libmobi) è una libreria C per MOBI/KF8,
  con build documentate anche per Android e Windows e licenza LGPL-3.0. È una
  candidata più leggera di un runtime Python per i vecchi documenti compatibili;
  non è un client Amazon e non decodifica KFX.
- [KindleUnpack](https://github.com/kevinhendricks/KindleUnpack) estrae contenuti
  Kindle/MOBI non protetti, in Python e con licenza GPL-3.0. Il suo README precisa
  che l'output KF8 può essere soltanto una struttura simile a un EPUB, da validare.
- [KFX Input / kfxlib](https://www.mobileread.com/forums/showthread.php?t=291290),
  di cui ksync include una copia, gestisce il formato KFX. Conversione del formato
  e disponibilità del contenuto non cifrato sono problemi distinti. Non basta
  rinominare un AZW/KFX in EPUB e non basta che il documento sia personale.

I due progetti proposti e kfxlib usano GPL, mentre KMReader-Porting è MIT. L'eventuale
distribuzione di quel codice richiede una strategia di licenza appropriata; non
sono stati aggiunti al prodotto né eseguiti. I protocolli possono essere studiati
per progettare un adattatore indipendente. L'aggiunta di Python/calibre e delle
sue dipendenze dentro il lettore sarebbe anche in contrasto con il requisito di
leggerezza, soprattutto su Android.

## Architettura proposta per KMReader

L'implementazione va divisa in un provider Kindle e nella pipeline documenti già
esistente, senza caricare la pagina Amazon durante la lettura.

1. **Account.** Browser di autenticazione Amazon, gestione di MFA/consenso e prova
   dell'accesso al catalogo. Il semplice successo del login non abilita la voce
   account connesso. Token e credenziali di dispositivo, se necessari, hanno un
   namespace separato nel `CredentialVault` già presente; non entrano nei log o
   nel normale database dei libri. Disconnessione ferma i lavori e revoca/rimuove
   la sessione del provider, mantenendo le copie locali gestite dall'utente.
2. **Catalogo nativo.** Identità stabile account/marketplace/ASIN/tipo EBOK o PDOC,
   titolo, autori, copertina, aggiornamenti e disponibilità del file. Una sorgente
   Kindle nella libreria aggrega questi elementi con le altre sorgenti. Non va
   simulato un server Komga: l'autenticazione e il protocollo sono diversi.
3. **Consegna.** Il provider risolve l'offerta effettivamente disponibile per quel
   titolo. Privilegiare l'esportazione ufficiale EPUB/PDF; non dedurre la leggibilità
   dalla presenza nel catalogo. URL firmati hanno scadenza; servono ripresa, rinnovo
   della richiesta, cancellazione, controllo della dimensione e verifica del file.
4. **Normalizzazione.** Verificare il formato reale dai contenuti. EPUB/PDF validi
   entrano nella pipeline esistente. MOBI/KF8/KFX richiedono un convertitore separato
   e verificato, eseguito fuori dal thread UI, con indice, immagini e font preservati.
   Prima di annunciare disponibilità offline, validare il risultato e completare
   il salvataggio atomico.
5. **Lettura KMReader.** `LocalLibrary.importFile` accetta oggi EPUB/PDF/CBZ/ZIP e
   usa già una copia temporanea, hash e analisi in isolate. Il file normalizzato
   può arrivare a `DocumentReader`/`BrowserEpubReader` o al motore PDF, mantenendo
   il collegamento al titolo Amazon nel catalogo. Nessun Kindle for Web incorporato
   come lettore sostitutivo.
6. **Posizione e annotazioni.** Inizialmente conservare la posizione KMReader.
   CFI EPUB, posizioni MOBI e posizioni KFX non sono intercambiabili. La sincronizzazione
   verso Amazon richiede una mappatura verificata separata; non inviare le nostre
   posizioni come se fossero posizioni Kindle.

### Download prima dello streaming

Per la prima versione scegliere download e apertura nel motore locale, opzione
esplicitamente ammessa dal requisito. L'host EPUB attuale legge un archivio ZIP
locale completo. Lo streaming vero richiederebbe accesso casuale alle risorse,
lettura dell'indice ZIP via HTTP Range, gestione dei server che non supportano Range
e degli URL scaduti. Mostrare il lettore web Amazon o scaricare tutto di nascosto
prima dell'apertura non costituirebbe uno streaming nativo già implementato.

### Verifica necessaria prima di presentare il collegamento come funzionante

Serve una prova autenticata sul marketplace effettivo, con MFA, libri acquistati
esportabili, documenti personali recenti e vecchi, titoli non esportabili, librerie
paginate, rinnovo della sessione e download interrotti. Le prove devono verificare
che il libro si apra effettivamente nel lettore KMReader, rimanga leggibile offline
e non introduca un runtime di conversione nel percorso delle animazioni.

## Decisione per questa consegna

La 0.8.17 corregge il curl dei fumetti e include questa ricerca. **Non contiene un
collegamento Amazon funzionante né una promessa di accesso universale ai libri
Kindle.** La base concreta da sviluppare è il provider nativo con esportazioni
EPUB/PDF e disponibilità per titolo; documenti in formati Kindle e contenuti
protetti hanno dipendenze ulteriori esplicitate sopra. Un connettore basato soltanto
su cookie o sugli script citati non soddisferebbe l'obiettivo completo.
