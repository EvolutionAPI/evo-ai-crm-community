#!/usr/bin/env bash
#
# EVO-2187 — cascade-deletion coverage guard.
#
# Deleting a contact (Api::V1::ContactsController#cleanup_contact_dependent_records)
# or a conversation/inbox (DeleteObjectJob#cleanup_conversation_dependencies!) destroys
# a chain of rows. A table with a FK into that chain that is neither ON DELETE CASCADE
# nor removed before the parent goes away raises PG::ForeignKeyViolation — 422 on the
# contact path, 500 on the job path. macro_executions was exactly this (EVO-2186).
#
# Both cleanups are hand-maintained lists, so the next such FK reintroduces the bug
# silently. This guard fails the build when a non-cascade FK into the chain is not in
# the reviewed allowlist, forcing a conscious decision. Rails-free.
#
# It scans BOTH db/schema.rb and db/migrate/: this repo sets
# dump_schema_after_migration = false, so a PR can add a FK-bearing migration without
# regenerating the dump (that is how macro_executions landed in PR #84 — the FK only
# reached db/schema.rb five days later, in an unrelated commit).
#
# Usage: check-cascade-deletion-coverage.sh [schema.rb] [allowlist.txt] [db/migrate|-] [evidence_root|-]
#   Pass "-" for the migrate dir / evidence root to skip that scan (used by the self-tests).
set -uo pipefail

SCHEMA="${1:-db/schema.rb}"
ALLOWLIST="${2:-.github/fk-deletion-allowlist.txt}"
MIGRATE_DIR="${3:-db/migrate}"
EVIDENCE_ROOT="${4:-.}"

# Tables destroyed while deleting a contact/conversation/inbox. A non-cascade FK into
# any of them breaks the delete unless something removes the child first.
PARENTS="conversations contacts messages pipeline_items contact_inboxes notes \
csat_survey_responses mentions conversation_participants reporting_events"

# Files that are allowed to be the "something removes the child first".
EVIDENCE_CLEANUPS="app/controllers/api/v1/contacts_controller.rb app/jobs/delete_object_job.rb"
EVIDENCE_MODELS="app/models"

fail=0
err() { echo "::error::$*"; fail=1; }

is_parent() {
  case " $PARENTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# "conversation" -> "conversations". Only used to test membership in PARENTS, so the
# naive rule is safe: a name it pluralizes wrong simply is not a parent.
pluralize() { case "$1" in *s) printf '%s' "$1" ;; *) printf '%ss' "$1" ;; esac; }

# ---------------------------------------------------------------------------
# 1. Collect (child, parent, cascade) triples from db/schema.rb.
# ---------------------------------------------------------------------------
if [ ! -f "$SCHEMA" ]; then
  echo "::error::schema file '${SCHEMA}' not found — the guard cannot verify anything. Fix the path (EVO-2187)."
  exit 1
fi

pairs=""
schema_fk_lines=0
while IFS= read -r line; do
  schema_fk_lines=$((schema_fk_lines + 1))
  child="$(printf '%s' "$line" | sed -E 's/.*add_foreign_key "([^"]+)", "([^"]+)".*/\1/')"
  parent="$(printf '%s' "$line" | sed -E 's/.*add_foreign_key "([^"]+)", "([^"]+)".*/\2/')"
  cascade=no
  printf '%s' "$line" | grep -q 'on_delete: :cascade' && cascade=yes
  pairs="${pairs}${child} ${parent} ${cascade} ${SCHEMA}
"
done < <(grep -E '^[[:space:]]*add_foreign_key "[^"]+", "[^"]+"' "$SCHEMA")

