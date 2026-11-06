La 0.2.3 aggiunge il bridge nativo per KMReader e la conversione con mappa
delle posizioni originali, senza modificare testo o struttura del documento.
La preparazione avviene in un processo separato dal lettore.

La 0.1.6 aggiunge test di decodifica progressiva KFX e della mappa delle posizioni
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

Il confronto online non usa il profiler delle allocazioni, che rallenta la
decodifica. Misura memoria RSS del processo, intervalli da 64/256 KiB e il
percorso download completo + EPUB. Il report distingue l'estrazione del testo
dalla disponibilità di una pagina impaginata e non promette tempi di streaming
sulla base della sola riduzione dei byte.

La verifica delle posizioni richiede esplicitamente il GUID del contenitore
scaricato: il servizio può restituire un’altra rappresentazione senza questo
parametro. I probe sono di sola lettura e pubblicano solo contatori e booleani.
