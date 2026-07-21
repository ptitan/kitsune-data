#!/usr/bin/env bash
set -euo pipefail

# Place this script in the same directory as:
# - manifest.json
# - either the .db files, the .zip archives, or both
#
# If a .db file is present, it is the source of truth and the matching ZIP is
# rebuilt when needed. If only the ZIP is present, the manifest is rebuilt from
# that ZIP without requiring the .db file.
#
# It creates/updates ZIP archives when possible and rewrites manifest.json atomically.
# A database version is incremented only when the .db content changed.
# Useful options:
#   FORCE=1 ./update.sh     rebuild all ZIP files
#   DRY_RUN=1 ./update.sh   show what would be done without writing manifest.json

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
  "lessons|Leçons JLPT|lessons.db|lessons.zip|false"
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
  local archive="$5"
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
    printf '      "archive": "%s",\n' "$(json_escape "$archive")"
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

NOW="$(utc_now)"
write_manifest_header "$NOW"

total=${#DATABASES[@]}
index=0
changes=0

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

  if [[ -f "$filename" ]]; then
    db_sha="$(sha256_file "$filename")"
  else
    db_sha="$(archive_db_sha256 "$archive" "$filename")"
  fi

  archive_for_manifest="$archive"
  dry_archive=""
  if [[ -f "$filename" ]] && archive_needs_rebuild "$filename" "$archive" "$db_sha" "$previous_db_sha"; then
    echo "ZIP  $archive <- $filename"
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

  comma=","
  if [[ "$index" -eq "$total" ]]; then
    comma=""
  fi

  append_manifest_entry \
    "$comma" \
    "$id" \
    "$label" \
    "$filename" \
    "$archive" \
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
  echo "DRY_RUN=1: manifest.json n'a pas ete remplace."
  exit 0
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
