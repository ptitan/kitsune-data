#!/usr/bin/env bash
set -euo pipefail

# publish.sh — publication complète des bases Nakama sur GitHub Releases.
#
# Usage : déposer la ou les bases mises à jour (kitsune, grammar_jlpt.db, …)
# dans le dépôt de données (à côté de manifest.json), puis :
#
#   ./publish.sh
#
# Le script déroule tout, étape par étape :
#   1. vérifie les outils (gh, zip, unzip, git, curl…) et l'authentification
#   2. détecte les bases modifiées (SHA-256 vs manifest.json)
#   3. affiche le plan et demande UNE confirmation
#   4. reconstruit les ZIP des bases modifiées
#   5. crée la release GitHub du jour et téléverse les ZIP
#   6. réécrit manifest.json (les bases inchangées gardent leur entrée à
#      l'identique — URL, version et SHA de leur release d'origine)
#   7. commit + push du manifeste
#   8. vérifie en ligne que tout répond
#
# Options :
#   DRY_RUN=1 ./publish.sh   s'arrête après le plan, ne modifie rien
#   FORCE=1  ./publish.sh    republie tout, même sans changement
#   YES=1    ./publish.sh    ne pose aucune question (pour scripter)
#   TAG=v2026.07.30 REPO=login/repo   surcharges habituelles

MANIFEST="manifest.json"

# id|label|database filename|archive filename|required
DATABASES=(
  "kitsune|Dictionnaire principal|kitsune|kitsune.zip|true"
  "grammar_jlpt|Grammaire JLPT|grammar_jlpt.db|grammar_jlpt.zip|true"
  "kanjivg|Tracés KanjiVG|kanjivg.db|kanjivg.zip|true"
  "idioms|Expressions et kotowaza|idioms.db|idioms.zip|true"
  "exercises|Exercices|exercises.db|exercises.zip|true"
  # "lessons|Leçons JLPT|lessons.db|lessons.zip|false"   # base désactivée
)

# --- Affichage ---------------------------------------------------------------

step()  { printf '\n\033[1;34m=== %s ===\033[0m\n' "$*"; }
ok()    { printf '  \033[32mOK\033[0m  %s\n' "$*"; }
info()  { printf '      %s\n' "$*"; }
fail()  { printf '  \033[31mERREUR\033[0m %s\n' "$*" >&2; exit 1; }

# --- Aides -------------------------------------------------------------------

