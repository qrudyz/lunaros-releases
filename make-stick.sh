#!/usr/bin/env bash
# ============================================================================
# make-stick.sh — LunarOS v3.3: creeaza un stick USB de INSTALARE dintr-un
# terminal Linux.
#
# Ce face:
#   1. Detecteaza stickurile USB conectate (NICIODATA discul de sistem).
#   2. Arata o lista numerotata; alegi stickul si confirmi tastand SCRIE.
#   3. Descarca ISO-ul de instalare LunarOS v3.3 de pe Google Drive
#      (link public, fara cont), verifica SHA-256 si il scrie RAW pe stick
#      (ISO hibrid: booteaza de pe USB ca pe R500). Daca Drive pica,
#      incearca lansarea din repo-ul PUBLIC qrudyz/lunaros-releases
#      (GitHub Releases). Totul cu SHA-256 verificat.
#   4. Scrie ISO-ul pe stick cu dd. ATENTIE: stickul ales e STERS complet!
#
# Dupa scriere: bootezi R500-ul de pe stick (F12), porneste mediul LIVE,
# alegi parola si installerul scrie LunarOS pe discul INTERN; la reboot
# porneste direct de pe disc, fara stick.
#
# Folosire:
#   curl -fsSL https://raw.githubusercontent.com/qrudyz/lunaros-releases/main/make-stick.sh -o make-stick.sh
#   sudo bash make-stick.sh            # [sau: sudo bash make-stick.sh --dry-run]
# ============================================================================
set -euo pipefail

REPO="qrudyz/lunaros-releases"
API_LATEST="https://api.github.com/repos/${REPO}/releases/latest"

# --- Sursa principala: ISO-ul de instalare v3.3 pe Google Drive ---
DRIVE_ISO_ID="1nfarydrDgs-NZU5524VNio39VfJ2U0Db"
DRIVE_ISO_URL="https://drive.usercontent.google.com/download?id=${DRIVE_ISO_ID}&export=download&confirm=t"
ISO_SHA256="6a504596c2408be9382bbf83ce5a58b59b223ef6ed99660723c72ef5c4597c8d"
ISO_BYTES=146800640   # marimea ISO-ului (146.800.640 B, ~140 MB)

DRY_RUN=0
ARGS=("$@")

for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      echo "Folosire: sudo bash make-stick.sh [--dry-run]"
      echo "  --dry-run   doar detecteaza stickul si arata planul; nu descarca ISO-ul, nu scrie nimic pe stick."
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
info "LunarOS v3.3 — creator de stick de instalare"
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

if (( DEV_BYTES < ISO_BYTES )); then
  err "Stickul ($(human "$DEV_BYTES")) e mai mic decat ISO-ul ($(human "$ISO_BYTES")). Anulat."
  exit 1
fi

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# --- 4. DRY-RUN: doar planul ---
if [[ $DRY_RUN -eq 1 ]]; then
  info ""
  info "=== DRY-RUN (nu se scrie nimic) ==="
  info "As face, pe rand:"
  info "  1. Demontez partitiile de pe $DEV."
  info "  2. Descarc ISO-ul de instalare LunarOS v3.3 de pe Google Drive"
  info "     ($(human "$ISO_BYTES")), verific SHA-256: $ISO_SHA256"
  info "  3. Il scriu RAW pe stick: dd bs=4M status=progress conv=fsync."
  info "  4. Daca Drive pica: fallback pe ultima lansare din $REPO (GitHub Releases)."
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

# Siguranta suplimentara: dispozitivul ales nu are voie sa gazduiasca "/"
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

mesaj_gata() {
  info ""
  info "=============================================================="
  info " GATA! Stickul de INSTALARE LunarOS v3.3 e pregatit."
  info " SHA-256 ISO scris: ${1:-$ISO_SHA256}"
  info "=============================================================="
  info "Pasii urmatori:"
  info "  1. Scoate stickul in siguranta (scrisul s-a terminat, sync facut)."
  info "  2. Baga-l in ThinkPad R500 si porneste laptopul cu F12 -> boot de pe USB."
  info "  3. Porneste mediul LIVE; din installer alegi parola si confirmi discul"
  info "     INTERN — LunarOS se instaleaza pe el (sloturi A/B)."
  info "  4. La reboot scoate stickul: sistemul porneste direct de pe disc."
}

