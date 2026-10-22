# LunarOS — lansări publice

Acest repo conține doar **lansările publice** LunarOS: în secțiunea
[Releases](../../releases) găsești `manifest.json` + imaginile de sistem.
Codul sursă este **privat** (în alt repo) — aici publicăm doar imaginile
gata de folosit, ca update-urile să meargă fără cont sau token.

## Instalare rapidă: stick USB bootabil

Pe orice Linux, într-un terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/qrudyz/lunaros-releases/main/make-stick.sh -o make-stick.sh && sudo bash make-stick.sh
```

Ce face scriptul `make-stick.sh`:

1. Detectează stickurile USB conectate — **niciodată discul de sistem**.
2. Alegi stickul din listă și confirmi tastând exact `SCRIE`
   (stickul ales este **șters complet**).
3. Descarcă ultima lansare de aici, verifică suma **SHA-256** din manifest
   și scrie imaginea pe stick.
4. Pornești laptopul de pe stick (boot menu, mod Legacy pe ThinkPad R500)
   și ai sistem LIVE, cu opțiune de instalare pe disc.

Mod de probă, fără să scrie nimic: `sudo bash make-stick.sh --dry-run`.

## Actualizări

Sistemele LunarOS instalate se actualizează singure din Releases-urile de
aici, prin `lunar-update` (sloturi A/B cu rollback automat la eșec).
Repo public ⇒ fără token; partiția de date nu e atinsă de update-uri.
