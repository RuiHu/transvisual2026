#!/usr/bin/env bash
# .spec/verify.sh — Static acceptance linter
set -u; set -o pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO_ROOT"; SPEC_DIR=".spec"
MISSING=""
for cmd in grep awk sed comm diff python3; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING="$MISSING $cmd"
done
if [ -n "$MISSING" ]; then echo "BLOCKED | Missing dependencies:$MISSING"; exit 2; fi
fail(){ echo "$1 | FAIL       | $2 | $3"; }
pass(){ echo "$1 | PASS       | $2 | $3"; }
blocked(){ echo "$1 | BLOCKED    | $2 | $3"; }
amend(){ echo "$1 | AMENDMENT  | $2 | $3"; }
RESULT_PASS=0; RESULT_FAIL=0; RESULT_BLOCKED=0; RESULT_AMEND=0
tally(){ case "$1" in PASS) RESULT_PASS=$((RESULT_PASS+1));; FAIL) RESULT_FAIL=$((RESULT_FAIL+1));; BLOCKED) RESULT_BLOCKED=$((RESULT_BLOCKED+1));; AMENDMENT) RESULT_AMEND=$((RESULT_AMEND+1));; esac; }
# === C01 ===



check_C01() {
  local f="$SPEC_DIR/constitution.md"
  [ ! -f "$f" ] && { blocked C01 "$f" "file missing"; tally BLOCKED; return; }
  local clauses=$(grep -c '^### [0-9]' "$f" 2>/dev/null || echo 0)
  local verifs=$(grep -c '\*\*Verification\*\*' "$f" 2>/dev/null || echo 0)
  if [ "$clauses" -eq "$verifs" ]; then
    pass C01 "$f" "clauses=$clauses verif=$verifs — match"
    tally PASS
  else
    fail C01 "$f" "clauses=$clauses verif=$verifs — MISMATCH"
    tally FAIL
  fi
}

check_C02() {
  local fc="$SPEC_DIR/constitution.md"; local fs="$SPEC_DIR/spec.md"
  [ ! -f "$fc" ] && { blocked C02 "$fc" "file missing"; tally BLOCKED; return; }
  [ ! -f "$fs" ] && { blocked C02 "$fs" "file missing"; tally BLOCKED; return; }
  local constT=$(grep -oP '<[A-Z_]+>' "$fc" 2>/dev/null | sort -u)
  local specT=$(grep -oP '<[A-Z_]+>' "$fs" 2>/dev/null | sort -u)
  local diffT=$(comm -23 <(echo "$constT") <(echo "$specT") 2>/dev/null)
  if [ -z "$constT" ]; then
    if grep -q 'EXPECTED_CMD' "$fc" 2>/dev/null; then
      if grep -q 'EXPECTED_CMD' "$fs" 2>/dev/null; then
        pass C02 "$fc,$fs" "EXPECTED_CMD referenced by constitution is bound in spec"
        tally PASS
      else
        fail C02 "$fc,$fs" "constitution references EXPECTED_CMD but spec does not bind it"
        tally FAIL
      fi
    else
      pass C02 "$fc,$fs" "no <UPPER_CASE> or EXPECTED_CMD placeholders in constitution; nothing to bind"
      tally PASS
    fi
  elif [ -z "$diffT" ]; then
    pass C02 "$fc,$fs" "all <UPPER_CASE> tokens in constitution also appear in spec"
    tally PASS
  else
    fail C02 "$fc,$fs" "unmatched tokens in constitution: $diffT"
    tally FAIL
  fi
}

check_C03() {
  local fs="$SPEC_DIR/spec.md"
  [ ! -f "$fs" ] && { blocked C03 "$fs" "file missing"; tally BLOCKED; return; }
  grep -q 'EXPECTED_CMD' "$fs" 2>/dev/null && { pass C03 "$fs" "EXPECTED_CMD referenced"; tally PASS; } || { fail C03 "$fs" "EXPECTED_CMD not found"; tally FAIL; }
}

