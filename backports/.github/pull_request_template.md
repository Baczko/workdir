## Opis
<!-- Co i dlaczego. Link do zadania. -->

## Rodzaj PR-a
<!-- Zaznacz jedno -->
- [ ] Zmiana biznesowa na `master`
- [ ] Backport na `master-gcp` (cherry-pick z `master`)
- [ ] Zmiana tylko pod migrację GCP (`master-gcp`), commit ma znacznik `[gcp-only]`

---

## Jeśli PR jest do `master`
- [ ] Zmiana musi trafić też na `master-gcp` -> dodaj label **`needs-gcp-backport`**
- [ ] Zmiana NIE jest potrzebna na `master-gcp`. Uzasadnienie:

Po merge'u uruchom backport: `.\scripts\backport.ps1 -PullRequest <numer>`

## Jeśli PR jest do `master-gcp`
Backport zrobiony przez `git cherry-pick -x` (robi to `scripts/backport.ps1`).
**Nie usuwaj linii poniżej** - sprawdza ją pipeline, a po squash and merge musi zostać w opisie.

Backport #<numer PR na master>

(cherry picked from commit <PEŁNY 40-znakowy SHA z master>)

Dla zmian czysto migracyjnych zamiast tego wpisz `[gcp-only]` w komunikacie commita.

## Checklista
- [ ] Testy przechodzą
- [ ] Przy konflikcie podczas cherry-picka opisałem w komentarzu, jak go rozwiązałem
