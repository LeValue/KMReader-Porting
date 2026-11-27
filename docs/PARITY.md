# Matrice di parità

Il riferimento è [kmworks/kmreader](https://github.com/kmworks/kmreader/tree/e2b35f8796cc830fc6e7464e161b2172d8f916e9).
Le voci aperte riguardano le prossime versioni di KMReader per Android e Windows.

| ID | Area | Stato e lavoro rimanente |
|---|---|---|
| A-01 | Azioni upstream | Confronto completato. Le discrepanze funzionali sono nelle rispettive voci F. |
| A-02 | Server e chiavi API | Modifica, cambio di indirizzo, protezione dei profili, chiavi API e verifica dei ruoli. |
| A-03 | Integrazione di sistema | Azioni rapide, cartelle monitorate, prelettura, ricerca di sistema, notifiche e finestre di lettura. |
| F-01 | Catalogo | Ordinamenti per tipo di contenuto, filtri annidati, selezione di tutti i risultati e preferenze persistenti. |
| F-02 | Liste offline | Liste e On Deck dall'indice del profilo, con ordine e stato della preparazione. |
| F-03 | Copertine | Visualizzazione, cache e aggiornamento delle copertine delle liste intelligenti. |
| F-04 | Esportazione | Salvataggio PNG della pagina scelta, anche nelle doppie pagine di fumetti e PDF. |
| F-05 | PDF offline | Originali riutilizzabili dopo la riapertura e cache dei documenti protetta mentre vengono letti. |
| F-06 | EPUB | Impaginazione per sezione, tipografia CJK, selezione e conservazione del locatore dopo il reflow. |
| F-07 | Download e spazio | Stato della coda, spazio disponibile, distinzione tra copie offline e cache, pausa persistente. |
| F-08 | Aggiornamenti live | Riconciliazione di catalogo, liste, copertine e progresso alla riconnessione. |
| F-09 | Statistiche e cronologia | Filtri di cronologia, indice offline e supporto parziale alle estensioni delle statistiche. |
| F-10 | Interfaccia | Schede adattive, navigazione laterale, download per stato e pannelli di lettura coerenti. |
| F-11 | Preferenze | Valori iniziali, scale tipografiche condivise, preset EPUB e ripristino delle preferenze del volume. |
| F-12 | Lingue e accessibilità | Catalogo del port in dieci lingue, etichette per la lettura assistita, navigazione da tastiera e barra adattiva per testo grande. |
| F-13 | Kindle | Migrazione verificata di note ed evidenziazioni e invio come copia separata per i formati senza mappa Kindle. [Compatibilità](KINDLE_LIBRARY_MANAGEMENT.md) |
| FUT-01 | Modelli, OCR e traduzione | Roadmap successiva al port descritta in fondo. |

## A-01 · Percorsi del lettore e della libreria

| Percorso nel riferimento | Equivalente Android e Windows | Dettagli e lavoro rimanente |
|---|---|---|
| Dashboard → In lettura, Da leggere, Aggiunti e Aggiornati | Dashboard con ambito per libreria, sezioni configurabili e accesso al catalogo | Vedi F-02 e F-08 per ordine e aggiornamento delle liste offline. |
| Scheda Ricerca → Libri e Serie | Ricerca dalla barra principale. La query resta attiva quando si passa da libri a serie. I risultati aprono le schede esistenti e usano l'indice locale in modalità offline. | Vedi F-01 per preferenze, filtri e selezioni. |
| Librerie, Liste → raccolte, liste di lettura e liste intelligenti | Cataloghi e raccolte dedicate. Le liste intelligenti del server dipendono dall'estensione disponibile. | Vedi F-02 e F-03 per risultati offline e copertine. |
| Dettaglio → apertura, download e modifica dei metadati | Schede di libro e serie, download, menu di gestione Komga e avanzamento nelle liste. | Vedi F-10 per le schede su display compatti e larghi. |
| Lettori → cambio pagina, indice, ricerca e presentazione | DIVINA, EPUB e PDF. EPUB e PDF hanno ricerca e indice. Comandi, preferenze e formati disponibili dipendono dal lettore. | Vedi F-04–F-06 per esportazione, disponibilità offline e impaginazione. |
| Offline → coda, file originali e pulizia | Download per volume, serie e lista. Catalogo locale, ripresa dei trasferimenti e impostazioni della cache. | Vedi F-02, F-07 e F-08 per indice, spazio e riconnessione. |
| Impostazioni → statistiche e cronologia | Cronologia, calendario di lettura e statistiche lato server con dati locali dove disponibili. | Vedi F-09 per filtri e disponibilità delle estensioni. |
| Comandi del sistema → ricerca, download e attività | Azioni rapide Android, navigazione assistiva e scorciatoie Windows. | Vedi A-03 e F-12. |

## A-02 · Server e chiavi API

- **Modifica del profilo.** Da **Impostazioni → Server → Modifica server** si possono cambiare nome, protezione e credenziali Komga. Una sostituzione delle credenziali verifica l'identità dell'account prima del salvataggio. Il nome può cambiare anche offline. La chiave, quando presente, rimane nell'archivio sicuro del dispositivo.
- **Cambio di indirizzo.** In **Modifica server** si possono inserire il nuovo indirizzo e le relative credenziali. KMReader verifica l'identità dell'account al nuovo indirizzo e conserva il profilo locale, i download, le preferenze e le modifiche in attesa. Un server con un'altra identità si aggiunge da **Aggiungi server**.
- **Protezione.** I profili protetti inattivi si aprono dal selettore **Server protetti**, dopo il controllo del dispositivo. Il profilo attivo richiede lo sblocco al ritorno dall'esterno dell'app. Restano disponibili il blocco globale e le normali operazioni di un account già aperto.
- **Gestione delle chiavi.** Una chiave creata durante l'accesso ha l'identificatore restituito da Komga e verificato per lo stesso utente. L'elenco di Komga non consente di collegare con certezza una chiave inserita manualmente alla sua voce, quindi da quella sessione il port mostra l'elenco e disabilita la revoca. Un amministratore può usare l'interfaccia del server per la gestione manuale.
- **Capacità del server.** La validazione aggiorna i ruoli per l'account verificato. Le operazioni amministrative rimangono limitate dai permessi Komga. Liste intelligenti, statistiche estese e caricamenti conservano i rispettivi controlli di disponibilità.

## A-03 · Integrazioni di sistema

| Funzione | Android | Windows |
|---|---|---|
| Azioni rapide | Da Android 7.1, pressione prolungata sull'icona per **Cerca in libreria**, **Download** e **In lettura**. Le destinazioni usano il profilo attivo. | **Ctrl+F** per la ricerca e **Ctrl+J** per i download dalla finestra della libreria. |
| Prelettura | Profili di prelettura e cache delle pagine nel lettore. Il budget resta legato al contenuto e alla memoria. | Stessi profili e budget per sessione. |
| Cartelle locali | **Libri locali → Cartelle monitorate** conserva l'accesso al documento scelto dal selettore Android. La scansione avviene all'apertura, al ritorno in primo piano e su richiesta. | Le cartelle scelte vengono monitorate durante l'esecuzione. Al ritorno in primo piano si ripete la scansione. Entrambe le piattaforme conservano le copie importate e il relativo progresso. |
| Indicizzazione | L'opzione **Trova i download nella ricerca di sistema** rende disponibili i titoli dei download Komga tramite Android SearchManager sui dispositivi che mostrano questi suggerimenti. | La stessa opzione crea collegamenti ricercabili nel menu Start. Entrambe le piattaforme escludono i profili protetti e sospendono l'indice con il blocco app o la protezione della privacy. |
| Notifiche | Con il consenso dell'utente, il sistema segnala download Komga completati o da riprendere. | Notifiche equivalenti tramite Windows. Toccando una notifica si apre la coda del relativo profilo. Il testo della notifica è generico. |
| Finestre di lettura | **Apri in una nuova finestra** apre un'attività di lettura separata nel multitasking Android. | Lo stesso comando apre una finestra di lettura indipendente. Le sessioni condividono il progresso salvato e le copie locali. |

## Komga e catalogo

### F-01 · Catalogo

- **Preferenze.** Ordinamento, filtri e vista a elenco o griglia vengono salvati per profilo, tipo di contenuto e sezione. Gli ordinamenti offline possono essere diversi da quelli online.
- **Filtri.** L'editor usa gruppi annidati con corrispondenza a tutti o a uno dei criteri. Durante la ricerca dalla barra principale, il campo di ricerca resta la fonte della query anche quando si applica un filtro salvato.
- **Selezione.** **Seleziona tutti i risultati** acquisisce l'intera query prima di aggiornare la selezione. Un annullamento o un errore lascia valida la selezione precedente. Con l'ordinamento casuale, l'acquisizione usa un ordine stabile per attraversare tutte le pagine.

### F-03 e F-09 · Copertine, cronologia e statistiche

- Le liste intelligenti mostrano la copertina fornita dall'estensione Komga e possono riutilizzare la copia in cache. Gli eventi del server aggiornano la copertina visualizzata.
- La cronologia conserva i filtri per profilo. Le statistiche usano l'indice locale disponibile offline. Se il server pubblica solo una parte delle statistiche estese, KMReader mostra le sezioni disponibili e mantiene il riepilogo.

## Offline e sincronizzazione

- **F-02.** On Deck e le liste salvate interrogano l'indice del profilo. Le liste di lettura ordinate conservano la sequenza originale. Le liste intelligenti usano la definizione salvata se il client può valutarla. Per le regole specifiche del server resta disponibile la risposta già salvata per la stessa richiesta. L'app indica quando l'indice non è completo o aggiornato.
- **F-07.** **Download** mostra trasferimenti attivi, in coda e completati. La pausa resta impostata per profilo dopo la riapertura e lascia disponibili i dati parziali per la ripresa. **Cache** mostra i limiti delle cache, le copie offline e lo spazio libero riportato dal sistema.
- **F-08.** Dopo la riconnessione, KMReader rivalida le copertine visibili, invalida le viste del catalogo e riprende la sincronizzazione del progresso in attesa. Le modifiche al catalogo segnalano quando l'indice offline richiede un aggiornamento.

## EPUB, PDF e fumetti

- **F-04.** Dal menu delle immagini del lettore fumetti e dal lettore PDF si può salvare in PNG ciascuna pagina di una doppia pagina. Il salvataggio usa il selettore di sistema e libera i file temporanei alla chiusura del selettore.
- **F-05.** I PDF scaricati usano l'originale offline. I PDF cifrati richiedono la password per la sessione. La cache dei documenti preserva i file aperti anche quando la pulizia viene avviata da un'altra finestra. I derivati raster restano limitati in memoria.
- **F-06.** Negli EPUB misti, le sezioni a impaginazione fissa rispettano il riquadro e la tipografia dell'editore. Le sezioni reimpaginabili seguono le preferenze del lettore. Il reflow conserva il locatore e la selezione usa la lingua del testo per individuare i confini delle parole.

## Interfaccia e preferenze

- **F-10.** Le schede di serie, raccolte e liste affiancano i dettagli al catalogo sulle finestre larghe. Sui telefoni la scheda scorre insieme ai contenuti. La barra laterale usa la palette dell'app e include le liste fissate. I download sono divisi fra coda, interruzioni e copie disponibili. Le opzioni di PDF e fumetti si aprono a lato in una finestra Windows larga e in basso nelle viste compatte.
- **F-11.** Le nuove installazioni adottano i valori di riferimento per i controlli condivisi, mantenendo il lettore PDF in modalità fumetto come scelta iniziale del port. Il lettore EPUB e le impostazioni generali mostrano le stesse scale per carattere e margini. Il preset applicato nel lettore cambia la tipografia del volume. Il preset applicato dalle impostazioni modifica quella globale. Una modifica globale sostituisce i valori precedenti del volume solo per i campi modificati. **Usa le impostazioni globali** ripristina l'intero profilo di lettura del volume e conserva la posizione. Le preferenze esistenti vengono conservate durante l'aggiornamento.
- **F-12.** Le stringhe del port sono disponibili nelle dieci lingue dell'app. Il cinese semplificato e quello tradizionale seguono la variante scelta o quella del sistema. I lettori espongono etichette accessibili per pagina, posizione e azioni sul testo selezionato. Quando è attiva la navigazione assistita, i controlli rimangono visibili. Su Windows **Alt+1–5** apre le sezioni principali e i comandi focalizzati ricevono i tasti di attivazione. La barra compatta mantiene le destinazioni accessibili con testo grande.

## Kindle

- **F-13.** La sostituzione di un documento personale ripristina posizione, segnalibri, note ed evidenziazioni quando è possibile verificare il testo e gli intervalli. Amazon deve confermare lo stato della nuova edizione prima del ritiro dell'originale. **Invia come copia Kindle separata** è disponibile per mantenere due copie, anche per PDF ed edizioni senza una mappatura certificabile. [Compatibilità della libreria Kindle](KINDLE_LIBRARY_MANAGEMENT.md)

## Modelli, OCR e traduzione

- **FUT-01.** La libreria dei modelli potrà includere profili OCR per lingua e scrittura, gestione delle versioni e funzionamento offline. Un'estensione successiva potrà riusare i blocchi OCR come unità di traduzione, con scelta del fornitore e cache gestita per volume. Le funzioni attuali permettono di riconoscere o tradurre il testo dagli strumenti del lettore.
