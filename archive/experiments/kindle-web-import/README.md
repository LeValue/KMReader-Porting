# First-party web Send to Kindle experiment (2026-11-08)

These source/test snapshots preserve the attempted web transport. They are not
compiled into the application. Refresh-token cookie exchange, `checkAuth` and
CSRF retrieval passed on the personal Windows runner without browser login.
However, device queries and upload initialization redirected to Amazon sign-in;
no document was transferred through this path. It is not a working substitute
for the native STK protocol and is not an automatic mutation fallback.

The native Firs registration subsequently passed after preserving the reference
XML declaration and exact `text/xml` content type (`Request.bodyBytes` avoids the
charset parameter added by `Request.body`). Credentials persisted and were reused
after session reconstruction without another registration. The application keeps
that verified native path; the web attempt is retained here as research evidence.

Relevant runs: Firs success `42482337075`; web session read `42480508219`; web init
redirect `42482208140`. No account identifiers or credentials are stored here.
