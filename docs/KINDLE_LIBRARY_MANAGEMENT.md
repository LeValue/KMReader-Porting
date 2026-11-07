# Gestione remota dei documenti personali Kindle

Stato della sorgente **1.0.0+31**: prima implementazione parziale, non ancora
verificata su un account Amazon reale. I pacchetti già distribuiti della build 30
non contengono queste modifiche. La voce **F-13** della [matrice](PARITY.md) resta
aperta, soprattutto per la sostituzione con migrazione dello stato.

L'ambito concordato è **PDOC**, i documenti personali caricati dall'utente.
I libri acquistati da Amazon (`EBOK`) sono esclusi sia nell'interfaccia sia nel
servizio che esegue le operazioni. Nessuna release, ramo o chiave Android viene
rimossa per introdurre questo servizio.

## Operazioni presenti

Dal dettaglio di un documento personale, **Gestisci documento Kindle** offre:

- **Modifica metadati e copertina:** scelta del file originale dal dispositivo,
  titolo/autore e, per EPUB, lingua, descrizione e immagine JPG/PNG fino a 20 MB.
  Le immagini vengono ridotte proporzionalmente a un lato massimo di 2048 pixel;
  una copertina esistente deve essere JPEG/PNG. Formati diversi vengono rifiutati
  prima di creare/inviare la nuova versione, conservando il file originale.
  L'EPUB viene ricostruito in un isolate, preservando identità, spine e risorse
  testuali; l'originale non viene sovrascritto. La copia viene inviata ad Amazon,
  quindi la modifica non è un semplice override della cache di KMReader.
- **Elimina dalla libreria Kindle:** conferma esplicita della cancellazione
  permanente del solo PDOC selezionato. Prima della richiesta vengono salvati i
  dati di lettura. Il risultato resta in verifica finché un catalogo completo
  letto da Amazon non conferma l'assenza del documento. HTTP 200 non basta.
  I file già scaricati e il progresso locale restano conservati.
- **Gestione contenuti Amazon:** accesso al sito ufficiale per controllare la
  libreria quando l'interfaccia di servizio non è disponibile o cambia.

L'autorizzazione web per la cancellazione usa cookie generati dal refresh token
**dell'account collegato**, con dominio Amazon.it e CSRF. Non legge il profilo del
browser e non chiede cookie da incollare. Una risposta persa non ripete la
cancellazione: **Verifica eliminazione** esegue soltanto letture. I libri acquistati
non possono raggiungere la richiesta di cancellazione.

## Sostituzione: limite ancora aperto

**Non è ancora implementata la sovrascrittura completa con risincronizzazione di
posizione e segnalibri richiesta dall'utente.** L'interfaccia lo indica prima
dell'invio: per ora si può inviare una copia aggiornata, conservando l'originale.

Prima dell'invio vengono registrati account/documento/revisione, stato cloud
riconosciuto dal parser (posizione, segnalibri, evidenziazioni e note), progresso
locale, locatore EPUB e segnalibri locali. La risposta Amazon viene associata
all'ID della nuova copia e al digest del file inviato. L'operazione rimane
`replacement_migration_required`; questo stato **non** significa migrazione
riuscita e blocca la cancellazione dell'originale tramite lo stesso servizio.

`KindleClient.pushPosition` scrive e rilegge una posizione della stessa edizione;
non fornisce ancora scrittura verificata dei segnalibri su una nuova edizione.
Copiare alla cieca CFI, GUID o numeri di posizione non sarebbe un ripristino.
L'assenza di credenziali/account di prova in questo ambiente impedisce di
verificare nuove scritture cloud. Non sono state eseguite mutazioni su documenti
reali durante lo sviluppo.

Per completare la sostituzione occorre ancora:

1. Verificare le API effettive di aggiornamento e scrittura delle annotazioni.
2. Attendere conversione e identificare la nuova copia tramite l'identità restituita.
3. Confrontare i contenuti e rimappare posizione/segnalibri su ancore non ambigue.
4. Scrivere e rileggere lo stato nel cloud; verificarlo su un altro Kindle/app.
5. Riconciliare eventuali modifiche concorrenti all'originale, migrare i riferimenti
   locali e soltanto allora ritirare il vecchio PDOC se ha un ID diverso.

