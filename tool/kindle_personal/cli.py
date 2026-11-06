"""Personal, interactive Windows prototype. Amazon sessions never enter CI."""

import argparse
import json
import os
import sys
import time
from contextlib import contextmanager
from pathlib import Path

from . import VERSION
from .auth import LoginAttempt, PROFILE, new_serial
from .catalog import CLASSIFICATION_VERSION, synchronize, visible_items
from .client import KindleClient
from .common import KindleError, read_json, write_json
from .download import download_book
from .prepare import prepare_download
from .storage import WindowsVault, account_key, default_directory


@contextmanager
def exclusive(directory):
    directory.mkdir(parents=True, exist_ok=True)
    stream = (directory / "operation.lock").open("a+b")
    try:
        if os.name == "nt":
            import msvcrt

            # A byte-range lock also forbids reads by a second handle on
            # Windows. Inspect file metadata before attempting the lock instead.
            if os.fstat(stream.fileno()).st_size == 0:
                stream.write(b"0")
                stream.flush()
            stream.seek(0)
            try:
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError:
                raise KindleError(
                    "busy", "Un'altra finestra del prototipo sta già lavorando."
                ) from None
        else:
            import fcntl

            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                raise KindleError(
                    "busy", "Un'altra istanza sta già lavorando."
                ) from None
        yield
    finally:
        stream.close()


