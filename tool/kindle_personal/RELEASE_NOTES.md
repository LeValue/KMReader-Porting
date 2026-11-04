Prototipo Windows x64 per il connettore personale Kindle di KMReader, configurato
per Amazon.it: login nel browser, catalogo EBOK/PDOC, download completo delle
risorse e preparazione offline di EPUB/PDF, anche tramite Calibre installato localmente.

Estrai lo ZIP e apri **Avvia-Kindle.cmd**. Le istruzioni sono in **LEGGIMI.md**.
Non serve installare Python o avviare un runner GitHub.

Credenziali conservate con Windows DPAPI. Nessuna modifica agli altri dispositivi
Amazon, agli acquisti o al lettore KMReader attuale. Il catalogo del prototipo è
testuale; l'integrazione nell'interfaccia dell'app e lo streaming vengono dopo
la verifica reale dei protocolli e dei file.

I test automatici usano dati sintetici, includono firme, callback browser,
acquisizione delle risorse, integrità, preparazione offline e DPAPI su Windows.
Non costituiscono una verifica del login del tuo account né della compatibilità
di tutti gli acquisti protetti. Il programma distingue download completato da
file importabile; la prova finale è l'apertura del risultato in KMReader.
