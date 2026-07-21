#!/usr/bin/env bash
set -euo pipefail

# Publication des bases sur GitHub Releases (dépôt public kitsune-data).
#
# Placer ce script dans le dépôt local kitsune-data, à côté de :
# - manifest.json
# - les fichiers .db, les archives .zip, ou les deux
#
# Si un .db est présent, il fait foi et le ZIP correspondant est reconstruit
# quand c'est nécessaire. Si seul le ZIP est présent, le manifeste est
# reconstruit depuis ce ZIP sans exiger le .db.
#
# Le champ "archive" du manifeste est l'URL ABSOLUE de l'asset GitHub
# Releases. Les ZIP nouveaux ou modifiés sont téléversés (CLI gh) dans la
# release $TAG, créée si besoin ; les bases inchangées gardent l'URL de leur
# release d'origine. La version d'une base n'est incrémentée que si le
# contenu du .db a changé. manifest.json est réécrit atomiquement — le
# committer/pousser ensuite (rappelé en fin de script).
#
# Options :
#   FORCE=1 ./update.sh              reconstruit et téléverse tous les ZIP
#   DRY_RUN=1 ./update.sh            simule sans écrire ni téléverser
#   TAG=v2026.07.21 ./update.sh      tag de release (défaut : v<date UTC>)
#   REPO=login/kitsune-data ./update.sh   dépôt (défaut : détecté par gh)

MANIFEST="manifest.json"
TMP_MANIFEST="${MANIFEST}.tmp"
BACKUP_MANIFEST="${MANIFEST}.bak"
SCHEMA=1
COMPRESSION="zip"

# id|label|database filename|archive filename|required
DATABASES=(
  "kitsune|Dictionnaire principal|kitsune|kitsune.zip|true"
  "grammar_jlpt|Grammaire JLPT|grammar_jlpt.db|grammar_jlpt.zip|true"
  "kanjivg|Tracés KanjiVG|kanjivg.db|kanjivg.zip|true"
  "idioms|Expressions et kotowaza|idioms.db|idioms.zip|true"
  "exercises|Exercices|exercises.db|exercises.zip|true"
  # Base Leçons désactivée dans l'app (retirée des DEFINITIONS) ; réactiver
  # cette ligne — avec lessons.db ou lessons.zip présent — pour la republier.
  # "lessons|Leçons JLPT|lessons.db|lessons.zip|false"
)

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Erreur: commande introuvable: $1" >&2
    exit 1
  fi
}

