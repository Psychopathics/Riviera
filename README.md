# RIVERA – internes Mitglieder- und Lagerverwaltungssystem

Responsive React-Webseite mit Schwarz-Gold-Design, Supabase-Login, Adminfreigabe, Rangverwaltung, Berechtigungen, Mitgliederübersicht und Echtzeit-Lagerbuchungen.

## Enthaltene Funktionen

- Login und Registrierung mit Benutzername und Passwort
- Neue Konten starten mit Status `pending` und benötigen Adminfreigabe
- Mitglieder aktivieren/deaktivieren und Ränge zuordnen
- Eigene Ränge mit Berechtigungs-JSON anlegen
- Getrennte Bereiche: Leaderschaftslager, Hauptlager, Waffenlager
- Artikel, Eingänge und Ausgänge mit Bemerkung
- Bestand wird aus dem unveränderlichen Buchungsjournal berechnet
- Protokoll mit Zeitpunkt, Benutzer, Artikel, Menge und Bemerkung
- Supabase Realtime für parallele Aktualisierung
- Responsive Navigation für Smartphone und Desktop
- GitHub Actions Deployment auf GitHub Pages

## 1. Supabase einrichten

1. Unter https://supabase.com ein neues Projekt erstellen.
2. In **SQL Editor** den kompletten Inhalt von `supabase/schema.sql` ausführen.
3. Unter **Project Settings → API** die Project URL und den `anon` / publishable key kopieren.
4. Im Supabase Dashboard unter **Authentication → Providers → Email** Email-Provider aktivieren. Für diesen Starter kann Email confirmation ausgeschaltet werden, da die eigentliche Freigabe in `profiles.status` erfolgt. In produktiven Installationen sind Rate Limits und ein passender Auth-Provider empfehlenswert.

### Ersten Admin anlegen

1. Webseite lokal starten oder über GitHub Pages öffnen.
2. Mit einem gewünschten Benutzernamen registrieren.
3. In Supabase unter **Authentication → Users** die User-ID kopieren.
4. Im SQL Editor ausführen (UUID ersetzen):

```sql
update public.profiles
set status = 'active', is_admin = true
where id = 'HIER-DIE-USER-UUID-EINTRAGEN';
```

Danach abmelden und wieder anmelden. Dieses manuelle Bootstrap-Verfahren verhindert, dass sich jemand selbst Adminrechte geben kann.

## 2. Lokal starten

Node.js 20 oder neuer installieren:

```bash
npm install
cp .env.example .env
```

In `.env` eintragen:

```env
VITE_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
VITE_SUPABASE_ANON_KEY=YOUR_SUPABASE_ANON_KEY
```

Dann:

```bash
npm run dev
```

## 3. Auf GitHub veröffentlichen

1. Neues GitHub-Repository mit dem Namen **RIVERA** erstellen.
2. Alle Projektdateien in das Repository hochladen und auf `main` pushen.
3. Unter **Settings → Secrets and variables → Actions** folgende Repository-Secrets hinzufügen:
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_ANON_KEY`
4. Unter **Settings → Pages** als Source **GitHub Actions** wählen.
5. Workflow läuft nach Push auf `main`. Die Webseite wird unter `https://DEIN-GITHUB-NAME.github.io/RIVERA/` veröffentlicht.

Wenn das Repository anders heißt, muss `base` in `vite.config.js` angepasst werden. Bei einer eigenen Domain ist `base: '/'` passend.

## Wichtige Hinweise vor produktivem Einsatz

- `anon` Key darf im Frontend verwendet werden; niemals den Supabase `service_role` Key veröffentlichen.
- Die Datenbank erzwingt Zugriffskontrollen über Row Level Security (RLS). Die Oberfläche blendet Bereiche zusätzlich anhand der Rechte aus.
- Im Starter dürfen Admins Mitglieder/Ränge verwalten; Ränge werden erstellt und Mitglieder zugeordnet. Die Berechtigungsmaske ist als Basis enthalten. Für feinere Rechte pro Lager (z. B. getrenntes Lesen, Buchen, Artikelpflege) sollten zusätzliche Permission-Keys und passende RLS-Policies ergänzt werden.
- Das Lagerjournal ist absichtlich unveränderlich. Fehler werden durch eine Gegenbuchung korrigiert, damit das Protokoll nachvollziehbar bleibt.
- Der aktuelle Login erzeugt aus dem Benutzernamen einen internen Alias (`username@rivera.local`). Das ist ein einfacher Starter-Ansatz, kein Ersatz für eine ausgereifte Username-Auth-Lösung. Bei produktivem Einsatz sollte ein Edge Function / eigener Auth-Flow oder ein echter E-Mail-Login mit bestätigter Adresse verwendet werden.
- Vor echtem Betrieb bitte Backup/Restore, Passwort-Wiederherstellung, Rate-Limits, Monitoring und Datenschutz-/Impressumspflichten einrichten.
