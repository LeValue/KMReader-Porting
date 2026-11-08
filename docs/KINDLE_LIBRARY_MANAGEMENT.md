# Gestione remota dei documenti personali Kindle

Sorgente **1.0.0+33**, candidata di sviluppo. La gestione riguarda i documenti
personali **PDOC**; gli acquisti Amazon (`EBOK`) non possono raggiungere le
mutazioni. La voce **F-13** della [matrice](PARITY.md) resta aperta per la copertura
residua e l'accettazione finale sulle app installate. Build e release precedenti,
cronologia, componenti Kindle attivi e firma Android restano conservati.

## Aggiunta e destinazione

**Invia a Kindle** distingue due operazioni, verificate sull'account reale:

- **Aggiungi alla libreria Kindle**, predefinita: archiviazione cloud, nessun
  dispositivo obbligatorio; accesso dai dispositivi compatibili dell'account.
- Interruttore disattivato: **Invia solo ai dispositivi selezionati**, con almeno
  una destinazione. Il documento non entra nel cloud e non viene sincronizzato
  o condiviso da Amazon. L'utente ha confermato ricezione e apertura sul Kindle
  Android scelto nella prova.

Le selezioni precedenti non vengono inoltrate in modalità libreria. Un errore
nel recupero dei dispositivi non impedisce l'aggiunta al cloud. Sessione di lettura
e credenziali di invio persistenti vengono riutilizzate senza un nuovo accesso
per ogni operazione. [Protocollo e prove di invio](KINDLE_IMPORT.md).

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

## Registro e recupero

Il registro `kindle:management` è separato per account. I backup sono nella
cartella privata `<account>/kindle-management/`, scritti con temporaneo e rinomina;
per una sostituzione viene conservata anche la copia del sorgente con SHA256.
Non vengono puliti automaticamente. Backup, identificativi personali, cookie,
chiavi e contenuto dei libri non fanno parte dei log o degli artefatti CI.
Le prove personali mantengono il registro sul PC, protetto con DPAPI.

| Stato | Significato e recupero |
|---|---|
| `backed_up` | Backup completato, mutazione non iniziata; annullabile. |
| `delete_submitting`, `delete_uncertain`, `delete_verifying` | Verifica senza scritture; nuovo tentativo solo con l'azione esplicita e i controlli di proprietà/revisione. |
| `replacement_submitting`, `replacement_uncertain` | Consegna da controllare; nessun nuovo invio automatico. |
| `replacement_migration_required` | Copia accettata; ripristino da completare. |
| `migration_submitting`, `migration_uncertain` | Scrittura dello stato da verificare, senza replay. |
| `progress_restored` | Stato cloud verificato e progresso locale ripristinato; originale ancora presente. |
| `replacement_retiring`, `replacement_retirement_uncertain`, `replacement_retirement_verifying` | Ritiro avviato: verifica senza replay; eventuale tentativo esplicito riusa copia e ripristino verificato. |
| `done` | Cancellazione confermata; per una sostituzione, anche ripristino verificato. |
| `rejected` | Mutazione non iniziata o richiesta rifiutata da Amazon; originale conservato. |
| `superseded` | Tentativo di cancellazione conservato nello storico e sostituito da un nuovo tentativo esplicito. |

Download/outbox pendenti bloccano la gestione dello stesso documento. Un'operazione
aperta impedisce mutazioni concorrenti, anche dopo il riavvio. La chiusura di un
account impedisce di pubblicare risultati tardivi nella sua cache.

## Requisiti e prove