if command -v sha256sum >/dev/null 2>&1; then
  sha256_file() { sha256sum "$1" | awk '{print $1}'; }
  sha256_stream() { sha256sum | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
  sha256_stream() { shasum -a 256 | awk '{print $1}'; }
else
  echo "Erreur: sha256sum ou shasum est requis." >&2
  exit 1
fi

file_size() {
  stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1"
}

file_mtime() {
  stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1"
}

utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

previous_value() {
  local id="$1"
  local key="$2"

  if [[ ! -f "$MANIFEST" ]]; then
    return 0
  fi

  awk -v id="$id" -v key="$key" '
    BEGIN { RS = "}," }
    $0 ~ "\"id\"[[:space:]]*:[[:space:]]*\"" id "\"" {
      text = $0
      pattern = "\"" key "\"[[:space:]]*:[[:space:]]*"
      if (match(text, pattern)) {
        value = substr(text, RSTART + RLENGTH)
        gsub(/^[[:space:]]*/, "", value)
        if (value ~ /^"/) {
          sub(/^"/, "", value)
          sub(/".*/, "", value)
        } else {
          sub(/[^0-9-].*/, "", value)
        }
        print value
        exit
      }
    }
  ' "$MANIFEST"
}

archive_db_sha256() {
  local archive="$1"
  local filename="$2"

  if [[ ! -f "$archive" ]] || ! command -v unzip >/dev/null 2>&1; then
    return 0
  fi

  if ! unzip -Z1 "$archive" 2>/dev/null | grep -qx "$filename"; then
    return 0
  fi

  unzip -p "$archive" "$filename" 2>/dev/null | sha256_stream || true
}

archive_uncompressed_size() {
  local archive="$1"
  local filename="$2"

  if ! command -v unzip >/dev/null 2>&1; then
    echo "Erreur: unzip est requis pour lire $archive quand $filename est absent." >&2
    exit 1
  fi

  unzip -l "$archive" "$filename" 2>/dev/null | awk -v filename="$filename" '
    $4 == filename { print $1; found = 1 }
    END { if (!found) exit 1 }
  '
}

ensure_archive_contains_db() {
  local archive="$1"
  local filename="$2"

  if ! command -v unzip >/dev/null 2>&1; then
    echo "Erreur: unzip est requis pour lire $archive quand $filename est absent." >&2
    exit 1
  fi

  if ! unzip -Z1 "$archive" 2>/dev/null | grep -qx "$filename"; then
    echo "Erreur: $archive ne contient pas $filename a la racine." >&2
    exit 1
  fi
}

archive_needs_rebuild() {
  local db_file="$1"
  local archive_file="$2"
  local db_sha="$3"
  local previous_db_sha="$4"

  if [[ "${FORCE:-0}" == "1" ]]; then
    return 0
  fi

  if [[ ! -f "$archive_file" ]]; then
    return 0
  fi

  if [[ -n "$previous_db_sha" ]]; then
    [[ "$db_sha" != "$previous_db_sha" ]]
    return
  fi

  [[ "$(file_mtime "$db_file")" -gt "$(file_mtime "$archive_file")" ]]
}

rebuild_archive() {
  local db_file="$1"
  local archive_file="$2"
  local tmp_archive="${archive_file}.tmp.$$.zip"

  require_command zip
  rm -f "$tmp_archive"
  zip -X -j -q "$tmp_archive" "$db_file"
  mv -f "$tmp_archive" "$archive_file"
}

dry_run_archive() {
  local db_file="$1"
  local archive_file="$2"
  local tmp_dir="${TMPDIR:-/tmp}"
  local tmp_archive="$tmp_dir/$(basename "$archive_file").dryrun.$$.zip"

  require_command zip
  rm -f "$tmp_archive"
  zip -X -j -q "$tmp_archive" "$db_file"
  printf '%s' "$tmp_archive"
}

write_manifest_header() {
  local now="$1"
  {
    printf '{\n'
    printf '  "schema": %s,\n' "$SCHEMA"
    printf '  "updatedAt": "%s",\n' "$now"
    printf '  "compression": "%s",\n' "$COMPRESSION"
    printf '  "databases": [\n'
  } > "$TMP_MANIFEST"
}

append_manifest_entry() {
  local comma="$1"
  local id="$2"
  local label="$3"
  local filename="$4"
  local archive_url="$5"
  local version="$6"
  local archive_sha="$7"
  local db_sha="$8"
  local archive_size="$9"
  local uncompressed_size="${10}"
  local required="${11}"

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
}

write_manifest_footer() {
  {
    printf '  ]\n'
    printf '}\n'
  } >> "$TMP_MANIFEST"
}

# --- Configuration GitHub Releases ------------------------------------------

# Sous Git Bash, un terminal ouvert avant l'installation de GitHub CLI ne l'a
# pas dans son PATH : on ajoute les emplacements d'installation habituels.
if ! command -v gh >/dev/null 2>&1; then
  for gh_dir in "/c/Program Files/GitHub CLI" "$HOME/AppData/Local/Programs/GitHub CLI"; do
    if [[ -x "$gh_dir/gh.exe" || -x "$gh_dir/gh" ]]; then
      PATH="$PATH:$gh_dir"
      break
    fi
  done
fi

TAG="${TAG:-v$(date -u +%Y.%m.%d)}"

if [[ -z "${REPO:-}" ]]; then
  require_command gh
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi
if [[ -z "$REPO" ]]; then
  echo "Erreur: dépôt GitHub introuvable. Lancer depuis le dépôt kitsune-data ou passer REPO=login/kitsune-data." >&2
  exit 1
fi

release_url() {
  printf 'https://github.com/%s/releases/download/%s/%s' "$REPO" "$TAG" "$1"
}

echo "Dépôt: $REPO — release: $TAG"
echo

# ----------------------------------------------------------------------------

NOW="$(utc_now)"
write_manifest_header "$NOW"

total=${#DATABASES[@]}
index=0
changes=0
UPLOAD_FILES=()

for spec in "${DATABASES[@]}"; do
  index=$((index + 1))
  IFS='|' read -r id label filename archive required <<< "$spec"

  if [[ ! -f "$filename" && ! -f "$archive" ]]; then
    echo "Erreur: ni $filename ni $archive ne sont presents." >&2
    rm -f "$TMP_MANIFEST"
    exit 1
  fi

  if [[ ! -f "$filename" ]]; then
    ensure_archive_contains_db "$archive" "$filename"
  fi

  previous_version="$(previous_value "$id" "version")"
  previous_archive_sha="$(previous_value "$id" "sha256")"
  previous_db_sha="$(previous_value "$id" "dbSha256")"
  previous_archive_url="$(previous_value "$id" "archive")"

  if [[ -f "$filename" ]]; then
    db_sha="$(sha256_file "$filename")"
  else
    db_sha="$(archive_db_sha256 "$archive" "$filename")"
  fi

  archive_for_manifest="$archive"
  dry_archive=""
  rebuilt=0
  if [[ -f "$filename" ]] && archive_needs_rebuild "$filename" "$archive" "$db_sha" "$previous_db_sha"; then
    echo "ZIP  $archive <- $filename"
    rebuilt=1
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
      dry_archive="$(dry_run_archive "$filename" "$archive")"
      archive_for_manifest="$dry_archive"
    else
      rebuild_archive "$filename" "$archive"
    fi
  fi

  archive_sha="$(sha256_file "$archive_for_manifest")"
  archive_size="$(file_size "$archive_for_manifest")"
  if [[ -f "$filename" ]]; then
    uncompressed_size="$(file_size "$filename")"
  else
    uncompressed_size="$(archive_uncompressed_size "$archive" "$filename")"
  fi

  if [[ -z "$previous_version" ]]; then
    version=1
    changes=$((changes + 1))
    echo "NEW  $id version $version"
  elif [[ -n "$previous_db_sha" && "$db_sha" != "$previous_db_sha" ]]; then
    version=$((previous_version + 1))
    changes=$((changes + 1))
    echo "UPD  $id version $previous_version -> $version"
  elif [[ -z "$previous_db_sha" && -n "$previous_archive_sha" && "$archive_sha" != "$previous_archive_sha" ]]; then
    version=$((previous_version + 1))
    changes=$((changes + 1))
    echo "UPD  $id version $previous_version -> $version"
  else
    version="$previous_version"
    echo "OK   $id version $version"
  fi

  # Téléversement requis si le ZIP a changé, si la version bouge, ou si le
  # manifeste précédent ne portait pas encore d'URL GitHub (migration).
  needs_upload=0
  if [[ "${FORCE:-0}" == "1" || "$rebuilt" == "1" ]]; then
    needs_upload=1
  elif [[ "$previous_archive_url" != http* ]]; then
    needs_upload=1
  elif [[ "$version" != "$previous_version" ]]; then
    needs_upload=1
  fi

  if [[ "$needs_upload" == "1" ]]; then
    archive_url="$(release_url "$archive")"
    UPLOAD_FILES+=("$archive")
  else
    archive_url="$previous_archive_url"
  fi

  comma=","
  if [[ "$index" -eq "$total" ]]; then
    comma=""
  fi

  append_manifest_entry \
    "$comma" \
    "$id" \
    "$label" \
    "$filename" \
    "$archive_url" \
    "$version" \
    "$archive_sha" \
    "$db_sha" \
    "$archive_size" \
    "$uncompressed_size" \
    "$required"

  if [[ -n "$dry_archive" ]]; then
    rm -f "$dry_archive"
  fi
done

write_manifest_footer

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo
  cat "$TMP_MANIFEST"
  rm -f "$TMP_MANIFEST"
  echo
  if [[ ${#UPLOAD_FILES[@]} -gt 0 ]]; then
    echo "DRY_RUN=1: seraient téléversés dans $REPO ($TAG): ${UPLOAD_FILES[*]}"
  fi
  echo "DRY_RUN=1: manifest.json n'a pas ete remplace."
  exit 0
fi

# Téléverser AVANT de remplacer le manifeste : si l'upload échoue, l'ancien
# manifeste (et ses URLs valides) reste en place.
if [[ ${#UPLOAD_FILES[@]} -gt 0 ]]; then
  require_command gh
  if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "Création de la release $TAG..."
    gh release create "$TAG" --repo "$REPO" --title "Bases $TAG" --notes "Publication du $NOW"
  fi
  for archive_file in "${UPLOAD_FILES[@]}"; do
    echo "PUSH $archive_file -> $REPO ($TAG)"
    gh release upload "$TAG" "$archive_file" --repo "$REPO" --clobber
  done
fi

if [[ -f "$MANIFEST" ]]; then
  cp -p "$MANIFEST" "$BACKUP_MANIFEST"
fi

mv -f "$TMP_MANIFEST" "$MANIFEST"

echo
echo "manifest.json mis a jour ($changes changement(s) de version)."
if [[ -f "$BACKUP_MANIFEST" ]]; then
  echo "Ancienne version sauvegardee dans $BACKUP_MANIFEST."
fi
echo
echo "Reste a publier le manifeste :"
echo "  git add manifest.json && git commit -m \"Bases $TAG\" && git push"
