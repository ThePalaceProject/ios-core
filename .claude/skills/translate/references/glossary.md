# Translation glossary and register

The termbase for `Palace/<lang>.lproj/`. Consult this before translating any key. Consistency
across ~410 strings depends on every occurrence of a domain term resolving the same way.

**This table lists dictionary forms.** Call sites inflect them. `restituire` is the lemma for
"return"; the button renders `Restituisci`. Never paste a cell from the termbase into a `.strings`
file without first deciding what role the string plays — see
[Rendered forms by role](#rendered-forms-by-role).

**Keys are English text.** Palace passes the English string itself to `NSLocalizedString`, so
the left-hand side of every `.strings` entry is the source you are translating. The exceptions —
keys that are symbols rather than prose — are enumerated in
[Identifier-shaped keys](#identifier-shaped-keys) and need different handling.

## The product and its readers

**Everything lent here is digital.** The app circulates ebooks and audiobooks; nothing is
physical, and no one visits a desk. Two consequences that change word choice:

- "Copies" are concurrent-license slots, not objects on a shelf. Italian takes **`copie`**, never
  `esemplari` (a physical specimen of an edition). German `Exemplare` and Spanish `ejemplares` are
  established in digital lending and stay.
- "Return" is an early check-in — the patron gives the license back before it expires. Avoid
  wording that implies carrying an item back or handing it over.

**The readers are public-library patrons**, not software users. Where a generic translation and a
library-domain term are both correct, use the one a patron already meets in their own library's
catalogue. That is the tiebreaker throughout this document.

## Register: formal

| Language | Address form | Example                                            |
| -------- | ------------ | -------------------------------------------------- |
| German   | **Sie**      | "Sind Sie sicher…", `Ihre Ausleihen`               |
| French   | **vous**     | "Vous devez vous connecter…"                       |
| Spanish  | **usted**    | "Debe iniciar sesión…"                             |
| Italian  | **Lei**      | "Deve effettuare l'accesso…", "Aggiorni la pagina" |

Prefer impersonal or nominal constructions where they read naturally — `Anmelden`,
`Se connecter`, `Iniciar sesión` — and fall back to the formal pronoun only when direct address
is unavoidable. This keeps button and nav strings short, which matters for layout (see
[Length policy](#length-policy)).

**Italian splits register by role, and this is correct.** Prose addresses the reader with _Lei_
(`Verifichi la connessione e riprovi`), while buttons take the second-person imperative
(`Accedi`, `Esci`, `Annulla`, `Restituisci`). A button is a label, not an address, and Italian
UI convention is overwhelmingly tu-imperative even in formally-registered products. Do **not**
"correct" `Accedi` to `Acceda`.

## Never translate

- **Palace**, **The Palace Project** — product names.
- **Open eBooks**, **Clever**, **FirstBook** — product/partner names.
- **SimplyE** — the predecessor app; named in migration and support copy.
- **Adobe**, **LCP**, **Readium**, **OverDrive**, **Bibliotheca**, **Axis 360** — DRM systems,
  vendors, and distributors. They appear in error copy and in the distributor field, where they
  are the vendor's own name.
- **AirPlay**, **CarPlay**, **VoiceOver** — Apple feature names. Apple localizes these in its own
  UI in some languages; Palace does not, because the patron is matching our label against a
  system control they already know by that name.
- **App Store**, **iOS**, **iPhone**, **iPad**, **Android**, **Google Play**.
- **ePub**, **PDF** — format identifiers, rendered as-is.
- Any format specifier — `%@`, `%d`, `%ld`, `%f`, `%%`, `%1$@`. Copy them verbatim; the only
  permitted change is bare → positional when the target reorders arguments. See the skill's
  Step 4b.
- **Format-only keys** — keys that are nothing but specifiers, spaces, and punctuation:
  `"%@"`, `"%@ %@"`, `"%@ (%@)"`, `"%@%"`, `"%1$@ %2$@"`. These are assembly templates, not
  prose. **Skip them always.** There is nothing to translate, and the only edit you could make
  to one is a defect. A language that needs a different assembly order changes the *specifier
  order* (positionally), never the punctuation — and that is a developer decision about what the
  template is for, not a translation.
- Login field labels. Basic-auth field names ("Barcode", "PIN", "Library Card Number") arrive
  from the library's own authentication document, not from our catalogs. They are interpolated
  into our strings untranslated, and they are the library's words.
- Durations and dates rendered by `DateFormatter` / `DateComponentsFormatter`. Those come from
  ICU data for the active locale; nothing in `.strings` controls how "2 hours, 15 minutes" reads.
  The `*_suffix_*` entries in `.stringsdict` are the exception and *are* yours.

## Identifier-shaped keys

These 27 keys are symbols, not English prose. Several are user-visible, and because the key
carries no source text, **a miss renders the identifier itself on screen** — `CarPlay.Error.offline`
on a dashboard, in a car, while the patron is driving. They matter more than their obscurity
suggests.

**Translate them by MEANING — what the UI actually shows — and flag every one for a human.** The
"UI slot" column below is derivable from the name and is the load-bearing part: CarPlay templates
have hard, slot-specific length budgets, and the three `OpenApp` variants exist precisely because
CarPlay picks the longest one that fits. **Read the call site** before writing a value; the
meanings below are the shape to expect, not a verified source string.

| Key                               | UI slot                          | Expected sense                                       |
| --------------------------------- | -------------------------------- | ---------------------------------------------------- |
| `AirPlay`                         | route-picker button label        | Brand — keep as `AirPlay` in all five languages       |
| `CarPlay.Error.authRequired`      | error template title             | Sign-in needed                                        |
| `CarPlay.Error.authMessage`       | error template body              | Sign in on the phone to listen                        |
| `CarPlay.Error.downloadRequired`  | error template title             | Download needed                                       |
| `CarPlay.Error.notDownloaded`     | list-row subtitle                | Not downloaded                                        |
| `CarPlay.Error.drmMessage`        | error template body              | License could not be verified                         |
| `CarPlay.Error.offline`           | error template title             | No connection                                         |
| `CarPlay.Error.offlineMessage`    | error template body              | Reconnect to continue                                 |
| `CarPlay.Error.playbackFailed`    | error template title             | Playback failed                                       |
| `CarPlay.Error.tryAgain`          | button                           | Try again                                             |
| `CarPlay.OpenApp.message`         | body — longest variant           | Open Palace on the phone                              |
| `CarPlay.OpenApp.messageShort`    | body — medium variant            | same sense, shorter                                   |
| `CarPlay.OpenApp.messageShortest` | body — shortest variant          | same sense, shortest                                  |
| `CarPlay.chapterNumber`           | list-row title, carries a count  | Chapter *n*                                           |
| `CarPlay.chapters`                | list template title              | Chapters                                              |
| `CarPlay.downloadAudiobooks`      | empty-state body                 | Download audiobooks on the phone                      |
| `CarPlay.library`                 | tab / template title             | Library                                               |
| `CarPlay.noAudiobooks`            | empty-state title                | No audiobooks                                         |
| `CarPlay.nowPlaying`              | template title                   | Now playing                                           |
| `DecreaseFontSize`                | reader accessibility label       | Decrease font size                                    |
| `IncreaseFontSize`                | reader accessibility label       | Increase font size                                    |
| `Filtering...`                    | in-progress label                | Filtering, in progress                                |
| `Loading...`                      | in-progress label                | Loading, in progress                                  |
| `More...`                         | button                           | See more **items** — not "more options"               |
| `eCard`                           | signup affordance                | The library's online library card                     |
| `ePub`                            | format label                     | Identifier — keep as `ePub`                           |
| `opds.error.feed_invalid`         | error body                       | This catalog could not be read                        |

Three notes:

- `Filtering...`, `Loading...` and `More...` *do* carry their English sense; they are listed here
  because the trailing ellipsis makes them easy to mistake for an identifier, and because
  `More...` is genuinely ambiguous — confirm from the call site whether it opens a longer list of
  books or a menu, because the two take different words in all four languages.
- The three `CarPlay.OpenApp.*` variants must be **three different lengths of the same sentence**,
  in the same order. Writing the same value three times defeats the mechanism that chose them.
- The CarPlay lengths are budgets on the *target*, not the source. German will not fit a slot
  sized for English; shorten it (see [Length policy](#length-policy)) rather than let it truncate
  mid-word on a car display.

## Core termbase — nouns

Used as written; inflect for number where the call site is plural.

| English        | German                  | French                | Spanish                  | Italian                  |
| -------------- | ----------------------- | --------------------- | ------------------------ | ------------------------ |
| library        | Bibliothek              | bibliothèque          | biblioteca               | biblioteca               |
| library card   | Bibliotheksausweis      | carte de bibliothèque | tarjeta de la biblioteca | tessera della biblioteca |
| catalog        | Katalog                 | catalogue             | catálogo                 | catalogo                 |
| book           | Buch                    | livre                 | libro                    | libro                    |
| title (a work) | Titel                   | titre                 | título                   | titolo                   |
| ebook / eBook  | E-Book                  | livre numérique       | libro electrónico        | ebook                    |
| audiobook      | Hörbuch                 | livre audio           | audiolibro               | audiolibro               |
| sample         | Leseprobe / Hörprobe    | extrait               | muestra                  | anteprima                |
| loan / on loan | Ausleihe / ausgeliehen  | emprunt / emprunté    | préstamo / prestado      | prestito / in prestito   |
| hold / on hold | Vormerkung / vorgemerkt | réservation / réservé | reserva / reservado      | prenotazione / prenotato |
| copies         | Exemplare               | exemplaires           | ejemplares               | copie                    |
| queue          | Warteliste              | file d'attente        | lista de espera          | lista d'attesa           |
| My Books       | Meine Bücher            | Mes livres            | Mis libros               | I miei libri             |
| series         | Reihe                   | série                 | serie                    | serie                    |
| audience       | Zielgruppe              | public                | público                  | pubblico                 |
| summary        | Zusammenfassung         | résumé                | resumen                  | riassunto                |
| chapter        | Kapitel                 | chapitre              | capítulo                 | capitolo                 |
| bookmark       | Lesezeichen             | signet                | marcador                 | segnalibro               |
| download       | Download                | téléchargement        | descarga                 | download                 |

German keeps `Download` rather than `Herunterladen` as the noun: it is the shorter form, it is
established, and the strings it lands in are length-constrained.

### Bibliographic role labels

These render as field labels beside a value, and the keys are plural ("Narrators"). A label names
a _role_, not a person, so it takes the bare institutional form in every language — no dual forms,
no slashes, no midpoints. See [Gender agreement](#gender-agreement).

| English     | German   | French       | Spanish      | Italian      |
| ----------- | -------- | ------------ | ------------ | ------------ |
| author      | Autor    | auteur       | autor        | autore       |
| narrator    | Sprecher | narrateur    | narrador     | narratore    |
| publisher   | Verlag   | éditeur      | editorial    | editore      |
| distributor | Vertrieb | distributeur | distribuidor | distributore |

## Rendered forms by role

The verbs below change shape depending on where they land. Pick the row that matches the call
site, not the lemma.

**Button convention:** German, French, and Spanish use the infinitive. Italian uses the
second-person imperative (see [Register](#register-formal)).

| Action   | Role     | German        | French            | Spanish              | Italian            |
| -------- | -------- | ------------- | ----------------- | -------------------- | ------------------ |
| borrow   | button   | Ausleihen     | Emprunter         | Pedir prestado       | Prendi in prestito |
|          | progress | Ausleihe...   | Emprunt...        | Pidiendo prestado... | Prestito...        |
| reserve  | button   | Vormerken     | Réserver          | Reservar             | Prenota            |
|          | progress | Vormerkung... | Réservation...    | Reservando...        | Prenotazione...    |
| return   | button   | Zurückgeben   | Rendre            | Devolver             | Restituisci        |
|          | progress | Rückgabe...   | Retour...         | Devolviendo...       | Restituzione...    |
| cancel   | button   | Abbrechen     | Annuler           | Cancelar             | Annulla            |
|          | progress | Abbruch...    | Annulation...     | Cancelando...        | Annullamento...    |
| sign in  | button   | Anmelden      | Se connecter      | Iniciar sesión       | Accedi             |
|          | progress | Anmeldung...  | Connexion...      | Iniciando sesión...  | Accesso...         |
| sign out | button   | Abmelden      | Se déconnecter    | Cerrar sesión        | Esci               |
| read     | button   | Lesen         | Lire              | Leer                 | Leggi              |
| listen   | button   | Hören         | Écouter           | Escuchar             | Ascolta            |
| download | button   | Laden         | Télécharger       | Descargar            | Scarica            |
|          | progress | Download...   | Téléchargement... | Descargando...       | Download...        |
| open     | progress | Öffnen...     | Ouverture...      | Abriendo...          | Apertura...        |
| search   | button   | Suchen        | Rechercher        | Buscar               | Cerca              |
|          | noun     | Suche         | Recherche         | Búsqueda             | Ricerca            |
| filter   | button   | Filtern       | Filtrer           | Filtrar              | Filtra             |
|          | noun     | Filter        | Filtre            | Filtro               | Filtro             |
| remove   | button   | Entfernen     | Supprimer         | Eliminar             | Rimuovi            |
| preview  | button   | Vorschau      | Aperçu            | Vista previa         | Anteprima          |
| retry    | button   | Wiederholen   | Réessayer         | Reintentar           | Riprova            |

### Generic chrome

The small buttons appear on nearly every screen and must be identical everywhere they appear.

| English | German      | French     | Spanish      | Italian  |
| ------- | ----------- | ---------- | ------------ | -------- |
| Back    | Zurück      | Retour     | Atrás        | Indietro |
| OK      | OK          | OK         | OK           | OK       |
| Cancel  | Abbrechen   | Annuler    | Cancelar     | Annulla  |
| Done    | Fertig      | Terminé    | Hecho        | Fine     |
| Close   | Schließen   | Fermer     | Cerrar       | Chiudi   |
| Delete  | Löschen     | Supprimer  | Eliminar     | Elimina  |
| Clear   | Leeren      | Effacer    | Borrar       | Cancella |
| Reload  | Neu laden   | Recharger  | Recargar     | Ricarica |
| Wait    | Warten      | Attendre   | Esperar      | Attendi  |
| Accept  | Akzeptieren | Accepter   | Aceptar      | Accetta |
| Reject  | Ablehnen    | Refuser    | Rechazar     | Rifiuta  |
| Yes     | Ja          | Oui        | Sí           | Sì       |
| No      | Nein        | Non        | No           | No       |
| Next    | Weiter      | Suivant    | Siguiente    | Avanti   |

**Clear and Delete must stay distinct.** "Clear" empties a field or drops a selection; "Delete"
destroys content. German is the one that collapses if you let it — `Löschen` is the natural word
for both, so Clear takes `Leeren` (`Suche leeren`) and Delete keeps `Löschen`. The other three
separate on their own.

### Progress strings

German, French, and Italian use a **deverbal noun** plus `...`; Spanish uses a **gerund**. Each
matches its own UI convention — German's `Anmeldung...` is the pattern to follow, not
`Wird abgebrochen...`.

Two hard requirements:

- **The progress form must differ from the idle label.** `Zurückgeben` → `Zurückgeben...` fails:
  the patron cannot tell the button did anything. Hence `Rückgabe...`.
- **Never mix patterns inside one language.** Every progress string in a language follows one
  shape.

The nominal progress form deliberately collides with the loan noun (`Ausleihe...` / `Emprunt...` /
`Prestito...` sit beside `Ausleihe` / `emprunt` / `prestito`). That is fine — the progress form
only ever appears inside a button mid-action, where context disambiguates.

### Borrow is not lend

The patron **takes**; the library **gives**. Every language has a verb pair here and picking the
wrong side inverts the meaning:

| Language | Patron's verb (use this) | Library's verb (never) |
| -------- | ------------------------ | ---------------------- |
| German   | ausleihen                | verleihen              |
| French   | emprunter                | prêter                 |
| Spanish  | **pedir prestado**       | **prestar**            |
| Italian  | prendere in prestito     | prestare               |

Spanish is the easiest one to get wrong, because the short form is the wrong one. The borrow
progress string is **`Pidiendo prestado...`**, never `Prestando...` — the latter is the gerund of
_prestar_ and tells the patron the library is lending.

### Return is not always "return"

Giving the loan back and navigating back are different verbs everywhere but English. The
navigation sense never takes the circulation verb:

| Sense               | German             | French              | Spanish            | Italian           |
| ------------------- | ------------------ | ------------------- | ------------------ | ----------------- |
| `Return` (the loan) | Zurückgeben        | Rendre              | Devolver           | Restituisci       |
| `Return Loan`       | Ausleihe zurückgeben | Rendre l'emprunt  | Devolver el préstamo | Restituisci il prestito |
| `Back` (navigate)   | Zurück             | Retour              | Atrás              | Indietro          |
| Return to Catalog   | Zurück zum Katalog | Retour au catalogue | Volver al catálogo | Torna al catalogo |

### The hold cluster

Palace exposes five hold actions on one screen, and they must be mutually distinguishable at a
glance. Collapsing any two of them costs the patron a reservation.

| English     | German                 | French                     | Spanish               | Italian                     |
| ----------- | ---------------------- | -------------------------- | --------------------- | --------------------------- |
| Place Hold  | Vormerken              | Réserver                   | Reservar              | Prenota                     |
| On Hold     | Vorgemerkt             | Réservé                    | Reservado             | Prenotato                   |
| Manage Hold | Vormerkung verwalten   | Gérer la réservation       | Gestionar la reserva  | Gestisci la prenotazione    |
| Keep Hold   | Vormerkung behalten    | Conserver la réservation   | Mantener la reserva   | Mantieni la prenotazione    |
| Cancel Hold | Vormerkung stornieren  | Annuler la réservation     | Cancelar la reserva   | Annulla la prenotazione     |
| Holds (nav) | Vormerkungen           | Réservations               | Reservas              | Prenotazioni                |

`Keep Hold` and `Cancel Hold` are the two buttons of one confirmation. They must not both begin
with the same word in the target, or the patron reads the shape instead of the words.

## Availability states

English distinguishes several hold-related states; all four target languages collapse _reserve_
and _hold_ into a single verb, so the distinction has to be carried by the noun or the adjective.

| English (status)    | Meaning                          | German            | French             | Spanish            | Italian             |
| ------------------- | -------------------------------- | ----------------- | ------------------ | ------------------ | ------------------- |
| Available to borrow | copies free, no hold needed      | Verfügbar         | Disponible         | Disponible         | Disponibile         |
| Unavailable         | all copies out, hold placeable   | Nicht verfügbar   | Indisponible       | No disponible      | Non disponibile     |
| Reserved / On Hold  | hold placed, patron is in queue  | Vorgemerkt        | Réservé            | Reservado          | Prenotato           |
| Ready to Borrow     | hold came in, waiting for patron | Jetzt ausleihbar  | Prêt à emprunter   | Reserva disponible | Prenotazione pronta |
| Unsupported         | format the app cannot open       | Nicht unterstützt | Non pris en charge | No compatible      | Non supportato      |

The constraint that matters: **"Ready to Borrow" must be distinguishable from both "Available to
borrow" and "Reserved."** A patron seeing the same word for "anyone can borrow this" and "your
hold is waiting" has lost the only information the status carries. If a layout forces a shorter
rendering, preserve that distinction over brevity.

## A `%@` carries its own gender and article

Palace interpolates three kinds of value that the translator cannot inspect: **book titles**
(`"Borrowed %@."`), **library names** (`"To download books, please sign in to %@."`), and
**library-supplied field labels** ("Barcode", "PIN"). All three have gender and definiteness that
are unknown at translation time, and every one of them is a real string in the app today.

Three rules keep that from breaking:

1. **Never let a participle or adjective agree with a `%@`.** `"Borrowed %@."` cannot become
   `%@ emprunté` — half the titles are feminine. Recast onto a noun **we** supply:
   `Emprunt de %@ effectué.` The agreement is now on `emprunt`, which we chose.
2. **Choose a preposition that does not contract with a following article.** German `bei`/`mit`,
   French `de`/`avec`, Spanish `de`/`con`, Italian `di`/`con` all survive an unknown following
   article. French `à` + `le`, Italian `su` + `l'`, and Spanish `a` + `el` contract — and the
   contraction cannot happen, because the article is inside the placeholder.
3. **Anchor field-label agreement on a noun of ours.** `Your %@ is required.` becomes
   `Das Feld %@ ist erforderlich.` / `Le champ %@ est obligatoire.` /
   `El campo %@ es obligatorio.` / `Il campo %@ è obbligatorio.` — because `%@` is the library's
   own untranslated word and its gender is unknowable. Anchoring on `Feld`/`champ`/`campo` is the
   only rendering that is correct for every value.

Worked examples of rule 1, which is the one that bites:

| English                       | German                        | French                       | Spanish                        | Italian                          |
| ----------------------------- | ----------------------------- | ---------------------------- | ------------------------------ | -------------------------------- |
| `Borrowed %@.`                | `%@ wurde ausgeliehen.`       | `Emprunt de %@ effectué.`    | `Préstamo de %@ realizado.`    | `Prestito di %@ effettuato.`     |
| `Returned %@.`                | `%@ wurde zurückgegeben.`     | `Retour de %@ effectué.`     | `Devolución de %@ realizada.`  | `Restituzione di %@ effettuata.` |
| `Download completed for %@.`  | `Download für %@ abgeschlossen.` | `Téléchargement de %@ terminé.` | `Descarga de %@ completada.` | `Download di %@ completato.`  |
| `Download failed for %@.`     | `Download für %@ fehlgeschlagen.` | `Échec du téléchargement de %@.` | `Error en la descarga de %@.` | `Download di %@ non riuscito.` |

German escapes the problem because its past participle in the perfect does not agree. It is still
written this way so the four languages share one sentence shape.

## Media and format labels

Medium names say what the title _is_ and translate. Format names say what the file is and do not —
`ePub` and `PDF` are identifiers, rendered as-is in every language. `Audiobook` in a format slot is
the exception: it is a medium name standing in for a format, so it translates like the medium.

| English   | German  | French          | Spanish           | Italian    |
| --------- | ------- | --------------- | ----------------- | ---------- |
| Book      | Buch    | Livre           | Libro             | Libro      |
| Ebook     | E-Book  | Livre numérique | Libro electrónico | Ebook      |
| Audiobook | Hörbuch | Livre audio     | Audiolibro        | Audiolibro |
| Duration  | Dauer   | Durée           | Duración          | Durata     |
| Format    | Format  | Format          | Formato           | Formato    |

## Identity and access

| English                                    | German                                                  | French                                             | Spanish                                             | Italian                                                          |
| ------------------------------------------ | ------------------------------------------------------- | -------------------------------------------------- | --------------------------------------------------- | ---------------------------------------------------------------- |
| Sign in                                    | Anmelden                                                | Se connecter                                       | Iniciar sesión                                      | Accedi                                                           |
| Sign up for a library card                 | Bibliotheksausweis beantragen                           | Demander une carte de bibliothèque                 | Solicitar una tarjeta de la biblioteca              | Richiedi una tessera della biblioteca                            |
| Need a library card?                       | Benötigen Sie einen Bibliotheksausweis?                 | Besoin d'une carte de bibliothèque ?               | ¿Necesita una tarjeta de la biblioteca?             | Le serve una tessera della biblioteca?                           |
| Find Your Library                          | Bibliothek finden                                       | Trouver votre bibliothèque                         | Buscar su biblioteca                                | Trova la sua biblioteca                                          |
| Switch Library                             | Bibliothek wechseln                                     | Changer de bibliothèque                            | Cambiar de biblioteca                               | Cambia biblioteca                                                |
| Scan Barcode                               | Barcode scannen                                         | Scanner le code-barres                             | Escanear el código de barras                        | Scansiona il codice a barre                                      |
| Patron Support                             | Support                                                 | Assistance                                         | Asistencia                                          | Assistenza                                                       |
| `Would you like to switch to %@?`          | `Möchten Sie zu %@ wechseln?`                           | `Voulez-vous passer à %@ ?`                        | `¿Desea cambiar a %@?`                              | `Vuole passare a %@?`                                            |
| `To download books, please sign in to %@.` | `Um Bücher zu laden, melden Sie sich bitte bei %@ an.`  | `Pour télécharger des livres, connectez-vous à %@.` | `Para descargar libros, inicie sesión en %@.`      | `Per scaricare libri, effettui l'accesso a %@.`                  |
| You must be signed in to borrow this book. | Sie müssen angemeldet sein, um dieses Buch auszuleihen. | Vous devez vous connecter pour emprunter ce livre. | Debe iniciar sesión para pedir prestado este libro. | Deve effettuare l'accesso per prendere in prestito questo libro. |
| Age Verification                           | Altersprüfung                                           | Vérification de l'âge                              | Verificación de edad                                | Verifica dell'età                                                |
| Please enter your birth year               | Bitte geben Sie Ihr Geburtsjahr ein                     | Veuillez saisir votre année de naissance           | Introduzca su año de nacimiento                     | Inserisca il suo anno di nascita                                 |

"Patron Support" drops the person entirely rather than picking a gendered noun — see
[Gender agreement](#gender-agreement).

## Catalog and navigation

The tightest length constraints in the app. Every one of these lands in a tab bar, a nav bar, a
button, or a lane header, and several are also the accessibility label for the same control.

| English           | German             | French              | Spanish            | Italian           |
| ----------------- | ------------------ | ------------------- | ------------------ | ----------------- |
| Catalog           | Katalog            | Catalogue           | Catálogo           | Catalogo          |
| My Books          | Meine Bücher       | Mes livres          | Mis libros         | I miei libri      |
| Holds             | Vormerkungen       | Réservations        | Reservas           | Prenotazioni      |
| Settings          | Einstellungen      | Réglages            | Ajustes            | Impostazioni      |
| Search Books      | Bücher suchen      | Rechercher un livre | Buscar libros      | Cerca libri       |
| Search Catalog    | Katalog durchsuchen | Rechercher dans le catalogue | Buscar en el catálogo | Cerca nel catalogo |
| Filter by format  | Nach Format filtern | Filtrer par format | Filtrar por formato | Filtra per formato |
| Books list        | Bücherliste        | Liste de livres     | Lista de libros    | Elenco di libri   |
| Expand section    | Abschnitt öffnen   | Développer la section | Expandir la sección | Espandi la sezione |
| Collapse section  | Abschnitt schließen | Réduire la section | Contraer la sección | Riduci la sezione |
| Continue Reading  | Weiterlesen        | Reprendre la lecture | Seguir leyendo    | Continua a leggere |
| Continue Listening | Weiterhören       | Reprendre l'écoute  | Seguir escuchando  | Continua ad ascoltare |
| See All           | Alle ansehen       | Tout voir           | Ver todo           | Vedi tutto        |
| `More books in %@` | `Mehr Bücher in %@` | `Plus de livres dans %@` | `Más libros en %@` | `Altri libri in %@` |

## Reader and player chrome

| English            | German                    | French                 | Spanish                      | Italian                    |
| ------------------ | ------------------------- | ---------------------- | ---------------------------- | -------------------------- |
| Table of contents  | Inhaltsverzeichnis        | Table des matières     | Índice                       | Indice                     |
| Bookmarks          | Lesezeichen               | Signets                | Marcadores                   | Segnalibri                 |
| Search in book     | Im Buch suchen            | Rechercher dans le livre | Buscar en el libro         | Cerca nel libro            |
| Page previews      | Seitenvorschau            | Aperçu des pages       | Vista previa de páginas      | Anteprima delle pagine     |
| Close sample       | Leseprobe schließen       | Fermer l'extrait       | Cerrar la muestra            | Chiudi l'anteprima         |
| Play               | Abspielen                 | Lecture                | Reproducir                   | Riproduci                  |
| Pause              | Pause                     | Pause                  | Pausa                        | Pausa                      |
| `Skip back %d seconds`    | `%d Sekunden zurück`   | `Reculer de %d secondes` | `Retroceder %d segundos` | `Indietro di %d secondi` |
| `Skip forward %d seconds` | `%d Sekunden vor`      | `Avancer de %d secondes` | `Avanzar %d segundos`    | `Avanti di %d secondi`   |
| `Playback speed: %@`      | `Wiedergabegeschwindigkeit: %@` | `Vitesse de lecture : %@` | `Velocidad de reproducción: %@` | `Velocità di riproduzione: %@` |
| `Time elapsed: %@`        | `Verstrichene Zeit: %@` | `Temps écoulé : %@`   | `Tiempo transcurrido: %@`   | `Tempo trascorso: %@`      |
| `Time remaining: %@`      | `Verbleibende Zeit: %@` | `Temps restant : %@`  | `Tiempo restante: %@`       | `Tempo rimanente: %@`      |
| Sleep timer        | Sleep-Timer               | Minuteur de veille     | Temporizador de apagado      | Timer di spegnimento       |

Note that the skip labels put the `%d` in a different position in German than in English. They are
single-specifier strings, so bare form is still correct — positional form is only required when
**two or more** specifiers change relative order.

## Error, empty, and loading states

Keep these impersonal. They are the strings most likely to force a participle agreeing with the
reader, and the recast is always available.

| English                                                                  | German                                                                                              | French                                                                                | Spanish                                                                | Italian                                                                            |
| ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Error                                                                    | Fehler                                                                                              | Erreur                                                                                | Error                                                                  | Errore                                                                             |
| Connection Required                                                      | Verbindung erforderlich                                                                             | Connexion requise                                                                     | Conexión necesaria                                                     | Connessione necessaria                                                             |
| No holds yet                                                             | Noch keine Vormerkungen                                                                             | Aucune réservation                                                                    | Aún no hay reservas                                                    | Nessuna prenotazione                                                               |
| We couldn't load this title. Please check your connection and try again. | Dieser Titel konnte nicht geladen werden. Bitte prüfen Sie Ihre Verbindung und versuchen Sie es erneut. | Ce titre n'a pas pu être chargé. Veuillez vérifier votre connexion et réessayer.    | No se ha podido cargar este título. Compruebe su conexión e inténtelo de nuevo. | Non è stato possibile caricare questo titolo. Verifichi la connessione e riprovi. |
| There was a problem loading your holds. Please try again later.          | Beim Laden Ihrer Vormerkungen ist ein Problem aufgetreten. Bitte versuchen Sie es später erneut.     | Un problème est survenu lors du chargement de vos réservations. Veuillez réessayer plus tard. | Se ha producido un problema al cargar sus reservas. Inténtelo de nuevo más tarde. | Si è verificato un problema durante il caricamento delle sue prenotazioni. Riprovi più tardi. |
| Summary not provided.                                                    | Keine Zusammenfassung vorhanden.                                                                    | Aucun résumé disponible.                                                              | Resumen no disponible.                                                 | Riassunto non disponibile.                                                         |
| Author unknown                                                           | Autor unbekannt                                                                                     | Auteur inconnu                                                                        | Autor desconocido                                                      | Autore sconosciuto                                                                 |

The expired-loan sentence is the longest string in the app and the one most likely to be rewritten
badly. It carries a date `%@` and must not agree with the title:

> `This title is no longer available because your loan ended on %@. It has been removed from your device.`
>
> — DE `Dieser Titel ist nicht mehr verfügbar, da Ihre Ausleihe am %@ endete. Er wurde von Ihrem Gerät entfernt.`
> — FR `Ce titre n'est plus disponible, car votre emprunt s'est terminé le %@. Il a été supprimé de votre appareil.`
> — ES `Este título ya no está disponible porque su préstamo finalizó el %@. Se ha eliminado de su dispositivo.`
> — IT `Questo titolo non è più disponibile perché il suo prestito è terminato il %@. È stato rimosso dal suo dispositivo.`

Both sentences stay; the second one is what tells the patron the file is gone.

## Collection, lane, and series

Three concepts that English blurs and German collapses onto one word if allowed.

- **collection (holdings)** — "our collection of ebooks and audiobooks", the library's whole
  offering. German takes **`Bestand`**, the library-idiomatic term; `Sammlung` suggests a curated
  or private assemblage. French `collection`, Spanish `colección`, Italian `collezione`.
- **collection (lane)** — a feed grouping in the catalog, and the word an accessibility label uses
  for a horizontal row. German `Kategorie`, French `sélection`, Spanish `sección`,
  Italian `sezione`. Keep every lane-sense string on the same word.
- **series** — a book series in the metadata panel. German keeps **`Reihe`**, the established
  bibliographic term. It must not also be used for the lane sense.

Never rendered as a patron's own list — the app has no such feature.

## Gender agreement

Rephrase around the person. This is the general rule; the "Patron" cases below are one instance
of it, and the [`%@` rules](#a--carries-its-own-gender-and-article) are another.

Order of preference:

1. **Recast so agreement never arises** — target the session, the action, or the object instead
   of the reader. `Vous avez été déconnecté` → `Votre session a été fermée`. A participial heading
   like `Déconnecté` becomes the event noun: `Déconnexion`. Spanish shows the pattern most
   cleanly: `Sesión cerrada` / `Ha cerrado la sesión`, with no participle agreeing with the
   reader.
2. **Use the bare institutional form** for role labels that name a function rather than a person —
   `Autor`, `auteur`, `editorial`. Grammatical gender on a field label asserts nothing about the
   individual named beside it.
3. **Only then** accept a gendered noun, using the established institutional form.

Two constructions that look correct and are not: `Vous devez être connecté` and
`È stato disconnesso` both agree with the reader. Recast them — `Vous devez vous connecter`,
`La sua sessione è stata chiusa`.

**Never use the midpoint.** No `auteur·rice`, no `connecté·e`. U+00B7 is a known screen-reader
hazard — VoiceOver reads it aloud as punctuation, and a large share of Palace's localized strings
are read aloud by construction. Slashed dual forms (`Autor/Autorin`) are equally unwelcome in
labels; they are noise in a field label and worse in an announcement.

### Patron

"Patron" has no clean formal equivalent that avoids gendering in German, Spanish, or Italian.
Apply rule 1:

- `%d patrons in the queue` → count the **holds**, not the people:
  `%d Vormerkungen in der Warteliste` / `%d réservations dans la file d'attente` /
  `%d reservas en la lista de espera` / `%d prenotazioni in lista d'attesa`.
- `%d patrons ahead of you in the queue` → same treatment.
- `Patron ID` → `Ausweisnummer` / `Numéro d'usager` / `Número de usuario` / `Numero utente`.
- `Patron Support` → drop the person: `Support` / `Assistance` / `Asistencia` / `Assistenza`.

## Length policy

**German routinely runs ~30% longer than English, and French not far behind.** On iOS that is a
layout bug, not a cosmetic one: tab-bar items truncate, `UIButton` titles shrink or clip, and
Dynamic Type at accessibility sizes multiplies the problem — a label that fits at the default text
size can be three lines at XXXL.

Choose the shortest accurate rendering for:

- anything that lands in a **tab bar, nav bar, toolbar, or button title**;
- any string whose English is under ~25 characters;
- every `CarPlay.*` value, which has a hard slot budget on a fixed display.

`Download Palace` → `Palace laden`, not `Palace herunterladen`. As a rule of thumb, a translation
more than ~1.4× the length of its English source in these categories needs a second look.

The deverbal progress forms above were chosen partly for this reason: `Wird ausgeliehen...` is
idiomatic German but 19 characters against a 12-character English source, in a button already
sized for `Ausleihen`.

**The policy stops at the visible chrome.** Accessibility labels, hints, and announcements have no
layout to overflow — never shorten one for length. See the skill's Step 5.

## Ellipsis and punctuation

- Progress strings end in `...` in English (`Loading...`, `Filtering...`). Keep **three ASCII
  periods**, not `…`, to match the source — except where the English itself uses `…`, where the
  character is copied as-is. The two are different characters and a `.strings` key is matched
  byte-for-byte.
- French requires a non-breaking space before `?`, `!`, `:`, and `;`. Use U+00A0 — a real
  non-breaking space, not a regular space.
- German capitalizes all nouns. Spanish and Italian capitalize only the first word of a UI label
  and proper nouns — do **not** replicate English title case. `Place Hold` → `Prenota`, not
  `Prenota Ora`.
- Spanish questions open with `¿` and exclamations with `¡`.
- **A colon in the English value stays in every language.** Nothing in the layout code puts it
  back if you drop it. French puts U+00A0 before it (`Temps restant : %@`); German, Spanish and
  Italian close it up (`Verbleibende Zeit: %@`).
- **`%%` is a literal percent sign.** `%d%% read` renders "47% read". A value that writes a single
  `%` there turns everything after it into a specifier. German, French, Spanish and Italian all
  put a space before the sign in running text — but do not add one here unless the English has
  one, because the key's spacing is what the designer sized the label for.

## Plural categories in `.stringsdict`

Counts that change wording live in `Palace/<lang>.lproj/Localizable.stringsdict`, not in
`Localizable.strings`. The mechanics are in the skill's Step 4d; the language facts are here.

| Language   | Categories to write | Where 0 lands |
| ---------- | ------------------- | ------------- |
| en         | `one`, `other`      | `other`       |
| de         | `one`, `other`      | `other`       |
| es         | `one`, `other`      | `other`       |
| it         | `one`, `other`      | `other`       |
| fr         | `one`, `other`      | **`one`**     |

- **`other` is mandatory everywhere.** Foundation falls back to it for any category you omit, so
  a missing `other` is the one omission with nowhere to land.
- **Do not write a `many` category for fr/it/es.** CLDR defines one, but it selects on
  compact-decimal and large-magnitude forms that Palace never renders. Foundation already resolves
  every count Palace produces — days, weeks, books, chapters, applied filters — to `one` or
  `other`. A `many` arm is dead weight the next reader has to re-derive.
- **French puts 0 in `one`.** French's `one` rule is `i = 0 or 1`, so `0 jour` is correct French
  and `0 jours` is not. The consequence for the translator is mechanical: **the French `one` value
  must keep its `%d`**, because it renders both 0 and 1. `%d jour` gives `0 jour` and `1 jour`;
  a hard-coded `1 journée` renders **`1 journée` for a zero-day count**.

  That defect is in the tree today — every `*_suffix_long` entry in
  `fr.lproj/Localizable.stringsdict` hard-codes the numeral in `one`. Do not copy the pattern, and
  fix it if a task brings you into that file. The other three languages put 0 in `other`, so
  `0 Tage` / `0 días` / `0 giorni` come out right without special handling.
- The `NSStringFormatValueTypeKey` and the variable name are structure, not content. Copy them
  from the English entry; translate only the category strings.

## There is no in-app language picker

iOS selects the localization from the system language order in Settings. Palace does not ship a
language selector, so there is **no grid of language names to translate** and no exonym table to
maintain — the OS renders those in its own UI, in its own words.

The practical consequence: a patron never chooses "German" inside Palace, so a German string is
only ever seen by someone whose entire phone is in German. Write for that reader. Do not hedge a
translation toward an English-reading audience, and do not leave English in as a
"recognizable" fallback.

## Before you finish

Run through this list. Each item corresponds to a defect that has actually shipped, here or in a
sibling Palace client:

- [ ] **Every key is in every language's table.** No language is missing an entry another has —
      a missing key renders the key, not the English.
- [ ] **No empty values.** An empty string renders blank, which is worse than untranslated.
- [ ] **Specifier parity.** Same set, same count, same type as the English key, in every value.
- [ ] **Positional where reordered.** No bare `%@` pair swapped relative to the English; if one
      specifier is positional, all of them are.
- [ ] **`%%` survived.** Every escaped percent in the key is still escaped in the value.
- [ ] **Every entry ends in `;`** and no key appears twice in a file.
- [ ] **Idle vs. progress differ.** No button whose loading text is its own label plus `...`.
- [ ] **Direction of transaction is right.** Nothing tells the patron the library is lending.
- [ ] **Return senses kept apart.** Nothing navigates with the circulation verb.
- [ ] **Hold cluster stays distinguishable.** Keep Hold and Cancel Hold do not open with the same
      word.
- [ ] **One pattern per language.** All progress strings share a grammatical shape.
- [ ] **No term rendered two ways.** Grep the term across the whole table before finishing.
- [ ] **Interpolated sentences read correctly end to end.** Substitute a real book title, a real
      library name, and a real field label, and read the whole sentence aloud.
- [ ] **Nothing agrees with a `%@`.** No participle or adjective bound to an interpolated title.
- [ ] **Roles respected.** Buttons are not lemmas; headings are not sentences; accessibility
      strings are never abbreviated and never left as identifiers.
- [ ] **Colons kept and spaced.** Every value whose English ends in `:` still ends in one, with
      U+00A0 before it in French and nothing before it in the other three.
- [ ] **Availability states stay distinct.** "Ready to Borrow" ≠ "Available to borrow".
- [ ] **`.stringsdict` has `other` in every language**, no `many` in fr/it/es, and the French
      `one` keeps its `%d`.
- [ ] **No midpoints, no slashed dual forms, no masculine agreement** with the reader.
- [ ] **No abbreviations** carried over from a table cell into a rendered string.
- [ ] **Identifier-shaped keys flagged for a human**, with the meaning you assumed written down.