utc_now()     { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
sha256_file() { sha256sum "$1" | awk '{print $1}'; }
file_size()   { stat -c '%s' "$1"; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Valeur d'un champ pour une base donnée dans le manifeste actuel.
previous_value() {
  local id="$1" key="$2"
  [[ -f "$MANIFEST" ]] || return 0
  awk -v id="$id" -v key="$key" '
    BEGIN { RS = "}," }
    $0 ~ "\"id\"[[:space:]]*:[[:space:]]*\"" id "\"" {
      text = $0
      pattern = "\"" key "\"[[:space:]]*:[[:space:]]*"
      if (match(text, pattern)) {
        value = substr(text, RSTART + RLENGTH)
        gsub(/^[[:space:]]*/, "", value)
        if (value ~ /^"/) { sub(/^"/, "", value); sub(/".*/, "", value) }
        else { sub(/[^0-9-].*/, "", value) }
        print value
        exit
      }
    }
  ' "$MANIFEST"
}

# SHA-256 du .db : depuis le fichier s'il est là, sinon depuis le ZIP.
db_sha_of() {
  local filename="$1" archive="$2"
  if [[ -f "$filename" ]]; then
    sha256_file "$filename"
  elif [[ -f "$archive" ]]; then
    unzip -p "$archive" "$filename" 2>/dev/null | sha256sum | awk '{print $1}'
  fi
}

# --- Étape 1 : outils --------------------------------------------------------

step "Étape 1/8 — Vérification des outils"

for cmd in git zip unzip curl sha256sum awk sed gh; do
  command -v "$cmd" >/dev/null 2>&1 || fail "commande introuvable : $cmd (sous WSL : sudo apt install $cmd)"
done
ok "outils présents (git, zip, unzip, curl, sha256sum, gh)"

gh auth status >/dev/null 2>&1 || fail "gh n'est pas authentifié — lancer : gh auth login"
ok "gh authentifié"

[[ -f "$MANIFEST" ]] || fail "$MANIFEST introuvable — lancer le script depuis le dépôt de données"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "ce dossier n'est pas un dépôt git"
BRANCH="$(git symbolic-ref --short HEAD)"

if [[ -z "${REPO:-}" ]]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi
[[ -n "$REPO" ]] || fail "dépôt GitHub introuvable — passer REPO=login/nom"
ok "dépôt : $REPO (branche $BRANCH)"

TAG="${TAG:-v$(date -u +%Y.%m.%d)}"
ok "release cible : $TAG"

# --- Étape 2 : détection des changements -------------------------------------

step "Étape 2/8 — Détection des bases modifiées"

CHANGED_IDS=()
declare -A DB_SHA STATUS
for spec in "${DATABASES[@]}"; do
  IFS='|' read -r id label filename archive required <<< "$spec"

  if [[ ! -f "$filename" && ! -f "$archive" ]]; then
    fail "ni $filename ni $archive n'est présent pour « $label »"
  fi

  sha="$(db_sha_of "$filename" "$archive")"
  [[ -n "$sha" ]] || fail "impossible de lire $filename (ni fichier ni entrée dans $archive)"
  DB_SHA[$id]="$sha"

  prev_sha="$(previous_value "$id" "dbSha256")"
  prev_ver="$(previous_value "$id" "version")"

  if [[ -z "$prev_ver" ]]; then
    STATUS[$id]="nouvelle"
    CHANGED_IDS+=("$id")
    ok "$label : NOUVELLE base (version 1)"
  elif [[ "$sha" != "$prev_sha" || "${FORCE:-0}" == "1" ]]; then
    STATUS[$id]="modifiée"
    CHANGED_IDS+=("$id")
    ok "$label : MODIFIÉE (version $prev_ver -> $((prev_ver + 1)))"
  else
    STATUS[$id]="inchangée"
    info "$label : inchangée (version $prev_ver)"
  fi
done

if [[ ${#CHANGED_IDS[@]} -eq 0 ]]; then
  printf '\nRien à publier : aucune base modifiée. (FORCE=1 pour republier quand même.)\n'
  exit 0
fi

# --- Étape 3 : plan et confirmation ------------------------------------------

step "Étape 3/8 — Plan de publication"

info "release  : $TAG sur $REPO"
info "bases    : ${CHANGED_IDS[*]}"
info "manifeste: commit + push sur $BRANCH"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  printf '\nDRY_RUN=1 : arrêt ici, rien n'"'"'a été modifié.\n'
  exit 0
fi

if [[ "${YES:-0}" != "1" ]]; then
  printf '\n'
  read -r -p "Publier ces changements ? [o/N] " answer
  case "$answer" in
    o|O|oui|y|Y|yes) ;;
    *) printf 'Abandon — rien n'"'"'a été modifié.\n'; exit 0 ;;
  esac
fi

# --- Étape 4 : reconstruction des ZIP ----------------------------------------

step "Étape 4/8 — Reconstruction des archives"

for spec in "${DATABASES[@]}"; do
  IFS='|' read -r id label filename archive required <<< "$spec"
  [[ "${STATUS[$id]}" == "inchangée" ]] && continue
  [[ -f "$filename" ]] || fail "$filename absent : impossible de reconstruire $archive (base ${STATUS[$id]})"
  tmp="${archive}.tmp.$$.zip"
  rm -f "$tmp"
  zip -X -j -q "$tmp" "$filename"
  mv -f "$tmp" "$archive"
  ok "$archive ($(file_size "$archive") octets)"
done

# --- Étape 5 : release et téléversement --------------------------------------

step "Étape 5/8 — Release GitHub et téléversement"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  ok "release $TAG existante — réutilisée"
else
  gh release create "$TAG" --repo "$REPO" --title "Bases $TAG" --notes "Publication du $(utc_now)" >/dev/null
  ok "release $TAG créée"
fi

for spec in "${DATABASES[@]}"; do
  IFS='|' read -r id label filename archive required <<< "$spec"
  [[ "${STATUS[$id]}" == "inchangée" ]] && continue
  gh release upload "$TAG" "$archive" --repo "$REPO" --clobber
  ok "$archive téléversé"
done

# --- Étape 6 : réécriture du manifeste ---------------------------------------

step "Étape 6/8 — Réécriture de $MANIFEST"

TMP_MANIFEST="${MANIFEST}.tmp"
{
  printf '{\n'
  printf '  "schema": 1,\n'
  printf '  "updatedAt": "%s",\n' "$(utc_now)"
  printf '  "compression": "zip",\n'
  printf '  "databases": [\n'
} > "$TMP_MANIFEST"

total=${#DATABASES[@]}
index=0
for spec in "${DATABASES[@]}"; do
  index=$((index + 1))
  IFS='|' read -r id label filename archive required <<< "$spec"

  if [[ "${STATUS[$id]}" == "inchangée" ]]; then
    # Entrée recopiée à l'identique : le ZIP publié n'a pas bougé, recalculer
    # ses champs depuis le disque risquerait de désynchroniser SHA et URL.
    version="$(previous_value "$id" "version")"
    archive_url="$(previous_value "$id" "archive")"
    archive_sha="$(previous_value "$id" "sha256")"
    db_sha="$(previous_value "$id" "dbSha256")"
    archive_size="$(previous_value "$id" "archiveSize")"
    uncompressed_size="$(previous_value "$id" "uncompressedSize")"
  else
    prev_ver="$(previous_value "$id" "version")"
    version=$(( ${prev_ver:-0} + 1 ))
    archive_url="https://github.com/$REPO/releases/download/$TAG/$archive"
    archive_sha="$(sha256_file "$archive")"
    db_sha="${DB_SHA[$id]}"
    archive_size="$(file_size "$archive")"
    uncompressed_size="$(file_size "$filename")"
  fi

  comma=","
  [[ "$index" -eq "$total" ]] && comma=""
  {
    printf '    {\n'
    printf '      "id": "%s",\n' "$(json_escape "$id")"
    printf '      "label": "%s",\n' "$(json_escape "$label")"
    printf '      "filename": "%s",\n' "$(json_escape "$filename")"
    printf '      "archive": "%s",\n' "$(json_escape "$archive_url")"
    printf '      "version": %s,\n' "$version"
    printf '      "sha256": "%s",\n' "$archive_sha"
    printf '      "dbSha256": "%s",\n' "$db_sha"
    printf '      "archiveSize": %s,\n' "$archive_size"
    printf '      "uncompressedSize": %s,\n' "$uncompressed_size"
    printf '      "required": %s\n' "$required"
    printf '    }%s\n' "$comma"
  } >> "$TMP_MANIFEST"
done
printf '  ]\n}\n' >> "$TMP_MANIFEST"

cp -p "$MANIFEST" "${MANIFEST}.bak"
mv -f "$TMP_MANIFEST" "$MANIFEST"
ok "$MANIFEST réécrit (ancien gardé en ${MANIFEST}.bak)"

# --- Étape 7 : commit et push ------------------------------------------------

step "Étape 7/8 — Publication du manifeste"

git add "$MANIFEST"
if git diff --cached --quiet; then
  info "manifeste identique au commit précédent — rien à pousser"
else
  git commit -q -m "Bases $TAG : ${CHANGED_IDS[*]}"
  git push -q
  ok "commit + push sur $BRANCH"
fi

# --- Étape 8 : vérification en ligne -----------------------------------------

step "Étape 8/8 — Vérification en ligne"

for spec in "${DATABASES[@]}"; do
  IFS='|' read -r id label filename archive required <<< "$spec"
  [[ "${STATUS[$id]}" == "inchangée" ]] && continue
  url="https://github.com/$REPO/releases/download/$TAG/$archive"
  if curl -sfLI "$url" >/dev/null; then
    ok "$archive accessible"
  else
    fail "$url ne répond pas — vérifier la release sur GitHub"
  fi
done

RAW_URL="https://raw.githubusercontent.com/$REPO/$BRANCH/$MANIFEST"
local_updated="$(awk -F'"' '/"updatedAt"/ {print $4; exit}' "$MANIFEST")"
remote_updated="$(curl -sfL "$RAW_URL" | awk -F'"' '/"updatedAt"/ {print $4; exit}' || true)"
if [[ "$remote_updated" == "$local_updated" ]]; then
  ok "manifeste en ligne à jour ($RAW_URL)"
else
  info "manifeste en ligne pas encore rafraîchi (cache CDN ~5 min) — normal, rien à faire"
fi

printf '\n\033[1;32mPublication terminée.\033[0m Les appareils verront la mise à jour au prochain lancement.\n'
