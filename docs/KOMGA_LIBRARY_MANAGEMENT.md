# Gestione remota Komga da KMReader

Ambito richiesto: **aggiungere nuovi contenuti, modificare informazioni e
copertine, eliminare volumi**. La sostituzione di un file esistente è esclusa.
Le funzioni richiedono un account amministratore Komga e una connessione attiva.
I metadati utilizzano l'editor già presente, compresi i blocchi dei campi e il
controllo di modifiche concorrenti. Le modifiche riguardano il catalogo Komga;
non riscrivono il contenuto dei file EPUB/PDF/archivio originali.

## Nell'app

- **Impostazioni → Server → Aggiungi a Komga**: scegli libreria, cartella della
  serie e file EPUB/PDF/CBZ/CBR. La cartella può essere nuova o già esistente,
  anche annidata (per esempio `Marvel/X-Men`), sempre relativa alla libreria.
  Il nome del file deve essere nuovo: un duplicato viene rifiutato.
- Nella scheda di un volume o serie, **Gestisci su Komga** permette di modificare
  le informazioni e scegliere una copertina JPG/PNG/WebP (massimo 20 MB).
- Per un volume, **Elimina da Komga** chiede conferma e richiede al server di
  eliminare il file originale, per tutti gli utenti. L'operazione non è una
  rimozione dalla sola cache locale. Il task Komga è asincrono.
- Dopo un'interruzione usa **Verifica esito caricamento**. L'identificatore
  dell'operazione rimane salvato per quell'account anche dopo la riapertura.
  Per riprovare seleziona lo stesso file. Non viene ripetuto automaticamente
  un caricamento dal risultato incerto.
- “File caricato” indica che i byte sono stati verificati e pubblicati sul
  filesystem. La scansione/analisi Komga deve ancora terminare prima che il
  contenuto compaia nel catalogo. Se la richiesta di scansione fallisce,
  **Scansiona libreria** la ripete senza reinviare il file.

## Perché serve un componente sulla VM

Le API verificate di Komga **1.29.1 e 1.30.1** consentono di modificare metadati,
caricare copertine e cancellare file. L'importazione dei libri di Komga usa
invece file già presenti sul server. `tool/komga_admin/server.py` riceve nuovi
file sulla VM Debian e richiede la scansione nativa. Non modifica Komga, non
memorizza password/API key e non offre operazioni di sostituzione o shell remota.

Il servizio verifica ogni richiesta con l'account Komga e controlla anche un
endpoint riservato agli amministratori, così da verificare i privilegi effettivi
del token. Le destinazioni sono una lista configurata di librerie; il percorso
ricevuto da Komga deve corrispondere alla configurazione. I file sono trasferiti
in streaming, controllati con SHA256 e pubblicati atomicamente senza sovrascrivere
un nome esistente. Cartelle/nomi con attraversamento di percorso e symlink nelle
cartelle di destinazione vengono rifiutati. Il controllo del formato è iniziale;
l'analisi completa resta responsabilità di Komga.

## Installazione una tantum su Debian

Questi passi si eseguono **nella VM**, non nell'host Proxmox. Richiedono Python
3.11 o successivo. Non è necessario cambiare database o versione di Komga.
Nessuna installazione è stata eseguita automaticamente sul server personale.

1. Copia `tool/komga_admin/server.py` in `/opt/kmreader-admin/server.py`.
   I file della candidata sono anche disponibili dal tag versionato
   `v1.0.0-candidate.6` del repository (dopo la sua pubblicazione), senza dipendenze pip:

   ```sh
   sudo install -d -m 0755 /opt/kmreader-admin /etc/kmreader-admin
   curl --fail --location https://raw.githubusercontent.com/LeValue/KMReader-Porting/v1.0.0-candidate.6/tool/komga_admin/server.py -o /tmp/kmreader-admin-server.py
   sudo install -m 0644 /tmp/kmreader-admin-server.py /opt/kmreader-admin/server.py
   ```

   Dallo stesso tag scarica `config.example.json` e i file nella sottocartella
   `debian/`. Non avviare il servizio con la configurazione di esempio invariata.
