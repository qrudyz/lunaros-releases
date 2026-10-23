#!/bin/bash
# lunar-v9-update.sh - se ruleaza in antiX LIVE pe R500, cu: sudo bash lunar-v9-update.sh
# Faza 1: descarca update-ul LunarOS v9 DIRECT (direct din repo-ul GitHub qrudyz/lunaros-releases, folderul update/):
#         manifest.json + imaginea in 6 parti, le uneste si verifica SHA-256. (tethering USB bagat)
# Faza 2: te anunta cand sa scoti telefonul si sa bagi hardul Intenso 1TB;
#         il detecteaza singur si copiaza fisierele pe el (backup).
# Faza 3: scrie imaginea in slotul liber al discului intern, inlocuieste si KERNELUL
#         din partitia BOOT cu cel nou #10 (vechiul ramane vmlinuz.bak), activeaza slotul la boot.
# Nu atinge: slotul activ, partitia de date (p4), continutul hardului (doar adauga 2 fisiere).
[ "$(id -u)" = 0 ] || { echo "Ruleaza ca root:  sudo bash lunar-v9-update.sh"; exit 1; }
URL_MAN="https://raw.githubusercontent.com/qrudyz/lunaros-releases/main/update/manifest.json"
URL_PARTS="
https://raw.githubusercontent.com/qrudyz/lunaros-releases/main/update/lunaros-sys-v9.ext4.gz.part-00
https://raw.githubusercontent.com/qrudyz/lunaros-releases/main/update/lunaros-sys-v9.ext4.gz.part-01
https://raw.githubusercontent.com/qrudyz/lunaros-releases/main/update/lunaros-sys-v9.ext4.gz.part-02
https://raw.githubusercontent.com/qrudyz/lunaros-releases/main/update/lunaros-sys-v9.ext4.gz.part-03
https://raw.githubusercontent.com/qrudyz/lunaros-releases/main/update/lunaros-sys-v9.ext4.gz.part-04
https://raw.githubusercontent.com/qrudyz/lunaros-releases/main/update/lunaros-sys-v9.ext4.gz.part-05
"
MAN="manifest.json"
WORK=/tmp/lunarupd
mkdir -p "$WORK"; cd "$WORK" || exit 1

echo "=== LunarOS: update la v9 (din antiX, descarcare directa) ==="
echo
echo "--- Faza 1: descarcare (telefonul cu tethering sa fie bagat) ---"
tries=0
while [ $tries -lt 2 ]; do
  tries=$((tries+1))
  ping -c1 -W3 8.8.8.8 >/dev/null 2>&1 || { for i in usb0 eth1 eth0; do dhclient "$i" >/dev/null 2>&1; done; }
  wget -q "$URL_MAN" -O "$MAN" || { echo "EROARE: nu pot descarca manifest.json - verifica tetheringul (sau linkurile au expirat)."; exit 1; }
  GZ=$(sed -n 's/.*"image"[^"]*"\([^"]*\)".*/\1/p' "$MAN" | head -1)
  SHA_MAN=$(sed -n 's/.*"sha256"[^"]*"\([0-9a-fA-F]*\)".*/\1/p' "$MAN" | head -1)
  rm -f "$GZ"
  ok=1
  for u in $URL_PARTS; do
    p=$(basename "$u")
    echo "Descarc $p ..."
    wget -q "$u" -O "$p" || { ok=0; break; }
    cat "$p" >> "$GZ"
    rm -f "$p"
  done
  [ $ok = 1 ] || { echo "EROARE la descarcarea unei parti - verifica tetheringul."; exit 1; }
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
# antiX monteaza singur hardul cand il bagi: refolosim montarea existenta
# (un mount nou ar pica cu "already mounted", cum a patit v8).
MNT=$(findmnt -n -o TARGET "${HDD}1" 2>/dev/null)
UM=0
if [ -z "$MNT" ]; then
  mkdir -p /tmp/hard
  mount "${HDD}1" /tmp/hard 2>/dev/null || mount "$HDD" /tmp/hard || { echo "EROARE: nu pot monta hardul."; exit 1; }
  MNT=/tmp/hard; UM=1
fi
cp "$GZ" "$MAN" "$MNT/" && echo "OK: fisierele de update sunt copiate pe hard (backup, la $MNT)."
sync; [ $UM = 1 ] && umount /tmp/hard

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
echo "Disc intern: $INT, slot activ $ACT -> scriu v9 in slotul $OTHER ($TARGET)"
gunzip -c "$GZ" | dd of="$TARGET" bs=1M status=progress
sync
mount "${INT}1" /tmp/bc || { echo "EROARE: nu pot monta partitia de boot pentru activare."; exit 1; }
# Kernel nou in partitia BOOT: kernelul care booteaza sta in BOOT, nu in slot.
# Il luam din slotul proaspat scris (boot/vmlinuz); vechiul ramane vmlinuz.bak.
mkdir -p /tmp/ns
KOK=0
if mount -o ro "$TARGET" /tmp/ns 2>/dev/null && [ -f /tmp/ns/boot/vmlinuz ]; then
  [ -f /tmp/bc/vmlinuz.bak ] || cp /tmp/bc/vmlinuz /tmp/bc/vmlinuz.bak
  if cp /tmp/ns/boot/vmlinuz /tmp/bc/vmlinuz.new && mv /tmp/bc/vmlinuz.new /tmp/bc/vmlinuz; then KOK=1; fi
fi
umount /tmp/ns 2>/dev/null
if [ $KOK = 1 ]; then
  echo "OK: kernel nou (#10) instalat si in partitia BOOT (backup: vmlinuz.bak)."
else
  echo "ATENTIE: kernelul din BOOT nu a putut fi inlocuit - ramane cel vechi (fara driverele noi de retea)."
fi
printf 'ACTIVE=%s\nPENDING=%s\nTRIED=0\n' "$ACT" "$OTHER" > /tmp/bc/lunar-boot.conf
echo "$(date '+%F %T') update v9 (din antiX, descarcare directa): scris in slotul $OTHER (pending), kernel BOOT: $([ $KOK = 1 ] && echo inlocuit || echo NEMODIFICAT), activ ramane $ACT pana la confirmare" >> /tmp/bc/update-log.txt
umount /tmp/bc; sync
echo
echo "=== GATA. Scoate stickul antiX (si hardul, daca vrei) si da reboot:"
echo "    porneste LunarOS v9. Daca bootul pica, revine singur pe versiunea veche. ==="