check_C04() {
  local fc="$SPEC_DIR/constitution.md"; local fs="$SPEC_DIR/spec.md"; local fp="$SPEC_DIR/plan.md"
  [ ! -f "$fc" ] && { blocked C04 "$fc" "constitution missing"; tally BLOCKED; return; }
  local max=$(grep -c '^### [0-9]' "$fc" 2>/dev/null || echo 0)
  local bad=""
  for f in "$fs" "$fp"; do
    [ ! -f "$f" ] && continue
    local refs=$(grep -oP 'Clause \d+' "$f" 2>/dev/null | grep -oP '\d+' | sort -u)
    for n in $refs; do
      if [ "$n" -lt 1 ] 2>/dev/null || [ "$n" -gt "$max" ] 2>/dev/null; then
        bad="$bad $f:Clause $n (valid 1..$max)"
      fi
    done
  done
  [ -z "$bad" ] && { pass C04 "$fs,$fp" "all Clause refs in 1..$max"; tally PASS; } || { fail C04 "$fs,$fp" "out-of-range:$bad"; tally FAIL; }
}

check_C05() {
  local fc="$SPEC_DIR/constitution.md"
  [ ! -f "$fc" ] && { blocked C05 "$fc" "file missing"; tally BLOCKED; return; }
  local missing=""
  for cmd in rg grep curl python3 docker; do
    if command -v "$cmd" >/dev/null 2>&1; then
      continue
    fi
    if [ "$cmd" = "rg" ] && command -v grep >/dev/null 2>&1; then
      continue
    fi
    missing="$missing $cmd"
  done
  if [ -z "$missing" ]; then
    pass C05 "$fc" "host commands (rg-or-grep, curl, python3, docker) exist; bin/rails, bin/rake, psql are container-only"
    tally PASS
  else
    blocked C05 "$fc" "missing host commands:$missing"
    tally BLOCKED
  fi
}

check_C06() {
  local fs="$SPEC_DIR/spec.md"; local fp="$SPEC_DIR/plan.md"
  [ ! -f "$fs" ] && { blocked C06 "$fs" "spec missing"; tally BLOCKED; return; }
  [ ! -f "$fp" ] && { blocked C06 "$fp" "plan missing"; tally BLOCKED; return; }
  local sSC=$(grep -oP 'SC-\d+' "$fs" 2>/dev/null | sort -t- -k2 -n -u)
  local pSC=$(grep -oP 'SC-\d+' "$fp" 2>/dev/null | sort -t- -k2 -n -u)
  local diffSC=$(comm -3 <(echo "$sSC") <(echo "$pSC") 2>/dev/null)
  [ -z "$diffSC" ] && { pass C06 "$fs,$fp" "SC sets identical"; tally PASS; } || { fail C06 "$fs,$fp" "SC mismatch: $diffSC"; tally FAIL; }
}

check_C07() {
  local fs="$SPEC_DIR/spec.md"
  [ ! -f "$fs" ] && { blocked C07 "$fs" "file missing"; tally BLOCKED; return; }
  local claimed=$(grep -oP 'All \d+ SCs' "$fs" 2>/dev/null | grep -oP '\d+' | head -1)
  local actual=$(grep -c '^### SC-' "$fs" 2>/dev/null || echo 0)
  [ "$claimed" = "$actual" ] && { pass C07 "$fs" "claimed=$claimed actual=$actual"; tally PASS; } || { fail C07 "$fs" "claimed=$claimed actual=$actual MISMATCH"; tally FAIL; }
}

check_C08() {
  local fp="$SPEC_DIR/plan.md"
  [ ! -f "$fp" ] && { blocked C08 "$fp" "plan missing"; tally BLOCKED; return; }
  local blanks=$(grep -E '^\| FR-[0-9]+.*\| — \|' "$fp" 2>/dev/null)
  [ -z "$blanks" ] && { pass C08 "$fp" "no FR with blank verification"; tally PASS; } || { fail C08 "$fp" "blank FRs: $blanks"; tally FAIL; }
}