| ID | Requisito | Situazione nella sorgente 33 |
|---|---|---|
| K-01 | Invio locale con sessione persistente e modalità distinte | Libreria e solo dispositivo verificati; ricezione/apertura Android confermata dall'utente. Resta accettazione UI installata su entrambe le piattaforme. |
| K-02 | Eliminazione cloud PDOC | Cancellazione reale del solo PDOC sintetico confermata da Amazon e dall'assenza nel catalogo; recupero del tentativo precedente senza nuovo upload. Resta accettazione UI installata. |
| K-03 | Metadati e copertina | Recupero dall'app e modifica EPUB su copia implementati; titolo e copertina convertiti verificati sull'account reale. Nessun aggiornamento in-place presunto; resta accettazione UI. |
| K-04 | Ripristino progresso e segnalibri | Punto di lettura e segnalibri riletti dal cloud sulla nuova edizione; completamento e data conservati nella prova reale. Test conferma, risposta persa, conflitti, rollback e ripresa offline passati. Restano PDF/note/evidenziazioni e accettazione sui dispositivi. |
| K-05 | Registro durevole e recupero | Piano salvato prima delle mutazioni; invii incerti non ripetuti, originale ritirabile solo dopo verifica. Prova personale conserva backup/registro sul PC tra processi. |
| K-06 | Accettazione Android/Windows/altro Kindle | Servizi provati dal desktop e consegna Kindle Android confermata; restano UI aggiornata e ripresa su un secondo dispositivo dopo sostituzione. |

Prove locali: [modifica/eliminazione](../test/kindle_management_test.dart),
[rimappatura](../test/kindle_edition_migration_test.dart),
[ripristino e ritiro](../test/kindle_replacement_test.dart).
[Prova reale conclusa 42514185821](https://github.com/LeValue/KMReader-Porting/actions/runs/42514185821)
sulla sorgente `e9a7712da95c227a86e5d613409e2c3dda2a7949`: nuova edizione con titolo/copertina
verificati, punto di lettura e segnalibri confermati dal cloud, completamento/data
conservati, cancellazione dell'originale riconosciuta da Amazon e assenza verificata.
Il caricamento iniziale è stato effettuato una sola volta nella
[prova 42506920429](https://github.com/LeValue/KMReader-Porting/actions/runs/42506920429);
[42509219752](https://github.com/LeValue/KMReader-Porting/actions/runs/42509219752)
ha ripristinato lo stato sulla nuova copia ma si era fermata al ritiro per il difetto
dei cookie. Il recupero finale ha eseguito **0 upload, 0 scritture di annotazioni e
1 cancellazione**, dopo aver ricontrollato proprietà e stato. I tentativi falliti
restano nella cronologia e non sono contati come prove riuscite.

[Riapertura in un nuovo processo 42514327712](https://github.com/LeValue/KMReader-Porting/actions/runs/42514327712)
passata con **0 upload, 0 cancellazioni e 0 scritture di annotazioni**: vecchia
copia assente, copia aggiornata presente, progresso/segnalibri cloud ancora
confermati e registro `done`.

Tutte queste prove riguardano lo stesso documento sintetico generato dalla prova
di aggiunta al cloud. Il guard HTTP impedisce modifiche ai libri preesistenti
dell'utente. [Altre evidenze](KINDLE_IMPORT.md).

## Fonti del protocollo

Il JavaScript MyCD attuale di Amazon contiene `ajax_fmyx`, `DeleteContent`,
`KindlePDoc`, form e header `MYX`:
[risorsa pubblica verificata](https://m.media-amazon.com/images/I/91XIVcpdV8L._RC%7C81vusVJblyL.js,01K8GZbiiAL.js_.js).
Il [riferimento storico](https://github.com/fatso83/amazon_fiona_js/blob/4092714156b31a3fecfa46c2ac552df613e395c7/TODO.md)
resta utile per il contesto, ma il suo vecchio endpoint non viene considerato attuale.
Lo scambio cookie segue il [client Audible](https://github.com/mkb79/Audible/blob/master/src/audible/auth.py),
adattato al dominio Kindle Amazon.it. La scrittura XML delle annotazioni è stata
verificata su un PDOC sintetico con GUID reale: l'alias `_LATEST_` non viene usato.
