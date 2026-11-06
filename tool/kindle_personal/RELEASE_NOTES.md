Correzione del prototipo personale Amazon.it per i documenti PDOC e l'elenco
della libreria.

- Riconosce annotazioni e metadati XML/JSON validi, che la 0.1.0 rifiutava
  indiscriminatamente come pagine di servizio.
- La mancata consegna di annotazioni esplicitamente facoltative non blocca
  il documento. Le risorse necessarie e quelle obbligatorie devono riuscire.
- Nasconde i dizionari Amazon usando i tag del catalogo; il menu 9 li mostra
  nuovamente. I numeri di selezione corrispondono sempre all'elenco mostrato.
- Rinnova i vecchi metadati e aggiunge alla diagnostica tipo/numero della risorsa
  e stato HTTP, senza corpi di risposta, identificativi o credenziali.

Estrai tutto lo ZIP, avvia **Avvia-Kindle.cmd**, scegli **2 — Sincronizza** e
riprova il documento con **3 — Scarica un titolo**. La sessione esistente viene
conservata: **non serve rifare il login**. Le istruzioni sono in **LEGGIMI.md**.

Verifica automatica su Windows/Linux, pacchetto Windows con Edge/DPAPI e
importazione dei file sintetici nel motore KMReader. La causa specifica della
seconda risorsa del documento dell'utente non era presente nel report 0.1.0:
il nuovo test riproduce il controllo errato e la nuova diagnostica permette di
distinguere ulteriori risposte del servizio durante la prova reale.

Il programma rimane separato dall'app; un download completo può ancora
richiedere la conversione del formato prima della lettura in KMReader.
