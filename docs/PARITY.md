# Matrice di parità e chiusura del porting KMReader

**Stato: porting ancora aperto; release stabile non pronta.**
Aggiornamento del documento: 14 novembre 2026. Piattaforme: Android e Windows.

Questa è la lista di lavoro per concludere il porting. La sorgente corrente è
**1.0.0+36 in sviluppo**. Il checkpoint distribuito **1.0.0+30**, verificato al
commit `4b93c91ddfd5b847f92dcdb888643e96dc1320a6`, resta conservata. La build 31
aggiunge le correzioni curl/Kindle e gli interventi di parità elencati sotto;
non chiude tutte le aree della matrice.

Il riferimento rimane [kmworks/kmreader](https://github.com/kmworks/kmreader/tree/e2b35f8796cc830fc6e7464e161b2172d8f916e9)
al commit `e2b35f8796cc830fc6e7464e161b2172d8f916e9`. Aggiornare il riferimento
richiede un confronto esplicito delle differenze. La vecchia matrice e tutti i
checkpoint sono [conservati nell'archivio](../archive/docs/parity-before-closure-plan-2026-11-07.md).

La build 35 aggiunge il compositore per lo scorrimento automatico, il preriscaldamento
del curl in entrambe le direzioni e la correzione della griglia pixel frazionaria.
Aggiunge inoltre aggiornamenti in-app da file pubblici GitHub (Android con conferma
del sistema; Windows con backup/ripristino). Queste implementazioni non chiudono
AT-01/AT-07: installazione reale e confronto Hyperion restano da accettare.

## Come si dichiara concluso il lavoro

- [ ] **Perimetro chiuso:** A-01–A-03 identificano tutte le operazioni applicabili
  del riferimento, i relativi adattamenti e le esclusioni motivate.
- [ ] **Parità funzionale chiusa:** F-01–F-13 hanno un esito verificato; nessuna
  funzione applicabile rimane mancante o parziale senza una decisione esplicita.
- [ ] **Accettazione conclusa:** AT-01–AT-08 hanno evidenze per Android e Windows,
  oltre ai backend richiesti dalle funzioni effettivamente supportate.
- [ ] **Release pronta:** R-01–R-05 sono verificati sulla sorgente finale e sui
  pacchetti effettivamente destinati alla distribuzione.

Una voce si chiude con sorgente, risultato atteso, verifica eseguita e risultato
osservato. Un controllo presente nell'interfaccia, un test saltato o una CI verde
non chiudono automaticamente la parità. Se manca un dispositivo/backend, la
validazione resta aperta. Una voce dubbia non diventa automaticamente «futura».

Per il porting interessa la stessa operazione e lo stesso risultato utente sulle
due piattaforme. Controlli nativi e API Apple possono richiedere un adattamento,
che va descritto e provato. La parità visiva richiede confronti delle schermate;
non è stata dimostrata un'identità pixel per pixel con Apple.

## Stati ed evidenze

| Stato | Significato |
|---|---|
| Implementato / da validare | Il comportamento esiste e ha copertura parziale; manca l'accettazione indicata. |
| Parziale | È già registrata una lacuna funzionale o di presentazione da risolvere/confrontare. |
| Da delimitare | Il vecchio elenco non documenta abbastanza il requisito upstream o l'equivalente di piattaforma. L'audit resta obbligatorio. |
| Futuro / escluso | Fuori dal perimetro per una motivazione dichiarata; non viene conteggiato come parità implementata. |
| Chiuso | Requisito, implementazione/adattamento ed evidenza soddisfano il criterio di accettazione. |

Le evidenze correnti sono in [VALIDATION.md](VALIDATION.md). La build 35,
sorgente `69a127d50354aed80983d72988cde186d611c8b2`, supera [CI completa](https://github.com/LeValue/KMReader-Porting/actions/runs/43588228905),
[consegna verificata](https://github.com/LeValue/KMReader-Porting/actions/runs/43590146370) e confronto dei download. La nuova
[candidate.5](https://github.com/LeValue/KMReader-Porting/releases/tag/v1.0.0-candidate.5) è pubblica/prerelease per gli aggiornamenti in-app:
APK firmato originale, tutti i 711 file Windows identici alla CI e manifest
pubblico verificato senza credenziali. Le 46 release/184 risorse precedenti sono
conservate. AT-01 e AT-07 restano aperti per aggiornamento fisico e Hyperion.

La build 34,
sorgente `2ebd0d9426e0f05e7e9011bb8ddfc70ffb0f10e1`, ha superato
[tutti e tre i job CI 43507849435](https://github.com/LeValue/KMReader-Porting/actions/runs/43507849435).
[Candidate.4](https://github.com/LeValue/KMReader-Porting/releases/tag/untagged-d2f6d537abce94cd6b9a) contiene APK Android universale firmato e Windows:
firma, architetture, versione/sorgente, allineamento e hash verificati; download
APK identico al file firmato locale e tutti i 710 file Windows identici alla CI.
Le nuove regressioni coprono il trascinamento touch fra capitoli e la resa del
curl quasi steso a densità 3×. Il confronto fisico sulle pagine Hyperion segnalate,
compresa la rara variazione di spaziatura, resta in AT-07. I pacchetti precedenti
rimangono conservati. Per il servizio Kindle rimane valida la prova della build 33:
La prova reale EPUB ha confermato metadati/copertina, ripristino di progresso e
segnalibri, ritiro dell'originale e riapertura senza nuove scritture. Restano
copertura residua del servizio, accettazione installata e gli altri requisiti
indicati sotto. Le evidenze delle build precedenti rimangono nel registro.

L'[audit delle impostazioni](SETTINGS_AUDIT.md) registra 128 chiavi/campi:
105 implementati, 9 adattati, 5 parziali, 3 interni e 6 non disponibili sulla
piattaforma. Non sono 128 funzionalità indipendenti né una percentuale di porting.
I cinque campi parziali riguardano la libreria dei modelli, rinviata come indicato
più sotto. Le altre lacune di questa matrice rimangono indipendenti da quei conteggi.

## Matrice attuale per area

Le prove collegate sono punti di partenza per la verifica, non certificazioni
dell'intera riga. Gli ID indicano il lavoro necessario per chiuderla.

| Area | Presente nella candidata | Stato | Chiusura richiesta / evidenza di partenza |
|---|---|---|---|
| Accesso, account, credenziali | Password/API key, primo accesso, cambio password, profili isolati, vault OS e blocco biometrico/PIN/Hello | Implementato / da validare | AT-01, AT-05; [test accesso](../test/auth_key_test.dart), [gestione account](../test/server_management_test.dart) |
| Server, librerie, amministrazione | Creazione/modifica librerie, operazioni di scansione, task/sessioni/log, metadati e integrazione Komf opzionale | Da delimitare / da validare | A-02, AT-04; [test amministrazione](../test/server_management_test.dart) |
| Dashboard | Libri EPUB/PDF separati dai fumetti DIVINA, ordinamento per aggiunta, nessun limite sulla data di pubblicazione; filtri condivisi con Mostra tutto, scope librerie, ordine/stile sezioni e continuazione liste | Implementato / da validare | AT-02, AT-05; [regressioni dashboard](../test/dashboard_sections_test.dart), [Komga reale](../test/live_komga_test.dart) |
| Catalogo e ricerca | Paginazione, ricerca, filtri annidati, selezioni/batch e indice SQLite FTS per account | Parziale | F-01, F-02; [strumenti catalogo](../test/catalog_tools_test.dart), [catalogo offline](../test/offline_catalog_test.dart) |
| Dettagli, raccolte e liste | Metadati e lock, modifiche singole/batch, raccolte/liste ordinate, pin e smart list kmrs | Parziale | F-03, F-10, AT-04, AT-05 |
| Lettore fumetti | LTR/RTL, Webtoon, pagine doppie/singole, zoom/rotazione/crop, pagine larghe, progresso e continuazione; curl singolo con trasparenza e gesti sui bordi reali della pagina | Implementato / adattamento da validare | F-04, F-10, AT-02, AT-07; [curl](../test/page_transition_test.dart), [gesti](../test/reader_gestures_test.dart) |
| PDF | PDFium o lettore fumetti, qualità raster, ricerca/outline, password non persistite, layout e continuazione | Parziale / da validare | F-05, AT-02, AT-03; [test PDF](../test/pdf_reader_test.dart) |
| EPUB | WebView/WebView2, Epub.js, CFI, continuo/paginato, fixed layout/CJK, font/temi, ricerca/segnalibri/note e animazioni | Parziale / da validare | F-06, F-10, AT-02, AT-07; [browser](../test/epub_browser_test.dart), [audit EPUB](EPUB_RENDERING_AUDIT.md) |
| Libri locali | Importazione streaming EPUB/PDF/CBZ/ZIP, copie proprie, deduplicazione, lettura/progresso indipendenti dagli account | Implementato / da delimitare | A-03, AT-06; [test importazione](../test/local_library_test.dart) |
| Download e offline | Coda limitata, annulla/riprova/ripresa, Range/If-Range, lease, protezione account e worker Android/Windows | Parziale / da validare | F-02, F-07, AT-03; [ripresa](../test/download_resume_test.dart), [worker](../test/download_worker_test.dart) |
| Progresso e sincronizzazione | Outbox durevole, revisioni, conflitti e avanzamento nei lettori; locatori Kindle verificati rispetto all'edizione | Implementato / da validare | AT-05; [repository Kindle](../test/kindle_repository_test.dart), [procedure](TESTING.md) |
| Aggiornamenti live | SSE, riconnessione, Last-Event-ID, invalidazioni mirate, refresh e stato task; rimozione metadati eliminati, riconciliazione dopo riconnessione e SessionExpired per account | Implementato / da validare | F-08; [test eventi](../test/server_event_test.dart) |
| Cache e prestazioni | Cache persistenti, quote immagini/documenti, rivalidazione condizionale, protezione originali e lavoro in isolate | Implementato / da validare | F-05, F-07, A-03, AT-07 |
| Impostazioni e API key | Navigazione adattiva, preferenze globali/per libro, preset/font, cache/rete/privacy, API key e attività autenticazione | Parziale / da validare | A-02, F-11, F-12, AT-01; [audit](SETTINGS_AUDIT.md), [test impostazioni](../test/settings_parity_test.dart) |
| Cronologia e statistiche | Cronologia locale/server, filtri di libreria, riepiloghi/heatmap/grafici ed endpoint estesi con fallback | Parziale / da delimitare | A-01, F-09, F-10, AT-04; [test statistiche](../test/reading_stats_test.dart) |
| Kindle integrato | Catalogo, conversione/lettura/offline, copertine e locatori; importazione file locali nel cloud; dizionari esclusi, recupero classificazioni vecchie, indicizzazione asincrona e copertine limitate | Implementato / da validare; gestione remota parziale | F-13, AT-01, AT-05, AT-06, AT-07; [limiti e protocollo](KINDLE_IMPORT.md), [test invio](../test/kindle_import_test.dart) |
| Sistema operativo e distribuzione | Avvio Android/Windows, icone, protezione cattura, fullscreen/keep-awake, worker e pacchetto Windows portabile | Adattamento da validare / da delimitare | A-03, F-04, AT-01, AT-03, AT-08, R-01–R-05 |
| Interfaccia, accessibilità e lingue | Asset originali, temi chiaro/scuro, layout adattivi e cataloghi di traduzione | Parziale | F-10, F-12, AT-08; [riferimenti iPad](IPAD_REFERENCE.md) |
| AI/OCR/modelli/traduzione | Esistono controlli sperimentali e componenti già integrati | Futuro per la chiusura richiesta | FUT-01; conservare codice, preferenze e descrizione dei limiti |

## A — Chiudere il perimetro del confronto

Questi audit producono un elenco preciso delle differenze; non costituiscono
un'autorizzazione a rinviare le funzioni applicabili.

| ID | Lavoro ancora aperto | Criterio di chiusura |
|---|---|---|
| A-01 | Completare la corrispondenza tra schermate/azioni del riferimento e port: accesso/navigazione, catalogo, dettagli/liste, lettori, offline, statistiche/cronologia e impostazioni | Ogni operazione ha percorso sorgente upstream, equivalente nel port, differenza osservata e test/accettazione. Ogni mancanza applicabile ha una voce F concreta; eliminare formule vaghe come «altri layout» o «tutti i filtri» senza inventario. |
| A-02 | Confrontare modifica/protezione server, opzioni amministrative e identificazione delle API key inserite manualmente | Elenco dei campi/azioni applicabili, permessi richiesti, supporto stock Komga/kmrs e comportamento se il server non espone la capacità. Correggere le lacune applicabili; nessuna falsa identificazione della chiave attiva o comando amministrativo apparentemente funzionante. |
| A-03 | Delimitare le voci generiche del vecchio backlog: RAR/CBR locale, monitoraggio cartelle, pagine d'archivio a richiesta, preload avanzato, widget, indicizzazione di sistema, azioni rapide, notifiche, finestre multiple e installer/aggiornamento di sistema | Per ciascuna voce registrare requisito e sorgente upstream oppure natura di estensione. Le capacità equivalenti disponibili su Android/Windows restano da implementare/validare se necessarie alla parità; un rinvio aggiuntivo richiede una decisione esplicita registrata. Nessuna di queste voci è già considerata esclusa. |

## F — Lacune e confronti funzionali da chiudere

L'elenco riprende i punti aperti della vecchia matrice. Dove la descrizione era
generica, il primo passo è riprodurre la differenza rispetto al riferimento.
Una voce già coperta può essere chiusa con evidenza; una lacuna confermata
richiede implementazione e verifica del comportamento.

| ID | Lavoro da completare | Accettazione richiesta |
|---|---|---|
| F-01 | Inventario e completamento di ordinamenti, filtri e azioni del catalogo applicabili | Stessi risultati su dati equivalenti, inclusi filtri annidati, scope librerie, ricerca e seleziona tutto oltre la prima pagina; controlli e persistenza coerenti con il riferimento. |
| F-02 | Parità delle liste speciali e di On Deck offline | Confrontare elenco/ordine/stato con il riferimento; dopo preparazione e riavvio offline, nessuna lista incompleta presentata come completa, nessun contenuto di un altro account e nessuna richiesta di rete. |
| F-03 | Copertine/miniature personalizzate nei dettagli e nelle liste | Verificare i percorsi previsti dal riferimento; completare caricamento/sostituzione/ripristino e invalidazione della cache ove applicabili, con permessi ed errori corretti. La sola visualizzazione delle copertine non chiude questa voce. |
| F-04 | Condivisione/esportazione tramite il sistema | Provare l'operazione su Android e Windows, anche per ciascuna pagina di uno spread; annullamento e file temporanei corretti, originali/progresso preservati. Documentare l'equivalente nativo quando differisce dalla share sheet Apple. |
| F-05 | Strategia PDF offline e quota dei derivati | Confrontare la preparazione raster con il riferimento e chiudere la lacuna di preparazione massiva/quota persistente, oppure dimostrare l'equivalenza della strategia con originale locale. Entrambi i lettori devono aprire tutte le pagine dopo riavvio offline, con cache limitata e originali protetti. |
| F-06 | EPUB misti/CJK, resa tipografica e strumenti testuali applicabili | Fixture per scritture/layout misti, colonne, font e reflow: destinazioni/CFI corretti e nessun salto o falso completamento. Delimitare lookup/dizionario nel lettore separatamente dai dizionari Kindle nascosti in libreria; le estensioni AI/traduzione restano FUT-01. |
| F-07 | Gestione dello spazio e interfaccia di pulizia/download | Rendere chiari uso disco, contenuti scaricati e cache eliminabile; provare quota raggiunta, pulizia, file attivi, coda interrotta e ripresa. Non eliminare originali protetti o progresso per rientrare in una quota. Confrontare le azioni con il riferimento. |
| F-08 | Invalidazione completa degli eventi live applicabili | Mappare eventi di libri/serie, metadati/copertine, liste, progresso e task agli aggiornamenti attesi. Dopo riconnessione la vista torna coerente senza riavvio, duplicati o cicli di richieste; rispettare refresh disabilitato e scope account. |
| F-09 | Completezza dei metadati offline per cronologia/statistiche | Confrontare risultati e filtri con dati controllati e indice completo; snapshot parziali o fallback locali devono essere riconoscibili. Accettazione anche su server con endpoint estesi, senza mascherare errori di autenticazione come capacità assenti. |
| F-10 | Layout dei dettagli, sidebar, offline e coerenza dei lettori | Confronto schermata per schermata con A-01 e riferimenti iPad: destinazioni Offline/Server, librerie/collasso sidebar, riepiloghi offline, layout dei dettagli, tipografia e controlli. Implementare differenze funzionali e documentare gli adattamenti nativi; raccogliere screenshot comparabili. |
| F-11 | Predefiniti, unità, visibilità e precedenza delle impostazioni | Confrontare nuove installazioni e aggiornamenti, preferenze globali/per libro, preset/font e controlli condizionali. Una modifica deve avere l'effetto previsto senza cancellare locatori o scelte non coinvolte; mantenere distinto il fallback HTML EPUB ridotto. |
| F-12 | Completare localizzazione di controlli, nuovi flussi ed errori | Verificare tutte le lingue dichiarate in `Strings.locales`, compresi importazione Kindle e dashboard. Nessuna chiave grezza, testo troncato o fallback inglese involontario nelle traduzioni completate; provare formati di date/numeri e testi ingranditi. |
| F-13 | Gestione remota dei documenti personali Kindle: aggiunta, eliminazione, metadati/copertina e sovrascrittura con risincronizzazione | Chiudere K-01–K-06 nel [piano del servizio](KINDLE_LIBRARY_MANAGEMENT.md). Ambito PDOC, esclusi gli acquisti Amazon. Prima risolvere l’errore di collegamento segnalato; per sostituire un documento salvare e rimappare stato/segnalibri, verificarli nel cloud e ritirare l’originale solo dopo la migrazione. Una modifica locale non vale come aggiornamento Amazon. |

## Interventi della build 31 sulla matrice

| Voce | Implementato e verificabile nel codice | Cosa resta aperto |
|---|---|---|
| F-08 | Mappatura delle famiglie eventi upstream, eliminazioni nell'indice offline senza toccare file/progresso, protezione da risposte tardive, scope utente, riconciliazione dopo riconnessione, rispetto del refresh disabilitato, stop su SessionExpired. [Regressioni](../test/parity_closure_test.dart), [SSE](../test/server_event_test.dart). | Accettazione con backend e UI su entrambe le piattaforme; audit completo A-01/A-02. |
| F-09 | Statistiche offline da tutti i metadati indicizzati, comprese serie/generi/tag, scope libreria/account; indici interrotti marcati incompleti; catalogo/cronologia segnalano cache parziali. Endpoint estesi e errori di autenticazione conservano il comportamento già testato. [Regressioni](../test/parity_closure_test.dart), [statistiche](../test/reading_stats_test.dart). | Confronto finale sul server con estensioni e accettazione AT-04. |
| F-12 | Etichetta Autore nelle dieci lingue e traduzioni italiane dei nuovi flussi Kindle. | Le altre nuove frasi restano con fallback inglese nelle lingue non ancora completate; F-12 non è chiusa. |
| F-13 | OAuth invio separato, copia EPUB modificata, eliminazione PDOC con backup/journal/verifica. | Build 33 implementa ripristino del punto nel testo, segnalibri e stato locale di completamento per EPUB con mappatura verificata; endpoint MyCD aggiornato. Prova reale EPUB completata: metadati/copertina, progresso/segnalibri e ritiro confermati. Restano i limiti K-01–K-06, compresi PDF, note/evidenziazioni e accettazione UI/secondo dispositivo. |

Aggiornamento build 32: sul desktop reale sono passati registrazione Firs,
riuso delle credenziali e invio di un solo EPUB sintetico con rilettura del catalogo
([42483122733](https://github.com/LeValue/KMReader-Porting/actions/runs/42483122733)).
Le correzioni riguardano media type/XML e TTL relativo dell'upload URL. Questo
chiude la riproduzione del blocco di invio in K-01, non F-13 o AT-06 nel complesso:
Build 33 distingue anche libreria cloud e solo dispositivi: prove account passate e ricezione Android confermata dall’utente. Eliminazione, metadati/copertina e ripristino EPUB sono verificati sul documento sintetico reale ([42514185821](https://github.com/LeValue/KMReader-Porting/actions/runs/42514185821)). Restano accettazione UI installata/secondo dispositivo e copertura PDF/note/evidenziazioni; F-13 resta aperta.

Questi interventi completano sottorequisiti concreti. Nessuna riga è dichiarata
«Chiusa» soltanto perché il relativo test host passa; l'accettazione residua resta
esplicita. I pacchetti della build 30 non contengono gli interventi della build 31.

## AT — Accettazione su piattaforme e backend reali

Registrare per ogni prova commit, piattaforma/dispositivo, OS/runtime, dati di
prova, passi, risultato e log/screenshot essenziali in [VALIDATION.md](VALIDATION.md).
Non registrare credenziali o testi dei libri. Gli account/profili di prova devono
essere isolati; non eseguire prove distruttive su un server personale.

| ID | Prova ancora da completare | Esito necessario |
|---|---|---|
| AT-01 | Installazione pulita e aggiornamento in-place dalla 0.9.1 firmata su Android e dal pacchetto Windows precedente | Account/vault, download, progresso, segnalibri, preferenze e identità conservati. Dalla build 35 provare anche aggiornamento in-app Android (permesso/conferma/annullamento) e Windows (chiusura/riapertura/rollback). Provare blocco biometrico/PIN/Hello, riavvio, sospensione e cambio/rimozione di un account mantenendo utilizzabile l'altro. |
| AT-02 | Percorso accesso → catalogo → lettura → chiusura/riapertura nei tre lettori | Su Android touch e Windows mouse/tastiera: singole/doppie pagine, LTR/RTL, crop/zoom/rotazione, Webtoon, PDF e EPUB reflow/fixed/CJK; margini e inset corretti, curl/tocchi coerenti e posizione conservata. Confrontare anche ritmo e resa con il riferimento. |
| AT-03 | Download e lettura offline in condizioni avverse | Su entrambi i sistemi: coda ampia, rete persa/cambiata, chiusura/ripresa, storage pieno, worker in background e regole rete/alimentazione. Provare anche restrizioni OEM Android e Task Scheduler Windows; nessuna perdita o duplicazione di dati. |
| AT-04 | Funzioni di liste/admin/statistiche su backend supportati | Oltre a stock Komga, verificare kmrs smart list/condivisione, Komf e statistiche estese dove dichiarati supportati. Confrontare utenti admin/non admin e server privi della capacità: stato corretto, nessun falso successo. |
| AT-05 | Progresso, conflitti e continuazione tra sessioni/dispositivi | EPUB/PDF/fumetti e liste: due client, aggiornamenti offline concorrenti, orologi diversi, perdita della risposta e riconnessione. Posizione coerente, conflitto risolvibile e nessuna mutazione ripetuta alla cieca. Per Kindle verificare edizione e limiti delle annotazioni. |
| AT-06 | File picker/provider esterni e Kindle reale | Importare da PC/telefono/provider un file supportato; verificare in un account di prova l'accettazione Amazon, conversione, comparsa in libreria e lettura dopo aggiornamento. Provare annullamento/esito incerto senza duplicati e cataloghi vecchi con dizionari. Le prove sintetiche già passate non chiudono questa voce. Per F-13 verificare anche eliminazione, metadati/copertina e risincronizzazione dello stato sul documento sostitutivo. |
| AT-07 | Prestazioni, memoria e blocco Kindle sul Windows segnalato | Misurare apertura iniziale e successiva, catalogo grande/copertine, libri lunghi, animazioni e navigazione durante il caricamento. Su Hyperion confrontare anche tap/swipe rapidi di Scorri, curl avanti/indietro e testo del fronte/sotto la piega agli estremi su densità frazionarie. Registrare tempi, memoria e comportamento con condizioni riproducibili; definire il criterio di accettazione prima della misura. Navigazione e annullamento devono restare utilizzabili durante il caricamento, senza stato «Non risponde» o crash. Confermare sul PC interessato che il blocco non si riproduca. |
| AT-08 | Accessibilità e integrazioni native | Schermi piccoli/grandi, chiaro/scuro, testo ingrandito, contrasto, focus/ordine tastiera, TalkBack/Narrator, fullscreen/cutout e privacy cattura. Validare anche share/export, icone, keep-awake e ritorno dal background. |

## Estensione richiesta — amministrazione Komga (build 36)

| ID | Funzione | Stato e criterio residuo |
|---|---|---|
| KGA-01 | Aggiungere EPUB/PDF/CBZ/CBR da PC/telefono | Implementato con servizio Python sulla VM, ricevute persistenti, verifica hash e rifiuto dei duplicati. Prova reale su Komga 1.30.1 temporaneo superata. Installare servizio e proxy sulla VM personale, quindi verificare un caricamento da Android e Windows. |
| KGA-02 | Modificare informazioni dei volumi/serie | Editor esistente accessibile dalla gestione amministrativa, con lock e controllo concorrenza. API native verificate. Confermare sul server personale. |
| KGA-03 | Modificare copertine | Caricamento nativo e invalidazione cache libro/serie. Verificato su catalogo temporaneo. Confermare aggiornamento visivo sui due dispositivi. |
| KGA-04 | Eliminare un volume | Conferma con titolo e avviso di eliminazione del file originale per tutti gli utenti; richiesta nativa asincrona verificata. Confermare soltanto con un volume di prova. |

La sostituzione del file di un volume esistente è esclusa su richiesta esplicita.
Queste estensioni non chiudono automaticamente le altre voci di parità.
[Procedura Debian e limiti](KOMGA_LIBRARY_MANAGEMENT.md).

## Funzionalità future ed esclusioni dichiarate

| ID | Voce | Effetto sulla chiusura |
|---|---|---|
| FUT-01 | Nuovi modelli AI, cataloghi/download/ruoli dei modelli, estensioni OCR/vision, traduzione e typesetting tradotto | Rinviati su richiesta. I controlli sperimentali e le impostazioni già presenti restano conservati e descritti correttamente. Le componenti già usate dall'app devono continuare a superare le regressioni. |
| PLAT-01 | Handoff, Spotlight, Live Activities e servizi Apple StoreKit/App Store/EULA Apple | Le API Apple non sono implementazioni Android/Windows. Documentare le differenze senza interruttori finti o vincoli commerciali Apple. Gli eventuali equivalenti nativi di ricerca/notifiche/widget restano nell'audit A-03: non sono esclusi automaticamente. |

Nessun'altra voce aperta viene rinviata implicitamente da questa tabella. In
particolare RAR/CBR, cartelle sorvegliate, finestre multiple e altri elementi di
A-03 richiedono ancora la delimitazione del requisito prima di essere inclusi
nella parità obbligatoria oppure classificati come estensioni.

## R — Passaggio dal porting concluso alla release stabile

Questi controlli riguardano i pacchetti finali. Le prove già superate dalla
candidata sono evidenza riutilizzabile solo quando la sorgente interessata non è
cambiata; le modifiche runtime richiedono nuove build e CI.

| ID | Controllo finale | Stato attuale / criterio di chiusura |
|---|---|---|
| R-01 | Chiudere A, F e AT, poi fissare la sorgente finale | Aperto. Elenco delle differenze risolto, nessuna esclusione implicita, difetti residui dichiarati. Aggiornare matrice e note con le prove effettive; la sola chiusura dei sette interventi non basta. |
| R-02 | Regressioni e backend sulla sorgente finale | Superato anche per la candidata 35 (`69a127d`, CI 43588228905); ripetere dopo nuove modifiche runtime e sulla sorgente scelta per la stabile. Tutti i job `android`, `windows`, `android_reader_display` devono riuscire; includere Komga reale, browser, worker e integrazioni native. Conservare fallimenti/ripetizioni e dichiarare skip/controlli non disponibili. |
| R-03 | Identità, versioni, aggiornamento e distribuzione | La candidata pubblica 1.0.0+35 ha APK universale firmato, Windows completo e feed verificati; include aggiornamento in-app con conferma Android e backup/ripristino Windows. AT-01 resta aperto. Per nuovi aggiornamenti distribuiti incrementare il build, mantenere package ID/certificato e verificare ABI, allineamento, provenienza e tutti i runtime/sorgenti/licenze Windows. La firma Authenticode Windows non è attualmente presente: il tipo di distribuzione, il percorso di installazione/aggiornamento e tale stato devono essere espliciti. |
| R-04 | Allegati e pubblicazione stabile | Consegna della candidata già verificata; la pubblicazione stabile resta aperta. Preparare/verificare i pacchetti della sorgente finale, riscaricarli e controllare checksum e contenuto. Seguire [RELEASING.md](RELEASING.md): il publisher preview non equivale alla promozione stabile di `v1.0.0`. |
| R-05 | Conservazione e documentazione | Conservare cronologia, build precedenti, firma Android e sorgenti del runtime Kindle; non rimuovere script attivi. Prima di eventuali eliminazioni di rami/release presentare un nuovo inventario preciso. Aggiornare README, note, [audit repository](REPOSITORY_AUDIT.md) e [validazione](VALIDATION.md) senza modificare allegati storici. |

### Ordine operativo consigliato

1. Chiudere A-01–A-03 per avere il perimetro verificabile delle funzioni applicabili.
2. Eseguire presto AT-01, AT-06 e AT-07 sulla candidata: aggiornamento/dati,
   invio reale a Kindle e blocco sul PC interessato sono le verifiche più urgenti.
3. Chiudere F-01–F-13, affrontando prima coerenza dei dati, offline e lettori,
   poi completamento dei flussi, presentazione e localizzazione. Associare a ogni
   correzione la regressione o il confronto di accettazione pertinente.
4. Completare AT-01–AT-08 sulla sorgente risultante, poi eseguire R-01–R-05
   sui pacchetti finali e procedere alla pubblicazione stabile.

Per un ambito non disponibile registrare il blocco e ciò che manca; non
trasformarlo in un pass.

## Registro delle chiusure

Per aggiornare uno stato usare questo formato e collegare il dettaglio in
[VALIDATION.md](VALIDATION.md). Non spuntare un'intera area per un singolo test.

| ID | Requisito/riferimento | Sorgente port | Piattaforma/backend | Verifica e risultato | Evidenza | Stato |
|---|---|---|---|---|---|---|
| F-08.a | Contratto degli eventi `SSEEvent.swift`: eliminazioni, aggiunte perse, riconnessione e scope utente | `2f3c6385bdd6e2c2a25e65b192af6a0e92a0dc69` | Host Linux/Windows, fixture SSE | Mappatura eventi e invalidazione; una risposta precedente alla cancellazione non ripristina il libro, una lista nuova sì; nessun refresh per altro utente o quando disabilitato. Test passati in CI. | [Regressioni](../test/parity_closure_test.dart), [CI](https://github.com/LeValue/KMReader-Porting/actions/runs/42413142048) | Sottorequisito chiuso; F-08 conserva l'accettazione finale con UI/backend. |
| F-09.a | Metadati completi dell'indice per statistiche offline e indicazione di parzialità | `2f3c6385bdd6e2c2a25e65b192af6a0e92a0dc69` | Host Linux/Windows, fixture SQLite | 207 libri nel filtro, oltre la prima pagina; account/librerie esclusi, generi/serie conservati, indice interrotto riconoscibile, nessuna rete. Test passati in CI. | [Regressioni](../test/parity_closure_test.dart), [validazione](VALIDATION.md) | Sottorequisito chiuso; F-09 conserva il confronto con backend estesi/AT-04. |
| Da compilare per ciascuna chiusura A/F/AT/R | Percorso o operazione upstream, oppure richiesta specifica | Commit esatto | Dispositivo/OS/runtime e server | Passi, atteso, osservato; pass/fail/skip | Test/log/screenshot o record di validazione | Aperto fino alla verifica |

Lavori implementati e prove della candidata rimangono descritti nelle
[note 1.0](releases/v1.0.0.md), nelle [guide di test](TESTING.md) e nella
[validazione](VALIDATION.md). Questo documento sostituisce il vecchio elenco
come piano di chiusura; i checkpoint storici restano consultabili nell'archivio.
