RIVIERA – Versandpaket
=====================

Dateien:
- index.html: eigenständige Browser-Datei für die lokale Demo.
- riviera_setup.sql: Supabase-Datenbankeinrichtung.
- RIVIERA_EINRICHTUNG.txt: Einrichtungshinweise.
- riviera_supabase/functions/riviera-auth/index.ts: Edge-Function-Quelltext.

Zum Vorzeigen/Versenden:
Die index.html kann direkt weitergegeben und lokal im Browser geöffnet werden.

Wichtiger Funktionshinweis:
Die HTML-Oberfläche läuft im Demo-Modus lokal im Browser. Das Speichern der
Supabase-URL und des Publishable Keys in der Oberfläche aktiviert noch keinen
produktiven Onlinebetrieb. Die vollständige Verbindung der Oberfläche mit den
Datenbank-RPCs und Realtime-Abonnements ist noch nicht fertig integriert und
muss vor einem echten Mehrgerätebetrieb implementiert und getestet werden.

Sicherheit:
Der Publishable Key ist für die Browserverwendung vorgesehen. Niemals einen
Supabase Service-Role-Key in index.html eintragen oder weitergeben.
Das Demo-Login ist ausschließlich für Vorführzwecke gedacht.
