#!/usr/bin/env bash
#
# EVO-2187 — cascade-deletion coverage guard.
#
# Deleting a contact/conversation destroys the conversation, which fails with a
# PG::ForeignKeyViolation -> HTTP 422 (OPERATION_NOT_ALLOWED) whenever a table has a
# FK to conversations/contacts/messages that is neither ON DELETE CASCADE nor cleaned
# up before the destroy. macro_executions was exactly this (EVO-2186).
#
# This guard fails the build when a NEW non-cascade FK to those parents appears that
# is not in the reviewed allowlist, forcing a conscious decision. Rails-free.
#
# Usage: check-cascade-deletion-coverage.sh [schema.rb] [allowlist.txt]
set -uo pipefail

SCHEMA="${1:-db/schema.rb}"
ALLOWLIST="${2:-.github/fk-deletion-allowlist.txt}"
PARENTS='conversations|contacts|messages'

# Allowlisted child tables = first token of each non-comment, non-blank line.
allow=""
if [ -f "$ALLOWLIST" ]; then
  allow="$(grep -vE '^[[:space:]]*(#|$)' "$ALLOWLIST" | awk '{print $1}')"
fi
in_allow() { printf '%s\n' "$allow" | grep -qxF "$1"; }

fail=0
found_any=0
while IFS= read -r line; do
  found_any=1
  # Cascade FKs are handled by the DB — nothing to clean up.
  printf '%s' "$line" | grep -q 'on_delete: :cascade' && continue
  child="$(printf '%s' "$line" | sed -E 's/.*add_foreign_key "([^"]+)", "[^"]+".*/\1/')"
  if ! in_allow "$child"; then
    echo "::error::FK '${child}' -> conversations/contacts/messages has no ON DELETE CASCADE and is not in ${ALLOWLIST}. Deleting a contact/conversation will 422 (OPERATION_NOT_ALLOWED) unless handled. Fix: add on_delete: :cascade or dependent: :destroy, OR add '${child}' to the allowlist AFTER making cleanup_contact_dependent_records remove it (EVO-2187)."
    fail=1
  fi
done < <(grep -E "add_foreign_key \"[^\"]+\", \"(${PARENTS})\"" "$SCHEMA" 2>/dev/null)

if [ "$found_any" -eq 0 ]; then
  echo "::warning::no add_foreign_key to conversations/contacts/messages found in ${SCHEMA} — check the path."
fi
[ "$fail" -eq 0 ] && echo "OK: every FK to conversations/contacts/messages is cascade or allowlisted (EVO-2187)."
exit "$fail"
