Correzione del login sul portatile dopo OTP e `register / HTTP 400`.

- Intercetta il ritorno Amazon in base a dominio e percorso, anche quando i
  parametri OpenID o il codice contengono `/`. Il risultato monouso non viene
  inviato alla pagina Amazon prima di essere consegnato al connettore.
- Gestisce nello stesso modo i risultati nel frammento URL, senza dipendere da
  una pagina Amazon di ritorno esistente.
- Scambia il risultato prima della pulizia e della chiusura di Edge. Non ripete
  automaticamente la registrazione con lo stesso codice.
- Registra in diagnostica soltanto categorie di errore Amazon note, quando
  presenti, senza messaggi, corpi, URL, token o valori sconosciuti.

Chiudi il vecchio prototipo, estrai tutto lo ZIP e avvia **Avvia-Kindle.cmd**.
Sul PC dove il collegamento non era riuscito, usa **1 — Collega Amazon.it** e
completa nuovamente il login/OTP. Il menu 8 non è necessario per questa prova.
Se il PC era già collegato, la sessione resta conservata: puoi usare il menu 2.

Test con browser reale, passaggio OTP simulato, parametri con slash e risultati
in query/frammento; verifica dell'eseguibile Windows con Edge/DPAPI. I test non
usano un account Amazon e non dimostrano quale risposta specifica abbia causato
il 400 sul portatile: è stato riprodotto e corretto il difetto di intercettazione.
Se il servizio restituisce ancora un errore, il nuovo `diagnostic.json` del menu 6
permette di distinguerne meglio la causa senza condividere credenziali.