## Registro e recupero

Il registro `kindle:management` è separato per account. Prima di una mutazione il
backup viene scritto con file temporaneo e rinomina nella cartella privata
`<account>/kindle-management/`; il piccolo registro SQLite conserva il riferimento.
Le operazioni sono salvate **prima** della richiesta remota. Backup e note non
finiscono nei log, nelle fixture o negli artefatti CI. Non è prevista una pulizia
automatica dei backup in questa revisione.

| Stato | Significato e recupero |
|---|---|
| `backed_up` | Backup completato, richiesta di mutazione non iniziata; annullabile dall'interfaccia. |
| `delete_submitting`, `delete_uncertain`, `delete_verifying` | Verificare il catalogo senza ripetere la cancellazione. |
| `done` | L'assenza del PDOC è stata confermata da un catalogo completo. |
| `replacement_submitting`, `replacement_uncertain` | Controllare la libreria Amazon; nessun reinvio automatico. |
| `replacement_migration_required` | Nuova copia accettata; originale e stato precedente conservati, migrazione incompleta. |
| `rejected` | Operazione fermata prima dell'invio della mutazione o errore di invio definitivo. Un nuovo tentativo deve essere esplicito. |

Un download o un'outbox di lettura pendenti bloccano l'avvio della gestione dello
stesso documento. Un'operazione aperta impedisce mutazioni concorrenti sullo
stesso PDOC, anche dopo il riavvio. Una disconnessione non può completare una
scrittura tardiva nella cache di un account chiuso.

## Requisiti e prove residue

| ID | Requisito | Situazione nella build 31 |
|---|---|---|
| K-01 | Risolvere il blocco di Invio a Kindle | Token di invio già validi indipendenti dal rinnovo del lettore; nuovo OAuth STK con PKCE e verifica dello stesso account; diagnostica per fase/HTTP. Prove sintetiche presenti, verifica dell'errore Windows reale ancora aperta. |
| K-02 | Eliminazione cloud PDOC | Servizio, conferma, backup, journal e rilettura implementati. Protocollo web non stabile e non verificato su Amazon reale. |
| K-03 | Metadati e copertina | Modifica EPUB su copia e invio implementati; aggiornamento in-place non dimostrato. Confermare metadati/copertina dopo conversione Amazon. |
| K-04 | Migrazione stato e segnalibri | Backup implementato; rimappatura, scrittura cloud delle annotazioni e migrazione completa ancora mancanti. |
| K-05 | Registro durevole e recupero | Implementato per invii/cancellazioni incerti; nessun ritiro automatico dell'originale durante una migrazione incompleta. |
| K-06 | Accettazione Android/Windows/altro Kindle | Da eseguire su account dedicato e dispositivi reali. |

[Test](../test/kindle_management_test.dart): EPUB immutato, risorse testuali e
copertina reale, input non validi, blocco EBOK, backup, copia aggiornata senza
ritiro dell'originale, cancellazione non confermata e risposta persa senza replay.
Queste fixture verificano il codice client, non la disponibilità attuale delle
API Amazon né l'avvenuta sincronizzazione con altri dispositivi.

## Fonti del protocollo

Amazon descrive la [rimozione dei documenti personali](https://digprjsurvey.amazon.co.uk/csad/help/node/TEYEjk3h6UBK0eAr0c)
e la [cancellazione permanente](https://www.amazonforum.com/s/question/0D54P00007LcdkYSAR/how-do-i-remove-old-books-from-library),
ma non pubblica un contratto REST stabile per queste mutazioni.

La richiesta `DeleteContent`/`KindlePDoc` e il percorso consumer web sono descritti
nel [riferimento primario amazon_fiona_js](https://github.com/fatso83/amazon_fiona_js/blob/4092714156b31a3fecfa46c2ac552df613e395c7/TODO.md).
È un protocollo storico: non si presume che Amazon lo mantenga disponibile.
Lo scambio refresh-token/cookie segue il [client Audible](https://github.com/mkb79/Audible/blob/master/src/audible/auth.py),
adattato all'account e al dominio Kindle Amazon.it. Le credenziali ADP di lettura
non vengono inviate alle pagine web. Per l'invio, vedere [KINDLE_IMPORT.md](KINDLE_IMPORT.md).
