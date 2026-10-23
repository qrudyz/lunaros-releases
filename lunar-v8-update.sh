#!/bin/bash
# lunar-v8-update.sh - se ruleaza in antiX LIVE pe R500, cu: sudo bash lunar-v8-update.sh
# Faza 1: descarca update-ul LunarOS v8 DIRECT DIN REPO (folderul update/, fara Release):
#         manifest.json + imaginea taiata in parti, le uneste si verifica SHA-256.
#         (telefonul cu tethering USB bagat)
# Faza 2: te anunta cand sa scoti telefonul si sa bagi hardul Intenso 1TB;
#         il detecteaza singur si copiaza fisierele pe el (backup).
# Faza 3: scrie imaginea in slotul liber al discului intern + o activeaza la boot.
# Nu atinge: slotul activ, partitia de date (p4), continutul hardului (doar adauga 2 fisiere).
[ "$(id -u)" = 0 ] || { echo "Ruleaza ca root:  sudo bash lunar-v8-update.sh"; exit 1; }
CHAN="https://raw.githubusercontent.com/qrudyz/lunaros-releases/main/update"
MAN="manifest.json"
WORK=/tmp/lunarupd
mkdir -p "$WORK"; cd "$WORK" || exit 1

echo "=== LunarOS: update la v8 (din antiX, canal direct din repo) ==="
echo
echo "--- Faza 1: descarcare (telefonul cu tethering sa fie bagat) ---"
tries=0
while [ $tries -lt 2 ]; do
  tries=$((tries+1))
  ping -c1 -W3 8.8.8.8 >/dev/null 2>&1 || { for i in usb0 eth1 eth0; do dhclient "$i" >/dev/null 2>&1; done; }
  wget -q "$CHAN/$MAN" -O "$MAN" || { echo "EROARE: nu pot descarca manifest.json - verifica tetheringul."; exit 1; }
  GZ=$(sed -n 's/.*"image"[^"]*"\([^"]*\)".*/\1/p' "$MAN" | head -1)
  SHA_MAN=$(sed -n 's/.*"sha256"[^"]*"\([0-9a-fA-F]*\)".*/\1/p' "$MAN" | head -1)
  PARTS=$(tr '"' '\n' < "$MAN" | grep '\.part-[0-9][0-9]$' | sort -u)
  if [ -n "$PARTS" ]; then
    rm -f "$GZ"
    for p in $PARTS; do
      echo "Descarc $p ..."
      wget -c "$CHAN/$p" -O "$p" || { echo "EROARE: nu pot descarca $p - verifica tetheringul."; exit 1; }
      cat "$p" >> "$GZ"
    done
  else
    wget -c "$CHAN/$GZ" -O "$GZ" || { echo "EROARE: nu pot descarca imaginea - verifica tetheringul."; exit 1; }
  fi
  SHA_FIS=$(sha256sum "$GZ" | cut -d' ' -f1)
  [ "$SHA_FIS" = "$SHA_MAN" ] && break
  echo "Checksum gresit - sterg si descarc din nou..."
  rm -f "$GZ" "$MAN"
done
[ "$SHA_FIS" = "$SHA_MAN" ] || { echo "EROARE: checksum invalid si la a doua incercare. Stop."; exit 1; }
echo "OK: imagine descarcata, unita din parti si verificata (SHA-256 corect)."
echo
echo "************************************************************"
echo "   ACUM: SCOATE TELEFONUL si BAGA HARDUL (Intenso 1TB),"
echo "   apoi apasa Enter."
echo "************************************************************"
read -r _
echo "Detectez hardul (max 60s)..."
HDD=""
n=0
while [ $n -lt 30 ] && [ -z "$HDD" ]; do
  n=$((n+1))
  for d in /sys/block/sd*; do
    [ -d "$d" ] || continue
    dev="/dev/$(basename "$d")"
    vend=$(cat "$d/device/vendor" 2>/dev/null || echo "")
    sect=$(cat "$d/size" 2>/dev/null || echo 0)
    case "$vend" in *Intenso*) HDD="$dev"; break;; esac
    if [ "$sect" -gt 1500000000 ] 2>/dev/null; then HDD="$dev"; break; fi
  done
  [ -z "$HDD" ] && sleep 2
done
[ -n "$HDD" ] || { echo "EROARE: nu am detectat hardul. Verifica cablul si ruleaza din nou."; exit 1; }
echo "Hard detectat: $HDD"
mkdir -p /tmp/hard
mount "${HDD}1" /tmp/hard 2>/dev/null || mount "$HDD" /tmp/hard || { echo "EROARE: nu pot monta hardul."; exit 1; }
cp "$GZ" "$MAN" /tmp/hard/ && echo "OK: fisierele de update sunt copiate pe hard (backup)."
sync; umount /tmp/hard

echo
echo "--- Faza 3: scriu update-ul pe discul intern ---"
INT=""; ACT=""
mkdir -p /tmp/bc
for d in /dev/sd[a-z]; do
  [ -b "${d}1" ] || continue
  if mount -o ro "${d}1" /tmp/bc 2>/dev/null; then
    if [ -f /tmp/bc/lunar-boot.conf ]; then
      INT="$d"; ACT=$(sed -n 's/^ACTIVE=//p' /tmp/bc/lunar-boot.conf | head -1)
    fi
    umount /tmp/bc
  fi
  [ -n "$INT" ] && break
done
[ -n "$INT" ] || { echo "EROARE: nu gasesc discul LunarOS (lunar-boot.conf lipseste). Stop, nimic scris."; exit 1; }
case "$ACT" in
  A) TARGET="${INT}3"; OTHER=B ;;
  B) TARGET="${INT}2"; OTHER=A ;;
  *) echo "EROARE: slot activ necunoscut ('$ACT'). Stop, nimic scris."; exit 1 ;;
esac
echo "Disc intern: $INT, slot activ $ACT -> scriu v8 in slotul $OTHER ($TARGET)"
gunzip -c "$GZ" | dd of="$TARGET" bs=1M status=progress
sync
mount "${INT}1" /tmp/bc || { echo "EROARE: nu pot monta partitia de boot pentru activare."; exit 1; }
printf 'ACTIVE=%s\nPENDING=%s\nTRIED=0\n' "$ACT" "$OTHER" > /tmp/bc/lunar-boot.conf
echo "$(date '+%F %T') update v8 (din antiX, canal repo): scris in slotul $OTHER (pending), activ ramane $ACT pana la confirmare" >> /tmp/bc/update-log.txt
umount /tmp/bc; sync
echo
echo "=== GATA. Scoate stickul antiX (si hardul, daca vrei) si da reboot:"
echo "    porneste LunarOS v8. Daca bootul pica, revine singur pe versiunea veche. ==="