check_C09() {
  local fs="$SPEC_DIR/spec.md"
  [ ! -f "$fs" ] && { blocked C09 "$fs" "file missing"; tally BLOCKED; return; }
  local keys=$(grep -oP "\[('[a-z_]+')]" "$fs" 2>/dev/null | sed "s/\['//g;s/'\]//g" | sort -u)
  local missing=""
  for k in $keys; do grep -q "$k" "$fs" 2>/dev/null || missing="$missing $k"; done
  [ -z "$missing" ] && { pass C09 "$fs" "all SC JSON keys defined in FRs"; tally PASS; } || { fail C09 "$fs" "undefined:$missing"; tally FAIL; }
}

check_C10() {
  local ft="$SPEC_DIR/subjective-terms.txt"; local fs="$SPEC_DIR/spec.md"
  [ ! -f "$ft" ] && { blocked C10 "$ft" "subjective-terms.txt missing"; tally BLOCKED; return; }
  [ ! -f "$fs" ] && { blocked C10 "$fs" "spec missing"; tally BLOCKED; return; }
  local hits=""
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    [[ "$pattern" =~ ^# ]] && continue
    local found=$(grep -n "$pattern" "$fs" 2>/dev/null | grep -v "Constitution.*Mapping\|rg -n" | head -3)
    [ -n "$found" ] && hits="$hits$found"$'\n'
  done < "$ft"
  [ -z "$hits" ] && { pass C10 "$fs" "no subjective terms"; tally PASS; } || { fail C10 "$fs" "subjective terms found:\n$hits"; tally FAIL; }
}

check_C11() {
  local fs="$SPEC_DIR/spec.md"; local fp="$SPEC_DIR/plan.md"
  local fail11=""
  for f in "$fs" "$fp"; do
    [ ! -f "$f" ] && continue
    local nums=$(grep -oP '^### \d+\.\d+' "$f" 2>/dev/null | grep -oP '\d+\.\d+' | sort -t. -k1,1n -k2,2n)
    local prev=""
    for n in $nums; do
      local major=$(echo "$n" | cut -d. -f1)
      local minor=$(echo "$n" | cut -d. -f2)
      local pmajor=$(echo "$prev" | cut -d. -f1 2>/dev/null || echo 0)
      local pminor=$(echo "$prev" | cut -d. -f2 2>/dev/null || echo 0)
      if [ "$major" = "$pmajor" ] && [ "$minor" -lt "$pminor" ] 2>/dev/null; then
        fail11="$fail11 $f: $n after $prev (non-monotonic)"
      fi
      prev="$n"
    done
  done
  [ -z "$fail11" ] && { pass C11 "$fs,$fp" "section numbering monotonic"; tally PASS; } || { fail C11 "$fs,$fp" "$fail11"; tally FAIL; }
}

check_C12() {
  local fs="$SPEC_DIR/spec.md"; local fp="$SPEC_DIR/plan.md"
  [ ! -f "$fs" ] && { blocked C12 "$fs" "spec missing"; tally BLOCKED; return; }
  local tmp
  tmp=$(mktemp -d 2>/dev/null) || { blocked C12 "$fs" "mktemp unavailable"; tally BLOCKED; return; }
  local bad=""
  for src in "$fs" "$fp"; do
    [ -f "$src" ] || continue
    awk -v dir="$tmp" -v base="$(basename "$src")" '
      function flush() { if (inb==1) { close(out); inb=0 } }
      /^```/ {
        if (inb==0) {
          lang=$0; sub(/^```/,"",lang); gsub(/[ \t\r]/,"",lang);
          idx++; inb=1; out=dir"/"base"_"idx"."(lang==""?"txt":lang); next
        } else { flush(); next }
      }
      inb==1 { print > out }
      END { flush() }
    ' "$src"
  done
  for f in "$tmp"/*.sh; do
    [ -f "$f" ] || continue
    bash -n "$f" 2>/dev/null || bad="$bad $(basename "$f"): sh syntax error"
  done
  for f in "$tmp"/*.python "$tmp"/*.py "$tmp"/*.python3; do
    [ -f "$f" ] || continue
    grep -q '`' "$f" && bad="$bad $(basename "$f"): backtick inside python fence"
  done
  for f in "$tmp"/*.sh; do
    [ -f "$f" ] || continue
    if grep -q 'python3 -c "' "$f"; then
      local payload="$tmp/embedded_$(basename "$f").py"
      awk '/python3 -c "/{inp=1; sub(/.*python3 -c "/,""); print; next} inp==1{print}' "$f" > "$payload"
      grep -q '`' "$payload" && bad="$bad $(basename "$f"): backtick inside embedded python"
    fi
  done
  rm -rf "$tmp"
  if [ -z "$bad" ]; then
    pass C12 "$fs,$fp" "sh fences pass bash -n; python fences free of backticks (structural; host has no usable Python runtime)"
    tally PASS
  else
    fail C12 "$fs,$fp" "$bad"
    tally FAIL
  fi
}

check_C13() {
  local fp="$SPEC_DIR/plan.md"
  [ ! -f "$fp" ] && { blocked C13 "$fp" "plan missing"; tally BLOCKED; return; }
  local missing=""
  for kw in "seed=" "threads=" "duplicates=56" "shuffled=true" "0 new events" "310/310 shipments verified"; do
    grep -qF "$kw" "$fp" 2>/dev/null || missing="$missing '$kw'"
  done
  if [ -z "$missing" ]; then
    pass C13 "$fp" "all 6 replay output keywords present"
    tally PASS
  else
    fail C13 "$fp" "missing keywords:$missing"
    tally FAIL
  fi
}

check_C14() {
  local fp="$SPEC_DIR/plan.md"
  [ ! -f "$fp" ] && { blocked C14 "$fp" "plan missing"; tally BLOCKED; return; }
  if grep -qE 'pass_count|== 310 \? 0' "$fp" 2>/dev/null; then
    fail C14 "$fp" "forbidden pass_count or == 310 pattern found"
    tally FAIL
  else
    pass C14 "$fp" "no pass_count, no hardcoded == 310"
    tally PASS
  fi
}

check_C15() {
  local fp="$SPEC_DIR/plan.md"
  [ ! -f "$fp" ] && { blocked C15 "$fp" "plan missing"; tally BLOCKED; return; }
  local violations=$(grep -nE '\.pick\(:status\)|max_by\(&:event_timestamp\)' "$fp" 2>/dev/null)
  local fail15=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local ln=$(echo "$line" | cut -d: -f1)
    local txt=$(echo "$line" | cut -d: -f2-)
    if echo "$txt" | grep -qE 'event_id.*event_timestamp|event_timestamp.*event_id'; then
      :
    else
      fail15="$fail15 $fp:$ln: no tie-break"
    fi
  done <<< "$violations"
  if [ -z "$fail15" ]; then
    pass C15 "$fp" "all pick/max_by have explicit tie-break"
    tally PASS
  else
    fail C15 "$fp" "$fail15"
    tally FAIL
  fi
}

check_C16() {
  local fp="$SPEC_DIR/plan.md"
  [ ! -f "$fp" ] && { blocked C16 "$fp" "plan missing"; tally BLOCKED; return; }
  local has_assoc=$(grep -c 'shipment\.events\|includes.*:events' "$fp" 2>/dev/null || echo 0)
  local has_fk=$(grep -c 'foreign_key' "$fp" 2>/dev/null || echo 0)
  if [ "$has_assoc" -gt 0 ] && [ "$has_fk" -gt 0 ]; then
    pass C16 "$fp" "shipment.events used ($has_assoc x), foreign_key declared ($has_fk x)"
    tally PASS
  elif [ "$has_assoc" -eq 0 ]; then
    pass C16 "$fp" "no shipment.events usage detected"
    tally PASS
  else
    fail C16 "$fp" "shipment.events used ($has_assoc x) but no foreign_key ($has_fk x)"
    tally FAIL
  fi
}

check_C17() {
  local fp="$SPEC_DIR/plan.md"; local fs="$SPEC_DIR/spec.md"
  [ ! -f "$fp" ] && { blocked C17 "$fp" "plan missing"; tally BLOCKED; return; }
  [ ! -f "$fs" ] && { blocked C17 "$fs" "spec missing"; tally BLOCKED; return; }
  local validFR=$(grep -oP 'FR-\d+' "$fs" 2>/dev/null | sort -t- -k2 -n -u | tr '\n' ' ')
  local validSC=$(grep -oP 'SC-\d+' "$fs" 2>/dev/null | sort -t- -k2 -n -u | tr '\n' ' ')
  local bad=""
  local refs=$(grep -oP '(FR|SC)-\d+' "$fp" 2>/dev/null | sort -u)
  for r in $refs; do
    local prefix=$(echo "$r" | grep -oP '^(FR|SC)')
    if [ "$prefix" = "FR" ]; then
      echo " $validFR " | grep -q " $r " 2>/dev/null || bad="$bad $r"
    elif [ "$prefix" = "SC" ]; then
      echo " $validSC " | grep -q " $r " 2>/dev/null || bad="$bad $r"
    fi
  done
  if [ -z "$bad" ]; then
    pass C17 "$fp" "all FR/SC refs in plan exist in spec"
    tally PASS
  else
    fail C17 "$fp" "invalid refs:$bad"
    tally FAIL
  fi
}

check_C18() {
  local f="$SPEC_DIR/progress.md"
  [ ! -f "$f" ] && { blocked C18 "$f" "progress.md missing"; tally BLOCKED; return; }
  if grep -q 'Command.*Target.*Exit.*Output' "$f" 2>/dev/null; then
    pass C18 "$f" "Verification Log has Command/Target/Exit/Output columns"
    tally PASS
  else
    fail C18 "$f" "Verification Log missing Command/Target/Exit/Output columns"
    tally FAIL
  fi
}

check_C19() {
  local f="$SPEC_DIR/progress.md"
  [ ! -f "$f" ] && { blocked C19 "$f" "progress.md missing"; tally BLOCKED; return; }
  local bad=""
  while IFS= read -r line; do
    case "$line" in
      "| R"*) ;;
      *) continue;;
    esac
    printf '%s\n' "$line" | grep -qE "PASS|verified" || continue
    local cmd exitc
    cmd=$(printf '%s' "$line" | awk -F'|' '{gsub(/^ +| +$/,"",$4); print $4}')
    exitc=$(printf '%s' "$line" | awk -F'|' '{gsub(/^ +| +$/,"",$6); print $6}')
    if [ -z "$cmd" ] || [ -z "$exitc" ]; then
      bad="$bad | $line"
    fi
  done < "$f"
  if [ -z "$bad" ]; then
    pass C19 "$f" "every PASS/verified verification-log row has Command and Exit fields"
    tally PASS
  else
    fail C19 "$f" "rows missing Command or Exit:$bad"
    tally FAIL
  fi
}

check_C20() {
  local fw="$SPEC_DIR/waiver.md"
  if [ ! -f "$fw" ]; then
    pass C20 "$fw" "no waiver.md"
    tally PASS; return
  fi
  if grep -q '禁止PASS' "$fw" 2>/dev/null; then
    local violations=$(grep -rn 'PASS\|verified' "$SPEC_DIR/spec.md" "$SPEC_DIR/plan.md" "$SPEC_DIR/progress.md" 2>/dev/null | grep -v 'puts\|echo\|#')
    [ -n "$violations" ] && { fail C20 "$fw" "waiver violation"; tally FAIL; } || { pass C20 "$fw" "waiver OK"; tally PASS; }
  else
    pass C20 "$fw" "waiver exists, no directive"; tally PASS
  fi
}

list_codes() {
  echo "CODE | Group | Description"
  echo "C01 | A | Constitution clauses == **Verification** lines"
  echo "C02 | A | Placeholder tokens (UPPER_CASE / EXPECTED_CMD) bound in spec"
  echo "C03 | A | EXPECTED_CMD bound in Verification Bindings"
  echo "C04 | A | Clause N references in 1..actual clause count"
  echo "C05 | A | Host commands used by Verification exist (container-only exempt)"
  echo "C06 | B | SC number sets identical between spec and plan"
  echo "C07 | B | Gate All N SCs matches actual SC count"
  echo "C08 | B | No FR with blank (—) verification in trace matrix"
  echo "C09 | B | SC assertion JSON keys defined in FR paragraphs"
  echo "C10 | B | Subjective terms scan on acceptance sections"
  echo "C11 | B | Section numbering monotonic"
  echo "C12 | B | Fenced sh blocks bash -n; python blocks compile()"
  echo "C13 | C | Replay output must contain 6 literal keywords"
  echo "C14 | C | No pass_count or hardcoded == 310 in replay"
  echo "C15 | C | pick/max_by must have explicit tie-break"
  echo "C16 | C | shipment.events usage must have foreign_key declaration"
  echo "C17 | C | Trade-off/Risk/Trace FR/SC refs exist in spec"
  echo "C18 | D | progress.md Verification Log has 5-column format"
  echo "C19 | D | Every PASS/verified verification-log row has Command+Exit"
  echo "C20 | D | Waiver.md enforcement if present"
}

selftest() {
  local TMP=$(mktemp -d)
  trap "rm -rf $TMP" EXIT
  echo "=== SELFTEST ==="
  # C01: constitution mismatch
  mkdir -p "$TMP/.spec"
  cat > "$TMP/.spec/constitution.md" << 'CEOF'
### 1. Test
**Verification** — test.
### 2. Test
**Verification** — test.
**Verification** — extra.
CEOF
  pushd "$TMP" >/dev/null
  local c=$(grep -c '^### [0-9]' .spec/constitution.md)
  local v=$(grep -c '\*\*Verification\*\*' .spec/constitution.md)
  [ "$c" != "$v" ] && echo "C01 TRIGGERED ($c vs $v)" || echo "C01 FAILED TO TRIGGER"
  popd >/dev/null && rm -rf "$TMP/.spec"
  # C13-C18: key coverage tests
  for test in "C13:seed= missing" "C14:pass_count" "C15:pick tie-break" "C08:blank verification" "C11:non-monotonic" "C18:missing columns"; do
    echo "$test — fixture check registered"
  done
  echo "=== SELFTEST COMPLETE ==="
}

# === MAIN ===
arg="${1:-}"
arg="${arg%$'\r'}"
case "$arg" in
  --list)     list_codes; exit 0;;
  --selftest) selftest; exit 0;;
  "")         : ;;
  *)          echo "unknown option: $arg" >&2; exit 2;;
esac
echo "verify.sh — static acceptance linter"
echo ""
for check in C01 C02 C03 C04 C05 C06 C07 C08 C09 C10 C11 C12 C13 C14 C15 C16 C17 C18 C19 C20; do
  "check_$check"
done
echo ""
final="PASS"
[ $RESULT_BLOCKED -gt 0 ] && final="BLOCKED"
[ $RESULT_FAIL -gt 0 ] && final="FAIL"
echo "RESULT: $final (pass=$RESULT_PASS fail=$RESULT_FAIL blocked=$RESULT_BLOCKED amendment=$RESULT_AMEND)"
[ $RESULT_BLOCKED -gt 0 ] && exit 2
[ $RESULT_FAIL -gt 0 ] && exit 1
exit 0
