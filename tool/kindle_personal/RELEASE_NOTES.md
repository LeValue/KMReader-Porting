La 0.1.5 aggiunge test di decodifica progressiva KFX e della mappa delle posizioni
originali Kindle, senza modificare libri, note o avanzamento su Amazon.

Il menu **11** oppure `probe --output report.json` verifica sul PC già collegato
se la risorsa Amazon supporta letture parziali e se sono disponibili posizione e
annotazioni. Il report contiene soltanto tempi, contatori e codici, senza testo,
titoli, identificativi, URL o credenziali.

Il decoder sperimentale legge indice e frammenti su richiesta; i test confrontano
il testo e le posizioni con una decodifica completa, includendo Unicode, cache,
risorse cambiate e server senza Range. La prova misura l'estrazione del testo,
non certifica ancora la riproduzione dell'impaginazione originale.

Il download e la conversione automatica della 0.1.4 restano disponibili, insieme
a sessioni e documenti già salvati. Sorgenti corrispondenti e licenze GPLv3+/MIT
sono inclusi nella release del companion separato dall'app.
