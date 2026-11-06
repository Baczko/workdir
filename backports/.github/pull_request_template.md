## Story
[AB#WorkItemNumber](https://dev.azure.com/_workitems/edit/WorkItemNumber/)
<!-- Zamień WorkItemNumber na numer story z Azure DevOps (w obu miejscach). -->

## Opis
<!-- Co i dlaczego. Link do zadania. -->

## Rodzaj PR-a
<!-- Zaznacz jedno -->
- [ ] Zmiana biznesowa na `master`
- [ ] Backport na `master-gcp` (cherry-pick z `master`)
- [ ] Zmiana tylko pod migrację GCP (`master-gcp`), commit ma znacznik `[gcp-only]`

---

## Jeśli PR jest do `master`
Domyślnie każda zmiana z `master` trafia też na `master-gcp`. Po merge'u zrób backport:
`.\scripts\backport.ps1 -PullRequest <numer>`

- [ ] Zmiana NIE ma trafić na `master-gcp`. Uzasadnienie (i daj znać osobie odpowiedzialnej za synchronizację gałęzi):

## Jeśli PR jest do `master-gcp`
Backport zrobiony przez `git cherry-pick -x` (robi to `scripts/backport.ps1`).
Sekcję **Story** na górze skrypt uzupełnia sam z numeru w `[]` na początku tytułu commita; jeśli go nie znajdzie, zostawia szablon do ręcznego uzupełnienia.
**Nie usuwaj linii poniżej** - sprawdza ją pipeline, a po squash and merge musi zostać w opisie.

Backport #<numer PR na master>

(cherry picked from commit <PEŁNY 40-znakowy SHA z master>)

Dla zmian czysto migracyjnych zamiast tego wpisz `[gcp-only]` w komunikacie commita.

## Checklista
- [ ] Testy przechodzą
- [ ] Przy konflikcie podczas cherry-picka opisałem w komentarzu, jak go rozwiązałem