# --- 7. Fluxul PRINCIPAL: ISO-ul de pe Google Drive, scris RAW ---
incearca_drive_iso() {
  local iso="$TMPD/lunaros-v33.iso" suma st
  info "Descarc ISO-ul de instalare de pe Google Drive ($(human "$ISO_BYTES"))..."
  if ! curl -fL -# -o "$iso" "$DRIVE_ISO_URL"; then
    err "Descarcarea de pe Google Drive a esuat."
    return 1
  fi
  info "Verific SHA-256..."
  suma="$(sha256sum "$iso" | cut -d' ' -f1)"
  if [[ "${suma,,}" != "${ISO_SHA256,,}" ]]; then
    err "SHA-256 NU corespunde (asteptat $ISO_SHA256, primit $suma)."
    return 1
  fi
  info "SHA-256 OK."
  info "Scriu ISO-ul pe $DEV (dureaza cateva minute)..."
  dd if="$iso" of="$DEV" bs=4M status=progress conv=fsync
  st=$?
  if [[ $st -ne 0 ]]; then
    err "Scrierea a esuat (dd=$st)."
    return 1
  fi
  sync
  mesaj_gata "$suma"
  return 0
}

# --- 8. Fluxul de FALLBACK: ultima lansare GitHub (manifest + imagine) ---
REL_JSON="$TMPD/release.json"
MAN_JSON="$TMPD/manifest.json"

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
man_get() { sed -n "s/.*\"$1\"[^\\\"]*\"\\([^\"]*\\)\".*/\\1/p" "$MAN_JSON" | head -1; }

flux_release() {
  info "Interoghez ultima lansare din $REPO..."
  if ! curl -fsSL -H "Accept: application/vnd.github+json" -H "User-Agent: lunar-make-stick" -o "$REL_JSON" "$API_LATEST"; then
    err "Nu pot citi lansarile din $REPO (retea sau repo fara lansari publicate)."
    exit 1
  fi
  local url
  url="$(asset_field manifest.json browser_download_url)"
  [[ -n "$url" ]] || { err "Release-ul nu contine manifest.json. Anulat."; exit 1; }
  curl -fsSL -o "$MAN_JSON" "$url" || { err "Nu am putut descarca manifest.json. Anulat."; exit 1; }
  local IMG IMG_SHA IMG_URL IMG_ASSET_BYTES
  IMG="$(man_get image)"; IMG_SHA="$(man_get sha256)"
  [[ -n "$IMG" && -n "$IMG_SHA" ]] || { err "Manifest invalid: lipsesc image/sha256. Anulat."; exit 1; }
  IMG_URL="$(asset_field "$IMG" browser_download_url)"
  IMG_ASSET_BYTES="$(asset_field "$IMG" size)"
  [[ -n "$IMG_URL" ]] || { err "Asset-ul imaginii lipseste din release. Anulat."; exit 1; }
  if [[ "${IMG_ASSET_BYTES:-0}" =~ ^[0-9]+$ ]] && (( IMG_ASSET_BYTES > DEV_BYTES )); then
    err "Stickul ($(human "$DEV_BYTES")) e mai mic decat imaginea ($(human "$IMG_ASSET_BYTES")). Anulat."
    exit 1
  fi
  info "Descarc $IMG..."
  curl -fL -# -o "$TMPD/$IMG" "$IMG_URL"
  local suma
  suma="$(sha256sum "$TMPD/$IMG" | cut -d' ' -f1)"
  if [[ "${suma,,}" != "${IMG_SHA,,}" ]]; then
    err "SHA-256 NU corespunde! Asteptat $IMG_SHA, primit $suma. Anulat — nu scriu nimic."
    exit 1
  fi
  info "SHA-256 OK."
  local IMG_BYTES
  case "$IMG" in
    *.gz) IMG_BYTES="$(gzip -l "$TMPD/$IMG" | awk 'NR==2 { print $2 }')" ;;
    *)    IMG_BYTES="$(stat -c%s "$TMPD/$IMG")" ;;
  esac
  if [[ "${IMG_BYTES:-0}" =~ ^[0-9]+$ ]] && (( IMG_BYTES > DEV_BYTES )); then
    err "Imaginea ($(human "$IMG_BYTES")) nu incape pe stick ($(human "$DEV_BYTES")). Anulat."
    exit 1
  fi
  info "Scriu imaginea pe $DEV (dureaza cateva minute)..."
  case "$IMG" in
    *.gz) gunzip -c "$TMPD/$IMG" | dd of="$DEV" bs=4M status=progress conv=fsync ;;
    *.xz) xz -dc "$TMPD/$IMG"    | dd of="$DEV" bs=4M status=progress conv=fsync ;;
    *)    dd if="$TMPD/$IMG" of="$DEV" bs=4M status=progress conv=fsync ;;
  esac
  sync
  mesaj_gata "$suma"
}

# --- 9. Dispecer: intai Google Drive (ISO v3.3), apoi GitHub Releases ---
if incearca_drive_iso; then
  exit 0
fi
info ""
info "Google Drive nu a mers (retea sau verificare picata) si NIMIC nu s-a scris"
info "din el. Incerc lansarea de pe GitHub..."
info ""
flux_release
