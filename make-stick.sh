#!/usr/bin/env bash
# ============================================================================
# make-stick.sh — LunarOS: creeaza un stick USB bootabil dintr-un terminal Linux
#
# Ce face:
#   1. Detecteaza stickurile USB conectate (NICIODATA discul de sistem).
#   2. Arata o lista numerotata; alegi stickul si confirmi tastand SCRIE.
#   3. Descarca din repo-ul PUBLIC qrudyz/lunaros-releases (GitHub Releases,
#      fara cont/token) manifest.json + imaginea, si verifica SHA-256.
#   4. Scrie imaginea pe stick cu dd. ATENTIE: stickul ales e STERS complet!
#
# Folosire:
#   curl -fsSL https://raw.githubusercontent.com/qrudyz/lunaros-releases/main/make-stick.sh -o make-stick.sh
#   sudo bash make-stick.sh            # [sau: sudo bash make-stick.sh --dry-run]
#
# Regula de alegere a imaginii (functia alege_imaginea de mai jos):
#   - Implicit: campurile "image" + "sha256" din manifest.json (acelasi format
#     ca lunar-update) — imaginea de sistem publicata in release.
#   - Daca release-ul contine un asset cu "live" sau "stick" in nume (imagine
#     live dedicata pentru stick), acela e PREFERAT; checksum-ul lui se ia din
#     campul "digest" (sha256:...) al API-ului GitHub sau din "live_sha256"
#     din manifest. Fara un checksum verificabil, asset-ul preferat NU se
#     foloseste — revenim la "image" + "sha256" din manifest.
# ============================================================================
set -euo pipefail

REPO="qrudyz/lunaros-releases"
API_LATEST="https://api.github.com/repos/${REPO}/releases/latest"
DRY_RUN=0
ARGS=("$@")

for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      echo "Folosire: sudo bash make-stick.sh [--dry-run]"
      echo "  --dry-run   doar detecteaza stickul si arata planul; nu descarca imaginea, nu scrie nimic pe stick."
      exit 0 ;;
    *) echo "EROARE: optiune necunoscuta: $a (incerca --help)" >&2; exit 2 ;;
  esac
done

info() { printf '%s\n' "$*"; }
err()  { printf 'EROARE: %s\n' "$*" >&2; }

# --- 0. Trebuie rulat dintr-un fisier real (re-exec cu sudo + citire de la tastatura) ---
if [[ ! -f "$0" ]]; then
  err "Ruleaza scriptul dintr-un fisier, nu din pipe:"
  err "  curl -fsSL https://raw.githubusercontent.com/${REPO}/main/make-stick.sh -o make-stick.sh && sudo bash make-stick.sh"
  exit 1
fi

# --- 1. Root: re-exec prin sudo daca nu suntem deja root ---
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    info "Am nevoie de root pentru a scrie pe stick — repornesc cu sudo..."
    exec sudo -- bash "$0" "${ARGS[@]}"
  fi
  err "Ruleaza cu sudo:  sudo bash make-stick.sh"
  exit 1
fi

# --- 2. Unelte necesare ---
lipsesc=""
for t in curl lsblk dd sha256sum findmnt umount awk sed grep; do
  command -v "$t" >/dev/null 2>&1 || lipsesc="$lipsesc $t"
done
if [[ -n "$lipsesc" ]]; then
  err "Lipsesc unelte necesare:$lipsesc"
  err "Instaleaza-le mai intai, de exemplu:  sudo apt install curl util-linux coreutils"
  exit 1
fi

human() { awk -v b="$1" 'BEGIN{ split("B KB MB GB TB",u," "); i=1; while (b>=1024 && i<5) { b/=1024; i++ } printf "%.1f %s", b, u[i] }'; }

# Numele discului care gazduieste "/" (ca sa nu-l listam/scriem NICIODATA)
disc_sistem() {
  local src base
  src="$(findmnt -no SOURCE / 2>/dev/null || true)"
  [[ -n "$src" ]] || { printf ''; return; }
  base="${src#/dev/}"
  case "$base" in
    nvme*|mmcblk*) base="$(printf '%s' "$base" | sed -E 's/p[0-9]+$//')" ;;
    *)             base="$(printf '%s' "$base" | sed -E 's/[0-9]+$//')" ;;
  esac
  printf '%s' "$base"
}
ROOTDEV="$(disc_sistem)"