# A dump with no foreign keys at all means the format changed (structure.sql), the
# path is wrong, or the file is truncated. Passing green there is how a guard rots.
if [ "$schema_fk_lines" -eq 0 ]; then
  echo "::error::no add_foreign_key found in '${SCHEMA}'. Either the path is wrong or the schema format changed — the guard would pass vacuously, so it fails instead (EVO-2187)."
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Collect the same triples from db/migrate/. Most migrations here declare FKs as
#    `t.references :conversation, foreign_key: true`, which never appears as
#    add_foreign_key, so scanning only the dump misses them.
# ---------------------------------------------------------------------------
if [ "$MIGRATE_DIR" != "-" ] && [ -d "$MIGRATE_DIR" ]; then
  # Tables a later migration dropped or renamed away. Their historical FKs are dead
  # weight — without this, `add_contact_to_pipeline_conversations` reports a table
  # that `rename_table :pipeline_conversations, :pipeline_items` removed in 2025.
  dead="$(grep -rhoE '(drop_table|rename_table)[( ]+[:"][a-z0-9_]+' "$MIGRATE_DIR"/*.rb 2>/dev/null \
          | sed -E 's/.*[:"]//' | sort -u)"
  is_dead() { printf '%s\n' "$dead" | grep -qxF "$1"; }

  mig_pairs="$(awk '
    function emit(child, ref, cascade) {
      gsub(/[^a-z0-9_]/, "", ref); if (ref == "" || child == "") return
      print child " " ref " " cascade " " FILENAME
    }
    # create_table :foo / create_table "foo" opens a block; t.references inside it
    # belongs to that table.
    /create_table[( ]+[:"][a-z0-9_]+/ {
      t = $0; sub(/.*create_table[( ]+[:"]/, "", t); sub(/[^a-z0-9_].*/, "", t); cur = t
    }
    /^[[:space:]]*end[[:space:]]*$/ { cur = "" }
    # t.references :conversation, foreign_key: true  (also t.belongs_to)
    /[[:space:]]t\.(references|belongs_to)[[:space:]]+:[a-z0-9_]+/ {
      if (cur == "" || $0 !~ /foreign_key/) next
      r = $0; sub(/.*t\.(references|belongs_to)[[:space:]]+:/, "", r); sub(/[^a-z0-9_].*/, "", r)
      if ($0 ~ /to_table:[[:space:]]*[:"]/) { r = $0; sub(/.*to_table:[[:space:]]*[:"]/, "", r); sub(/[^a-z0-9_].*/, "", r) }
      emit(cur, r, ($0 ~ /on_delete:[[:space:]]*:cascade/) ? "yes" : "no")
    }
    # add_reference :sla_reports, :conversation, foreign_key: true
    /add_reference[( ]+[:"][a-z0-9_]+/ {
      if ($0 !~ /foreign_key/) next
      c = $0; sub(/.*add_reference[( ]+[:"]/, "", c); sub(/[^a-z0-9_].*/, "", c)
      r = $0; sub(/.*add_reference[( ]+[:"][a-z0-9_]+[^:"]*[:"]/, "", r); sub(/[^a-z0-9_].*/, "", r)
      if ($0 ~ /to_table:[[:space:]]*[:"]/) { r = $0; sub(/.*to_table:[[:space:]]*[:"]/, "", r); sub(/[^a-z0-9_].*/, "", r) }
      emit(c, r, ($0 ~ /on_delete:[[:space:]]*:cascade/) ? "yes" : "no")
    }
    # add_foreign_key :sla_reports, :conversations (symbol form, absent from the dump)
    /add_foreign_key[( ]+[:"][a-z0-9_]+/ {
      c = $0; sub(/.*add_foreign_key[( ]+[:"]/, "", c); sub(/[^a-z0-9_].*/, "", c)
      r = $0; sub(/.*add_foreign_key[( ]+[:"][a-z0-9_]+[^:"]*[:"]/, "", r); sub(/[^a-z0-9_].*/, "", r)
      emit(c, r, ($0 ~ /on_delete:[[:space:]]*:cascade/) ? "yes" : "no")
    }
  ' "$MIGRATE_DIR"/*.rb 2>/dev/null)"

  while IFS=' ' read -r child ref cascade src; do
    [ -z "${child:-}" ] && continue
    is_dead "$child" && continue
    pairs="${pairs}${child} $(pluralize "$ref") ${cascade} ${src}
"
  done <<< "$mig_pairs"
fi

# ---------------------------------------------------------------------------
# 3. Load the reviewed allowlist: "<child_table> <parent_table>" per line.
#    Keyed on the PAIR, not the child alone — allowlisting pipeline_items for its FK
#    to contacts must not silently cover a future pipeline_items -> messages FK.
# ---------------------------------------------------------------------------
allow=""
if [ -f "$ALLOWLIST" ]; then
  allow="$(sed 's/\r$//' "$ALLOWLIST" | grep -vE '^[[:space:]]*(#|$)' | awk 'NF>=2 { print $1 " " $2 }')"
  bad_fmt="$(sed 's/\r$//' "$ALLOWLIST" | grep -vE '^[[:space:]]*(#|$)' | awk 'NF<2 { print $1 }')"
  if [ -n "$bad_fmt" ]; then
    err "allowlist '${ALLOWLIST}' has entries without a parent table: $(printf '%s' "$bad_fmt" | tr '\n' ' '). Format is '<child_table> <parent_table>   # how it is handled' (EVO-2187)."
  fi
fi
in_allow() { printf '%s\n' "$allow" | grep -qxF "$1 $2"; }

# ---------------------------------------------------------------------------
# 4. Evidence: an allowlist entry must correspond to real cleanup code. The EVO-2186
#    failure mode was a MISSING destroy_all, and a plain text file cannot notice that
#    someone deleted the line.
#
#    Accepted evidence for table `foo_bars`:
#      - `foo_bars` or `FooBars?` on a non-comment line of a cleanup method, or
#      - a `dependent: :destroy` association in app/models mentioning it.
#    `dependent: :destroy_async` is explicitly NOT evidence: it enqueues a job instead
#    of deleting in the same transaction, so the FK still blocks the parent destroy.
#    That distinction matters here — this codebase uses :destroy_async far more than
#    :destroy, so "I added a dependent:" is not by itself a fix.
# ---------------------------------------------------------------------------
camelize() { printf '%s' "$1" | awk -F_ '{ s=""; for (i=1;i<=NF;i++) s = s toupper(substr($i,1,1)) substr($i,2); print s }'; }
singularize() { case "$1" in *s) printf '%s' "${1%s}" ;; *) printf '%s' "$1" ;; esac; }

evidence_enabled=yes
if [ "$EVIDENCE_ROOT" = "-" ]; then
  evidence_enabled=no
else
  for f in $EVIDENCE_CLEANUPS; do
    if [ ! -f "${EVIDENCE_ROOT}/${f}" ]; then
      echo "::error::cleanup source '${EVIDENCE_ROOT}/${f}' not found — the allowlist cannot be verified. Update EVIDENCE_CLEANUPS in this script if the method moved (EVO-2187)."
      exit 1
    fi
  done
fi

has_cleanup_evidence() {
  local table="$1" re f
  # `macro_executions` matches the table name or the class (MacroExecution) the
  # cleanup calls. Singularize before camelizing, then let the plural be optional.
  re="(${table}|$(camelize "$(singularize "$table")")s?)([^A-Za-z0-9_]|$)"
  # Cleanup methods: any non-comment mention counts (destroy_all, delete_all, ...).
  for f in $EVIDENCE_CLEANUPS; do
    grep -vE '^[[:space:]]*#' "${EVIDENCE_ROOT}/${f}" | grep -qE "$re" && return 0
  done
  # Associations: synchronous dependent: :destroy only — never :destroy_async.
  grep -rhE "dependent:[[:space:]]*:destroy([^_]|$)" "${EVIDENCE_ROOT}/${EVIDENCE_MODELS}" 2>/dev/null \
    | grep -qE "$re" && return 0
  return 1
}

# ---------------------------------------------------------------------------
# 5. Verdict.
# ---------------------------------------------------------------------------
checked=0
seen=""
while IFS=' ' read -r child parent cascade src; do
  [ -z "${child:-}" ] && continue
  is_parent "$parent" || continue
  [ "$cascade" = "yes" ] && continue          # the DB handles it
  case " $seen " in *" ${child}>${parent} "*) continue ;; esac
  seen="${seen}${child}>${parent} "
  checked=$((checked + 1))

  if ! in_allow "$child" "$parent"; then
    err "FK '${child}' -> '${parent}' (${src}) has no ON DELETE CASCADE and is not in ${ALLOWLIST}. Deleting a contact/conversation/inbox will fail with PG::ForeignKeyViolation (422 on the contact path, 500 on the job path) unless something removes '${child}' first. Fix: add on_delete: :cascade, OR a synchronous 'dependent: :destroy' association (NOT :destroy_async — it enqueues a job and does not delete in the same transaction), OR add '${child} ${parent}' to the allowlist AFTER covering it in cleanup_contact_dependent_records AND DeleteObjectJob#cleanup_conversation_dependencies! (EVO-2187)."
    continue
  fi

  if [ "$evidence_enabled" = yes ] && ! has_cleanup_evidence "$child"; then
    err "'${child}' is allowlisted for '${parent}' but no cleanup covers it: it is not referenced in ${EVIDENCE_CLEANUPS// /, } and has no synchronous 'dependent: :destroy' in ${EVIDENCE_MODELS}/. Either the cleanup line was removed, or it is only handled by :destroy_async, which does NOT prevent the FK violation. Restore the cleanup or drop the allowlist entry (EVO-2187)."
  fi
done <<< "$pairs"

if [ "$fail" -eq 0 ]; then
  echo "OK: ${checked} non-cascade FK(s) into the contact/conversation delete chain, all allowlisted with real cleanup coverage (EVO-2187)."
fi
exit "$fail"
