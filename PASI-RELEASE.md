# Pasul rămas (manual, o singură dată): crearea Release-ului v2 în `qrudyz/lunaros-releases`

Fișierele sunt pregătite în acest director:
- `manifest.json`
- `lunaros-sys-v2.ext4.gz` (99.264.825 bytes, sha256 `18d3780980cacd83ba1d825caf663dd7abdf7537e472c9a144e22d64216ea350` — aceeași valoare e și în manifest.json)

De ce manual: conectorul GitHub (MCP) are doar citire pentru releases (fără `create_release` / upload de asset-uri), repo-ul e complet gol (un release cere un commit de inițializare), iar în mediu nu există token GitHub accesibil pentru REST. Nu e blocaj de permisiuni: repo-ul răspunde prin API.

## Pașii exacți (interfața web GitHub, ~2 minute)

1. Deschide https://github.com/qrudyz/lunaros-releases
2. Dacă repo-ul e gol, adaugă un README de inițializare („Add a README file”) — orice conținut, ex. „LunarOS – imagini de sistem publice (codul e în repo privat)”.
3. Click **Releases** → **Draft a new release**.
4. **Choose a tag** → scrie `v2` → **Create new tag: v2 on publish**. Titlu: `LunarOS Linux v2`.
5. Descriere (poți copia din `notes` în manifest.json).
6. Trage în zona de asset-uri AMBELE fișiere din acest director: `manifest.json` + `lunaros-sys-v2.ext4.gz`. Așteaptă upload-ul complet al .gz-ului (~95 MB).
7. **Publish release**.

Verificare după publicare (trebuie să meargă fără login):
`https://github.com/qrudyz/lunaros-releases/releases/latest/download/manifest.json`

Din acel moment, `lunar-update` pe orice mașină cu v2 descarcă automat din acest repo public, fără token (configurația nouă e deja în imaginea v2 de mai sus, în codul împins pe `qrudyz/lunaros` commit `8b99209907e5f56b593da9cd7c879e27079facab` și în rootfs-urile locale slot/v2/v3).