# --- 3. Detectare stickuri: doar removabile (RM=1) sau pe USB (TRAN=usb) ---
# Parsam lsblk ancorat LA DREAPTA (MODEL poate contine spatii): NAME SIZE ... TRAN RM
info "LunarOS — creator de stick bootabil"
info "Scanez dupa stickuri USB..."

declare -a C_NAME=() C_BYTES=() C_MODEL=()
while IFS=$'\t' read -r _n _b _m; do
  [[ -n "$_n" ]] || continue
  if [[ -n "$ROOTDEV" && "$_n" == "$ROOTDEV" ]]; then
    info "  (sar peste discul de sistem: /dev/$_n)"
    continue
  fi
  C_NAME+=("$_n"); C_BYTES+=("$_b"); C_MODEL+=("$_m")
done < <(lsblk -bdn -o NAME,SIZE,MODEL,TRAN,RM 2>/dev/null | awk '{
    rm_ = $NF; tran = tolower($(NF-1)); name = $1; size = $2;
    model = ""; for (i = 3; i <= NF-2; i++) model = (model == "" ? $i : model " " $i);
    if ((rm_ == 1 || tran == "usb") && size + 0 > 0)
      print name "\t" size "\t" (model == "" ? "-" : model)
  }')

if [[ ${#C_NAME[@]} -eq 0 ]]; then
  err "Nu am gasit niciun stick USB (removabil sau pe USB)."
  err "Conecteaza un stick si ruleaza din nou. (Discul de sistem nu e afisat niciodata.)"
  exit 1
fi

info ""
info "Stickuri gasite:"
for i in "${!C_NAME[@]}"; do
  printf '  %d) /dev/%s — %s — %s\n' "$((i+1))" "${C_NAME[$i]}" "${C_MODEL[$i]}" "$(human "${C_BYTES[$i]}")"
done
info ""
printf 'Alege numarul stickului pe care scriu LunarOS: '
read -r alegere || { err "Nicio alegere citita. Anulat."; exit 1; }
if ! [[ "$alegere" =~ ^[0-9]+$ ]] || (( alegere < 1 || alegere > ${#C_NAME[@]} )); then
  err "Alegere invalida: '$alegere'. Anulat — nu s-a scris nimic."
  exit 1
fi
idx=$((alegere - 1))
DEV_NAME="${C_NAME[$idx]}"
DEV="/dev/${DEV_NAME}"
DEV_BYTES="${C_BYTES[$idx]}"
info "Ai ales: $DEV — ${C_MODEL[$idx]} — $(human "$DEV_BYTES")"

# --- Functii pentru GitHub Releases + manifest ---
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
REL_JSON="$TMPD/release.json"
MAN_JSON="$TMPD/manifest.json"

# Extrage un camp al unui asset din JSON-ul release-ului (API-ul GitHub
# returneaza JSON formatat, cate un camp pe linie; cautam dupa "name": "<asset>").
asset_field() { # $1=asset $2=field
  awk -v name="$1" -v field="$2" '
    index($0, "\"name\": \"" name "\"") > 0 { gasit = 1; next }
    gasit && index($0, "\"" field "\":") > 0 {
      line = $0
      sub(/^[^:]*:[ \t]*/, "", line)
      gsub(/[" ,]/, "", line)
      print line; exit
    }' "$REL_JSON"
}

man_get() { # $1=cheie (valoare sir)  din manifest.json
  sed -n "s/.*\"$1\"[^\\\"]*\"\\([^\"]*\\)\".*/\\1/p" "$MAN_JSON" | head -1
}

descarca_release() { # umple REL_JSON; returneaza !=0 daca nu exista release / retea picata
  curl -fsSL -H "Accept: application/vnd.github+json" -H "User-Agent: lunar-make-stick" \
       -o "$REL_JSON" "$API_LATEST"
}
descarca_manifest() { # umple MAN_JSON din asset-ul manifest.json al release-ului
  local url
  url="$(asset_field manifest.json browser_download_url)"
  [[ -n "$url" ]] || return 1
  curl -fsSL -o "$MAN_JSON" "$url"
}

IMG="" IMG_SHA="" IMG_URL="" IMG_ASSET_BYTES=""
alege_imaginea() {
  local m_img m_sha m_live m_live_sha nume digest
  m_img="$(man_get image)";         m_sha="$(man_get sha256)"
  m_live="$(man_get live_image)";   m_live_sha="$(man_get live_sha256)"
  [[ -n "$m_img" && -n "$m_sha" ]] || return 1
  IMG="$m_img"; IMG_SHA="$m_sha"
  # Preferam un asset "live"/"stick" din release (vezi regula din antet).
  while IFS= read -r nume; do
    case "$nume" in
      manifest.json|make-stick.sh) continue ;;
    esac
    case "$(printf '%s' "$nume" | tr '[:upper:]' '[:lower:]')" in
      *live*|*stick*)
        case "$nume" in
          *.gz|*.img|*.iso|*.ext4|*.xz|*.zst)
            if [[ -n "$m_live_sha" && "$m_live" == "$nume" ]]; then
              IMG="$nume"; IMG_SHA="$m_live_sha"
            else
              digest="$(asset_field "$nume" digest)"
              digest="${digest#sha256:}"
              if [[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]]; then
                IMG="$nume"; IMG_SHA="$digest"
              fi
            fi
            break ;;
        esac ;;
    esac
  done < <(grep -o '"name": "[^"]*"' "$REL_JSON" | sed 's/"name": "//; s/"$//')
  IMG_URL="$(asset_field "$IMG" browser_download_url)"
  IMG_ASSET_BYTES="$(asset_field "$IMG" size)"
  [[ -n "$IMG_URL" ]]
}

# --- 4. DRY-RUN: doar planul (poate citi manifestul mic de pe GitHub, dar
#         NU descarca imaginea si NU scrie nimic pe stick) ---
if [[ $DRY_RUN -eq 1 ]]; then
  info ""
  info "=== DRY-RUN (nu se scrie nimic) ==="
  info "As face, pe rand:"
  info "  1. Demontez partitiile de pe $DEV."
  if descarca_release && descarca_manifest && alege_imaginea; then
    ver="$(sed -n 's/.*"version"[^0-9]*\([0-9][0-9]*\).*/\1/p' "$MAN_JSON" | head -1)"
    info "  2. Din $REPO (ultima lansare, v${ver:-?}): descarc manifest.json + $IMG"
    info "     URL: $IMG_URL"
    info "     Verific SHA-256: $IMG_SHA"
  else
    info "  2. Din $REPO: interoghez ultima lansare, descarc manifest.json + imaginea din el"
    info "     (acum nu am putut citi lansarea de pe GitHub — probabil nu e publicata inca;"
    info "      in rularea reala scriptul s-ar opri aici cu eroare.)"
  fi
  info "  3. Verific suma SHA-256 a fisierului descarcat (anulez la nepotrivire)."
  info "  4. Scriu imaginea pe $DEV cu: dd bs=4M status=progress conv=fsync, apoi sync."
  info "Dispozitiv tinta: $DEV — ${C_MODEL[$idx]} — $(human "$DEV_BYTES")"
  info "=== DRY-RUN terminat: nu s-a scris nimic. ==="
  exit 0
fi

# --- 5. Confirmare explicita: doar "SCRIE" tastat exact merge mai departe ---
info ""
info "ATENTIE: TOT continutul de pe $DEV (${C_MODEL[$idx]}, $(human "$DEV_BYTES")) va fi STERS!"
printf 'Daca esti sigur, tasteaza exact SCRIE si apasa Enter: '
read -r confirmare || { err "Nicio confirmare citita. Anulat."; exit 1; }
if [[ "$confirmare" != "SCRIE" ]]; then
  err "Nu ai tastat SCRIE — anulat. Nu s-a scris nimic."
  exit 1
fi

# Siguranta suplimentara: dispozitivul ales nu are voie sa gazduiasca "/" (nu apare
# in lista, dar verificam inca o data chiar inainte de scriere).
if [[ -n "$ROOTDEV" && "$DEV_NAME" == "$ROOTDEV" ]]; then
  err "Refuz: $DEV este discul de sistem (gazduieste /). Anulat."
  exit 1
fi

# --- 6. Demonteaza partitiile stickului ---
info "Demontez partitiile de pe $DEV..."
for part in "$DEV"?*; do
  [[ -e "$part" ]] || continue
  umount "$part" 2>/dev/null || true
done
umount "$DEV" 2>/dev/null || true

# --- 7. Descarca manifest + imagine din ultima lansare, verifica SHA-256 ---
info "Interoghez ultima lansare din $REPO..."
if ! descarca_release; then
  err "Nu pot citi lansarile din $REPO (retea sau repo fara lansari publicate)."
  exit 1
fi
if ! descarca_manifest; then
  err "Release-ul nu contine manifest.json sau nu l-am putut descarca. Anulat."
  exit 1
fi
if ! alege_imaginea; then
  err "Manifest invalid: lipsesc \"image\"/\"sha256\" sau asset-ul imaginii. Anulat."
  exit 1
fi
VER="$(sed -n 's/.*"version"[^0-9]*\([0-9][0-9]*\).*/\1/p' "$MAN_JSON" | head -1)"
info "Lansare v${VER:-?}: imagine $IMG"

# Refuz din start daca stickul e mai mic decat fisierul de descarcat (limita inferioara;
# verificarea exacta cu marimea decompresata se face dupa descarcare).
if [[ "${IMG_ASSET_BYTES:-0}" =~ ^[0-9]+$ ]] && (( IMG_ASSET_BYTES > DEV_BYTES )); then
  err "Stickul ($(human "$DEV_BYTES")) e mai mic decat imaginea ($(human "$IMG_ASSET_BYTES")). Anulat."
  exit 1
fi

info "Descarc $IMG..."
curl -fL -# -o "$TMPD/$IMG" "$IMG_URL"
suma="$(sha256sum "$TMPD/$IMG" | cut -d' ' -f1)"
if [[ "${suma,,}" != "${IMG_SHA,,}" ]]; then
  err "SHA-256 NU corespunde! Asteptat $IMG_SHA, primit $suma. Anulat — nu scriu nimic."
  exit 1
fi
info "SHA-256 OK."

# Marimea reala de scris (decompresata pentru .gz) trebuie sa incapa pe stick.
case "$IMG" in
  *.gz) IMG_BYTES="$(gzip -l "$TMPD/$IMG" | awk 'NR==2 { print $2 }')" ;;
  *)    IMG_BYTES="$(stat -c%s "$TMPD/$IMG")" ;;
esac
if [[ "${IMG_BYTES:-0}" =~ ^[0-9]+$ ]] && (( IMG_BYTES > DEV_BYTES )); then
  err "Imaginea decompresata ($(human "$IMG_BYTES")) nu incape pe stick ($(human "$DEV_BYTES")). Anulat."
  exit 1
fi

# --- 8. Scrierea efectiva ---
info "Scriu imaginea pe $DEV (dureaza cateva minute)..."
case "$IMG" in
  *.gz) gunzip -c "$TMPD/$IMG" | dd of="$DEV" bs=4M status=progress conv=fsync ;;
  *.xz) xz -dc "$TMPD/$IMG"    | dd of="$DEV" bs=4M status=progress conv=fsync ;;
  *)    dd if="$TMPD/$IMG" of="$DEV" bs=4M status=progress conv=fsync ;;
esac
sync

info ""
info "=============================================================="
info " GATA! Stickul cu LunarOS v${VER:-?} e pregatit."
info "=============================================================="
info "Pasii urmatori:"
info "  1. Scoate stickul in siguranta (scrisul s-a terminat, sync facut)."
info "  2. Baga-l in ThinkPad R500 si porneste laptopul."
info "  3. In BIOS/boot menu alege boot de pe USB (mod Legacy/BIOS);"
info "     pe R500 meniul de boot apare de regula cu F12 la pornire."
info "  4. Sistemul porneste LIVE de pe stick — il poti incerca fara instalare,"
info "     iar din desktop ai aplicatia de instalare pe disc cand esti gata."
