Aggiornamento del flusso di collegamento Amazon.it dopo il rifiuto di
registrazione ancora presente nella 0.1.2.

Chrome è ora il browser predefinito per i nuovi collegamenti. Il menu **10**
permette di scegliere Chrome o Edge e ricorda la preferenza, senza cambiare
il browser predefinito di Windows o le sessioni già collegate.

- Usa l'ingresso italiano per dispositivi (`amzn_device_it`, pagina
  `amzn_device_common_dark`) mantenendo il tipo Kindle già usato per la libreria.
- Preserva i `+` letterali nei codici restituiti da Amazon; il precedente parser
  per moduli poteva trasformarli in spazi prima della registrazione.
- Allinea la richiesta al protocollo dispositivo: dominio dei cookie, tipi di
  token e nome con gestione dei duplicati. Non importa cookie dal browser e non
  conserva i cookie aggiuntivi restituiti dal servizio.
- Conserva sessioni, identità e libri esistenti; distingue l'ingresso nel report
  e riconosce altre varianti dei codici d'errore, senza copiarne i messaggi.

Chiudi il vecchio prototipo, estrai tutto lo ZIP e avvia **Avvia-Kindle.cmd**.
Sul portatile dove il collegamento non è riuscito, usa **1 — Collega Amazon.it**
e completa di nuovo il login/OTP. Il menu 8 non serve per questa prova.
Sul PC già collegato continua a usare il menu 2; non occorre rifare il login.

Verifica automatica del contratto dispositivo, dei caratteri opachi, della
registrazione, delle sessioni precedenti e della protezione delle credenziali;
test con browser reale ed eseguibile Windows con Chrome, Edge e DPAPI. Queste prove usano
risposte simulate e non certificano l'accettazione sul proprio account Amazon.
Se il servizio rifiuta ancora l'accesso, esporta il nuovo `diagnostic.json`
dal menu 6, senza condividere URL di ritorno o file di sessione.