class Application:
    def __init__(self, directory, *, client=None):
        self.directory = directory
        self.client = client or KindleClient(WindowsVault(directory))
        self.include_dictionaries = False
        try:
            preferences = read_json(directory / "preferences.json", {})
        except KindleError:
            preferences = {}
        selected = (
            preferences.get("login_browser") if isinstance(preferences, dict) else None
        )
        self.login_browser = selected if selected in ("chrome", "msedge") else "chrome"

    def set_login_browser(self, browser):
        if browser not in ("chrome", "msedge"):
            raise KindleError("browser_choice", "Scegli Chrome oppure Edge.")
        write_json(self.directory / "preferences.json", {"login_browser": browser})
        self.login_browser = browser

    @property
    def account_directory(self):
        self.client.require_session()
        return self.directory / "accounts" / account_key(self.client.session)

    def login(self, flow="pkce", browser=None):
        from .browser import capture_login

        if self.client.session:
            print("Account già collegato. Puoi sincronizzare il catalogo.")
            return
        identity = read_json(self.directory / "identity.json") or {
            "serial": new_serial()
        }
        write_json(self.directory / "identity.json", identity)
        attempt = LoginAttempt(identity["serial"], flow)
        (self.directory / "last-error.json").unlink(missing_ok=True)
        selected_browser = browser or self.login_browser
        print(
            "Si apre Amazon.it in una finestra separata di "
            + ("Chrome" if selected_browser == "chrome" else "Edge")
            + "."
        )
        print(
            "Inserisci password ed eventuale codice esclusivamente nella pagina Amazon."
        )
        print(
            "Al termine torna qui. Non condividere URL di ritorno o file di sessione."
        )
        try:
            capture_login(
                attempt,
                channel=selected_browser,
                on_auth=lambda data: self.client.register(attempt, data),
            )
        except KindleError as error:
            error.add_authentication({"browser": selected_browser})
            raise
        print(
            "Dispositivo personale registrato; credenziali protette con Windows DPAPI."
        )
        print(
            "Ora sincronizza il catalogo per verificare l'accesso effettivo a Kindle."
        )

    def library(self, *, full=False):
        path = self.account_directory / "catalog.json"
        snapshot = synchronize(self.client, read_json(path), full=full)
        write_json(path, snapshot)
        self.show_items(snapshot)
        return snapshot

    def show_items(self, snapshot):
        items = visible_items(snapshot, include_dictionaries=self.include_dictionaries)
        for index, item in enumerate(items, 1):
            print(
                f"{index:4}. [{item['type']}] {item['title']} — {', '.join(item['authors'])}"
            )
        print(f"{len(items)} titoli mostrati nella copia locale del catalogo.")
        hidden = len(snapshot.get("items", [])) - len(items)
        if hidden:
            print(
                f"{hidden} dizionari Amazon nascosti. Il menu 9 permette di includerli."
            )
        if not snapshot.get("complete"):
            print(
                "CATALOGO PARZIALE: il server segnala altri risultati o ha raggiunto il limite. Non considero l'elenco completo."
            )

    def cached_library(self):
        snapshot = read_json(self.account_directory / "catalog.json")
        if (
            snapshot is None
            or snapshot.get("classification_version") != CLASSIFICATION_VERSION
        ):
            return self.library(full=True)
        return snapshot

    def download(self, selector, *, converter=None, convert=True):
        snapshot = self.cached_library()
        matches = [item for item in snapshot["items"] if item["key"] == selector]
        if not matches and selector.isdigit():
            index = int(selector) - 1
            items = visible_items(
                snapshot, include_dictionaries=self.include_dictionaries
            )
            matches = items[index : index + 1] if index >= 0 else []
        if len(matches) != 1:
            raise KindleError(
                "book_selection",
                "Scegli il numero del titolo oppure la chiave EBOK:ID / PDOC:ID del catalogo.",
            )
        directory, result = download_book(
            self.client,
            matches[0],
            self.account_directory / "downloads",
            progress=print,
            convert=convert,
            converter=converter,
        )
        (self.directory / "last-error.json").unlink(missing_ok=True)
        self.show_result(directory, result)
        return directory, result

    @staticmethod
    def show_result(directory, result):
        if result["state"] == "importable":
            print("FILE PRONTO PER L'IMPORTAZIONE:")
            print(directory / result["file"])
            print(
                "In KMReader: Libri locali → importa questo file; verifica la lettura e poi riaprilo offline."
            )
        else:
            print("DOWNLOAD COMPLETO; PREPARAZIONE ANCORA NECESSARIA:")
            print(result["reason"])
            print(directory)
            print(
                "Il file non è ancora dichiarato leggibile da KMReader. Puoi riprovare Preparazione senza riscaricarlo."
            )

    def report(self, *, output=None):
        catalog = (
            read_json(self.account_directory / "catalog.json", {})
            if self.client.session
            else {}
        )
        prepared, pending, optional_skipped = 0, 0, 0
        if self.client.session:
            for path in (self.account_directory / "downloads").glob(
                "*/*/preparation.json"
            ):
                record = read_json(path, {})
                prepared += record.get("state") == "importable"
                pending += record.get("state") != "importable"
                optional_skipped += len(
                    read_json(path.parent / "receipt.json", {}).get(
                        "optional_resources_skipped", []
                    )
                )
        report = {
            "schema": 2,
            "prototype_version": VERSION,
            "marketplace": "amazon.it",
            "profile": self.client.session.get("profile", PROFILE)
            if self.client.session
            else PROFILE,
            "connected": bool(self.client.session),
            "login_browser": self.login_browser,
            "login_flow": self.client.session.get("flow")
            if self.client.session
            else None,
            "catalog_count": len(catalog.get("items", [])),
            "library_count": len(visible_items(catalog)),
            "amazon_dictionary_count": sum(
                bool(item.get("is_amazon_dictionary"))
                for item in catalog.get("items", [])
            ),
            "catalog_complete": catalog.get("complete"),
            "importable_count": prepared,
            "needs_preparation_count": pending,
            "optional_resources_skipped_count": optional_skipped,
            "last_error": read_json(self.directory / "last-error.json"),
            "amazon_reading_verified": False,
        }
        output = output or self.directory / "diagnostic.json"
        write_json(output, report)
        print(json.dumps(report, indent=2, ensure_ascii=False))
        print("Diagnostica condivisibile:", output)
        return report

    def menu(self):
        while True:
            print(
                f"\nKMReader Kindle personale {VERSION} — Amazon.it — prototipo download"
            )
            print("1. Collega Amazon.it (browser / PKCE sperimentale)")
            print("2. Sincronizza e mostra catalogo")
            print("3. Scarica un titolo (prepara con Calibre se installato)")
            print("4. Riprova preparazione di un download")
            print("5. Apri cartella dei file")
            print("6. Esporta diagnostica senza credenziali")
            print("7. Scollega il prototipo (mantiene libri e dispositivo Amazon)")
            print("8. Login alternativo storico con token (se PKCE non accettato)")
            print(
                "9. "
                + (
                    "Nascondi dizionari Amazon"
                    if self.include_dictionaries
                    else "Mostra anche i dizionari Amazon"
                )
            )
            print(
                "10. Browser per il login: "
                + ("Chrome" if self.login_browser == "chrome" else "Edge")
                + " (modifica)"
            )
            print("0. Esci")
            choice = input("> ").strip()
            try:
                if choice == "0":
                    return
                if choice in ("1", "8"):
                    self.login("pkce" if choice == "1" else "token")
                elif choice == "2":
                    self.library()
                elif choice == "3":
                    self.show_items(self.cached_library())
                    selection = input(
                        "Numero del titolo (vuoto per annullare): "
                    ).strip()
                    if selection:
                        self.download(selection)
                elif choice == "4":
                    paths = sorted(
                        (self.account_directory / "downloads").glob("*/*/receipt.json")
                    )
                    for index, path in enumerate(paths, 1):
                        print(f"{index}. {read_json(path)['book']['title']}")
                    value = input("Numero del download (vuoto per annullare): ").strip()
                    if value.isdigit() and 0 < int(value) <= len(paths):
                        directory = paths[int(value) - 1].parent
                        self.show_result(
                            directory, prepare_download(directory, convert=True)
                        )
                elif choice == "5":
                    if os.name == "nt":
                        os.startfile(str(self.directory))
                elif choice == "6":
                    self.report()
                elif choice == "7":
                    self.client.vault.clear()
                    self.client.session = None
                    print(
                        "Credenziali locali rimosse. Libri conservati. Nessun dispositivo Amazon scollegato."
                    )
                elif choice == "9":
                    self.include_dictionaries = not self.include_dictionaries
                    self.show_items(self.cached_library())
                elif choice == "10":
                    print("1. Google Chrome\n2. Microsoft Edge")
                    selected = input("Browser (vuoto per annullare): ").strip()
                    if selected in ("1", "2"):
                        self.set_login_browser(
                            "chrome" if selected == "1" else "msedge"
                        )
            except KindleError as error:
                self.record_error(error)

    def record_error(self, error):
        print(
            f"\n{error}\nCodice: {error.code}; fase: {error.stage}; HTTP: {error.status or '-'}"
        )
        if error.authentication:
            print(
                "Autenticazione:", json.dumps(error.authentication, ensure_ascii=False)
            )
        write_json(
            self.directory / "last-error.json",
            {
                **error.diagnostic(),
                "at": int(time.time()),
                "prototype_version": VERSION,
            },
        )


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Prototipo Kindle personale Amazon.it: login, catalogo, download completo e preparazione offline."
    )
    parser.add_argument("--version", action="version", version=VERSION)
    parser.add_argument(
        "--data-dir",
        type=Path,
        help="Archivio locale (credenziali sempre protette con DPAPI)",
    )
    sub = parser.add_subparsers(dest="command")
    login = sub.add_parser("login")
    login.add_argument("--flow", choices=("pkce", "token"), default="pkce")
    login.add_argument("--browser", choices=("msedge", "chrome"), default=None)
    library = sub.add_parser("library")
    library.add_argument("--full", action="store_true")
    library.add_argument("--include-dictionaries", action="store_true")
    download = sub.add_parser("download")
    download.add_argument("book", help="Numero locale oppure EBOK:ID / PDOC:ID")
    download.add_argument("--converter", help="Percorso ebook-convert.exe di Calibre")
    download.add_argument("--no-convert", action="store_true")
    download.add_argument("--include-dictionaries", action="store_true")
    prepare = sub.add_parser("prepare")
    prepare.add_argument(
        "directory", type=Path, help="Cartella contenente receipt.json e le risorse"
    )
    prepare.add_argument("--converter")
    sub.add_parser("status")
    sub.add_parser("logout")
    check = sub.add_parser(
        "self-test",
        help="Test locale: DPAPI e file sintetici; nessun contatto con Amazon",
    )
    check.add_argument("--output", type=Path)
    check.add_argument(
        "--fixtures",
        type=Path,
        help="Esporta i soli file sintetici per la verifica di importazione KMReader",
    )
    check.add_argument(
        "--browser",
        action="store_true",
        help="Verifica anche Chrome ed Edge con risposte interamente sintetiche",
    )
    args = parser.parse_args(argv)
    if args.command == "self-test":
        from .selfcheck import self_check

        report = self_check(browser=args.browser, fixtures=args.fixtures)
        if args.output:
            write_json(args.output, report)
        print(json.dumps(report, indent=2))
        return 0
    application = None
    try:
        directory = args.data_dir or default_directory()
        with exclusive(directory):
            application = Application(directory)
            application.include_dictionaries = getattr(
                args, "include_dictionaries", False
            )
            if args.command is None:
                application.menu()
            elif args.command == "login":
                application.login(args.flow, args.browser)
            elif args.command == "library":
                application.library(full=args.full)
            elif args.command == "download":
                _, result = application.download(
                    args.book, converter=args.converter, convert=not args.no_convert
                )
                return 0 if result["state"] == "importable" else 3
            elif args.command == "prepare":
                result = prepare_download(
                    args.directory.resolve(), convert=True, converter=args.converter
                )
                application.show_result(args.directory, result)
                return 0 if result["state"] == "importable" else 3
            elif args.command == "status":
                application.report()
            elif args.command == "logout":
                application.client.vault.clear()
                print(
                    "Credenziali locali rimosse; nessuna modifica alla libreria o agli altri dispositivi Amazon."
                )
        return 0
    except KindleError as error:
        if application:
            application.record_error(error)
        else:
            print(f"{error} ({error.code})")
        return 2
    except (KeyboardInterrupt, EOFError):
        print("\nOperazione annullata.")
        return 130
    except Exception:
        # Never print a traceback from HTTP/browser libraries: it can embed a
        # signed URL, a callback code or response payload. Reproduce with fakes.
        if application:
            application.record_error(
                KindleError(
                    "unexpected", "Errore interno. Esporta la diagnostica dal menu 6."
                )
            )
        else:
            print("Errore interno del prototipo (unexpected).")
        return 2
    finally:
        if application:
            application.client.close()


if __name__ == "__main__":
    sys.exit(main())
