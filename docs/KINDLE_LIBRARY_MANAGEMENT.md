# Gestire i documenti Kindle

KMReader può gestire i documenti personali del proprio account Amazon.it.
Per inviarne uno, usa [Invia a Kindle](KINDLE_IMPORT.md).
Gli acquisti Amazon sono disponibili per la lettura secondo il supporto del servizio.

## Modifica ed eliminazione

Dal dettaglio del documento, **Gestisci documento Kindle** offre:

- **Modifica metadati e copertina:** recupera il documento tramite la coda normale
  dell'app o riutilizza il file già scaricato. È possibile scegliere un altro
  file dal dispositivo. Per EPUB: titolo, autore, lingua, descrizione e copertina
  JPG/PNG fino a 20 MB; ridimensionamento proporzionale a un massimo di 2048 pixel.
  Le copertine esistenti non supportate vengono rifiutate prima dell'invio.
- **Salva:** invia la copia aggiornata al cloud, ne verifica l'identità e tenta
  il ripristino dello stato descritto sotto. Il documento precedente viene
  ritirato soltanto dopo il ripristino verificato. Un'accettazione Amazon non
  basta a dichiarare concluso l'aggiornamento.
- **Elimina dalla libreria Kindle:** conferma esplicita della cancellazione
  permanente del PDOC selezionato. Prima della richiesta viene salvato lo stato
  di lettura. Un sidecar non disponibile (404) viene registrato come tale, non
  come stato vuoto; non impedisce una cancellazione esplicita, ma impedisce una
  sostituzione con ripristino. Il catalogo completo deve confermare l'assenza;
  HTTP 200 non basta. File locali, progresso e dati di recupero restano conservati.
- **Gestione contenuti Amazon:** apre il sito ufficiale per controllare la
  libreria e gestire i casi non ancora supportati dall'app.

La modifica dell'EPUB avviene su una copia, in un isolate. Il sorgente, l'identità
interna, la spine e le risorse testuali sono conservati. La richiesta inviata ad
Amazon modifica un documento cloud; non è un semplice override della cache.
Il contratto corrente di cancellazione è `POST /hz/mycd/ajax`, form con `data`
JSON, CSRF della pagina MyCD e header `client: MYX`. I cookie vengono generati dal
refresh token dell'account collegato e conservati per dominio, percorso e nome.
La scadenza di un cookie del solo host non cancella quello di autenticazione del
dominio padre. Gli errori applicativi Amazon, anche con HTTP 200, fermano
l'operazione e conservano l'originale. Le chiavi ADP non vengono inviate alle pagine web.
Il precedente endpoint consumer non viene usato come fallback.

## Ripristino del progresso prima della sostituzione

Il ripristino comprende il **punto effettivo nel testo**, i segnalibri cloud e
locali, il progresso locale, lo stato **in corso/completato**, la data di lettura
e le preferenze del lettore. Non viene copiato alla cieca il numero di pagina,
la percentuale, un CFI o un GUID della vecchia edizione.

1. Prima dell'invio, salvare sorgente con digest, account/documento/revisione,
   posizione cloud, segnalibri, evidenziazioni/note riconosciute, progresso e
   locatori/preferenze locali. Una risposta incompleta non equivale a zero note.
2. Associare la copia all'ID restituito da Amazon; attendere catalogo e conversione.
3. Confrontare le mappe delle due edizioni e rimappare le posizioni su testo
   Unicode **identico e non ambiguo**. I CFI locali devono risolversi contro il
   DOM originario; quelli non verificabili fermano la migrazione.
4. Registrare l'intento prima della scrittura. Inviare posizione e segnalibri
   sulla nuova edizione, poi rileggerli dal cloud con il suo GUID verificato.
5. Pubblicare progresso, completamento, data di lettura, segnalibri e locatore
   locale in una transazione SQLite. Anche l'overlay in memoria viene invalidato
   in caso di rollback. Il locatore migrato consente la ripresa offline.
6. Ricontrollare lo stato dell'originale e della nuova copia. Solo dopo queste
   verifiche, rimuovere il vecchio PDOC e confermarne l'assenza dal catalogo.

Modifiche concorrenti allo stato di lettura fermano l'operazione. Dopo una risposta
persa, **Ripristina il progresso di lettura** esegue soltanto la verifica del piano
registrato: non reinvia il file né ripete la scrittura dei segnalibri. **Completa
l'aggiornamento del documento** ritenta il ritiro solo quando lo stato ripristinato
è verificato e non è già partita una cancellazione. Quando la cancellazione è
incerta, **Verifica eliminazione** legge il catalogo senza ripetere la mutazione.
**Riprova eliminazione** è un'azione esplicita separata: controlla la proprietà
cloud del documento esatto, la revisione e il titolo; per una sostituzione
ricontrolla anche il ripristino prima di richiedere il ritiro. Riutilizza la
stessa copia e lo stesso piano, senza reinviare il file o i segnalibri.

Il catalogo di consegna di un dispositivo può trattenere i metadati dopo la
cancellazione cloud. In quel caso la conferma viene dal catalogo completo MyCD
dell'account. Un marcatore persistente impedisce che quei metadati facciano
riapparire il documento, anche offline dopo il riavvio; non cancella file o
progresso e può essere rimosso da una successiva aggiunta confermata.

### Copertura residua

La rimappatura è implementata per EPUB preparati con una mappa Kindle valida.
La presenza di **note o evidenziazioni**, un PDF o un'edizione senza mappa, testo
modificato/ambiguo e CFI non supportati impediscono il ritiro dell'originale.
Questi casi restano da completare: non vengono considerati riusciti e non sono
spostati automaticamente tra le funzionalità future della 1.0.

## Recupero

Se una sostituzione è interrotta, riapri la gestione del documento per riprendere
dallo stato salvato. In caso di esito incerto, verifica nel catalogo prima di
ripetere un invio o un’eliminazione.
