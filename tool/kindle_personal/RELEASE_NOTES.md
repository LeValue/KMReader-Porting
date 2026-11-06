Il documento veniva scaricato correttamente ma restava in formato Amazon KFX:
la 0.1.3 non riconosceva la firma `CONT` e, senza Calibre, non produceva un EPUB.

La **0.1.4 converte automaticamente i KFX non cifrati in `ready.epub`**, offline,
senza installare Calibre o plugin. Controlla l'integrità delle risorse e la struttura
dell'EPUB prima di dichiararlo importabile; un errore non diventa un falso successo.

Chiudi il vecchio prototipo, estrai tutto lo ZIP Windows e avvia **Avvia-Kindle.cmd**.
Scegli **4 — Riprova preparazione**, seleziona il documento già scaricato e importa
il `ready.epub` indicato in **KMReader → Libri locali**. Non serve rifare login o
download. I nuovi download con **3** vengono preparati automaticamente.

Verifiche: conversione reale di KFX sintetici su Windows/Linux, importazione EPUB
nel motore KMReader e riapertura offline, eseguibile Windows con conversione KFX,
DPAPI, Chrome ed Edge. I test pubblici non contengono documenti personali.

Il prototipo è un programma separato dall'app Flutter MIT. Include kfxlib di John
Howell (GPL-3.0-or-later); il pacchetto combinato è distribuito sotto GPLv3 o successiva
con avvisi MIT e dipendenze. I sorgenti corrispondenti, incluso kfxlib della revisione
fissata e le istruzioni di compilazione, sono nello ZIP `source` allegato.