2. Crea l'utente di servizio `kmreader-admin` e usa il gruppo che può leggere
   i contenuti Komga (negli esempi `komga`). Il file unit fornito usa questi nomi;
   adattali se la tua installazione ha utenti/gruppi diversi.
3. Copia `config.example.json` in `/etc/kmreader-admin/config.json` e modifica:
   - `komga_url`: indirizzo interno di Komga, per esempio
     `http://127.0.0.1:25600`; conserva l'eventuale prefisso `/komga`;
   - `libraries`: ID delle librerie (visibili nell'API amministrativa
     `/api/v1/libraries`) e cartelle reali nella VM;
   - `komga_root`: percorso esposto da Komga. Se Komga gira in un container può
     essere diverso da `path`, che è il corrispondente percorso nella VM;
   - `max_upload_bytes`: limite per singolo file, predefinito 2 GiB.
4. Concedi all'utente di servizio accesso in scrittura **solo** alle cartelle
   abilitate. I file nuovi hanno permessi `0640`, le cartelle nuove `2770`:
   il gruppo configurato deve consentire a Komga di leggerli. Se servono ACL,
   applicale alle cartelle delle librerie, senza rendere scrivibile il sistema.
5. Copia `debian/kmreader-admin.service` in `/etc/systemd/system/` e adatta
   `User`, `Group`, `RequiresMountsFor` e `ReadWritePaths` alle stesse cartelle del JSON.
   Mantieni il file del servizio e la configurazione modificabili solo da root.
6. Avvia il servizio:

   ```sh
   sudo systemctl daemon-reload
   sudo systemctl enable --now kmreader-admin
   sudo systemctl status kmreader-admin
   ```

   Per una prova manuale con lo stesso utente e gli stessi permessi:

   ```sh
   sudo -u kmreader-admin -g komga python3 /opt/kmreader-admin/server.py --config /etc/kmreader-admin/config.json
   ```

7. Nel reverse proxy che espone Komga, aggiungi la location fornita in
   `tool/komga_admin/debian/nginx-location.conf`. Il servizio ascolta soltanto su
   `127.0.0.1:8788`. Il percorso esterno deve essere **sotto lo stesso indirizzo
   Komga configurato nell'app**, per esempio `/kmreader-admin/` oppure
   `/komga/kmreader-admin/` se esiste un prefisso. Il proxy deve conservare gli
   header `Authorization` e `X-API-Key` e il limite di dimensione deve essere
   coerente col JSON. Per le copertine, il proxy del normale endpoint Komga deve
   permettere una richiesta multipart (per esempio 25 MiB); il server Komga
   può imporre un limite inferiore ai 20 MiB consentiti dall’app. Usa HTTPS per l'accesso remoto fuori dalla rete fidata.

Se oggi accedi direttamente alla porta Komga senza reverse proxy, puoi creare
un frontend Nginx su un'altra porta, con `location /` verso Komga e la location
aggiuntiva verso il servizio. Configura nell'app l'indirizzo di quel frontend.
Se usi già Nginx/Caddy con un dominio, aggiungi il percorso sul frontend esistente
senza cambiare l'indirizzo nell'app. La configurazione del proxy dipende dalla
rete effettiva della VM; non esporre direttamente la porta interna 8788.

## Verifiche e limiti

I test automatici usano librerie temporanee e utenti sintetici: permessi,
proprietà delle ricevute, hash, symlink, duplicati, ripresa dopo pubblicazione,
richiesta di scansione e trasferimento HTTP. Non cancellano libri personali.

La VM personale deve ancora ricevere il servizio/configurazione. Dopo il setup
verificare con un file di prova: comparsa nel catalogo, modifica informazioni,
nuova copertina, eliminazione confermata. Conservare librerie e credenziali
esistenti; non pubblicare API key, password o percorsi privati nei log del progetto.
