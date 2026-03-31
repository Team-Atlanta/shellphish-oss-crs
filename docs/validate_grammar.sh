#!/bin/bash
# Validate Grammar pipeline end-to-end.
# Usage: ./validate_grammar.sh <container_prefix>
# Example: ./validate_grammar.sh crs_compose_1774886529c0-crs-shellphish-grammar
set -u

P="${1:?Usage: validate_grammar.sh <container_prefix>}"
NEO="docker exec ${P}_neo4j-1 cypher-shell -u neo4j -p helloworldpdt"
PASS=0; FAIL=0; WARN=0

check() {
    local label="$1" result="$2" expected="$3"
    if echo "$result" | grep -qE "$expected"; then
        echo "  ✅ $label"
        PASS=$((PASS+1))
    else
        echo "  ❌ $label  (got: $(echo "$result" | head -1 | cut -c1-80))"
        FAIL=$((FAIL+1))
    fi
}

check_warn() {
    local label="$1" result="$2" expected="$3"
    if echo "$result" | grep -qE "$expected"; then
        echo "  ✅ $label"
        PASS=$((PASS+1))
    else
        echo "  ⚠️  $label  (may need more time)"
        WARN=$((WARN+1))
    fi
}

echo "========================================"
echo "Grammar Pipeline Validation: $P"
echo "========================================"

echo ""
echo "--- R: Infrastructure ---"
CNT=$(docker ps --format '{{.Names}}' | grep -c "${P}")
check "R1  Container count (11)" "$CNT" "^11$"

R2=$(docker logs ${P}_entrypoint-1 2>&1 | grep "AFLPP_CPUS" | tail -1)
check "R2  Entrypoint CPU alloc" "$R2" "AFLPP_CPUS"

R3=$(docker logs ${P}_neo4j-1 2>&1 | grep "Started\." | tail -1)
check "R3  Neo4j started" "$R3" "Started"

R4=$(docker logs ${P}_codeql-server-1 2>&1 | grep "CodeQL server ready" | tail -1)
check "R4  CodeQL server ready" "$R4" "server ready"

R5=$(docker logs ${P}_codeql-server-1 2>&1 | grep "Database uploaded" | tail -1)
check "R5  CodeQL DB uploaded" "$R5" "uploaded"

R6=$(docker logs ${P}_ag-init-1 2>&1 | grep "PYTHON exiting" | tail -1)
check "R6  ag-init completed" "$R6" "PYTHON exiting"

R7=$($NEO "MATCH (f:CFGFunction) RETURN count(f) AS c" 2>/dev/null | tail -1)
check "R7  CFGFunction count > 0" "$R7" "[1-9]"

R8=$($NEO "MATCH ()-[r:DIRECTLY_CALLS]->() RETURN count(r) AS c" 2>/dev/null | tail -1)
check "R8  DIRECTLY_CALLS count > 0" "$R8" "[1-9]"

R9=$(docker logs ${P}_aflpp_fuzzer-1 2>&1 | grep "Fuzzing test case" | tail -1)
check "R9  AFL++ fuzzing" "$R9" "Fuzzing test case"

R10=$(docker logs ${P}_aflpp_fuzzer-1 2>&1 | grep -oP '\d+ crashes saved' | tail -1)
check_warn "R10 AFL++ crashes" "$R10" "[1-9]"

echo ""
echo "--- G: Grammar-Guy ---"
G1=$(docker logs ${P}_coverage_tracer-1 2>&1 | grep ".oss-fuzz-coverage_live.started" | head -1)
check "G1  Tracer buddy started" "$G1" "started"

G2=$(docker logs ${P}_grammar_guy-1 2>&1 | grep "Grammar-Guy starting" | head -1)
check "G2  Grammar-Guy started" "$G2" "Grammar-Guy starting"

G3=$(docker logs ${P}_grammar_guy-1 2>&1 | grep "Inferencing with o3" | head -1)
check "G3  LLM inference (o3)" "$G3" "Inferencing"

G5=$(docker logs ${P}_grammar_guy-1 2>&1 | grep "Found coverage" | head -1)
check "G5  Coverage found" "$G5" "Found coverage"

G6=$(docker logs ${P}_grammar_guy-1 2>&1 | grep "Grammar improved" | head -1)
check_warn "G6  Grammar improved" "$G6" "Grammar improved"

G7=$($NEO "MATCH (g:Grammar) RETURN count(g) AS c" 2>/dev/null | tail -1)
check "G7  Grammar in Neo4j > 0" "$G7" "[1-9]"

G8=$(docker logs ${P}_grammar_guy-1 2>&1 | grep "Cycle.*finished" | tail -1)
check_warn "G8  Multi-cycle" "$G8" "Cycle"

G9=$(docker logs ${P}_grammar_guy-1 2>&1 | grep "Synced.*files to FUZZER" | tail -1)
check_warn "G9  Seeds synced to AFL++" "$G9" "Synced"

G10=$(docker logs ${P}_grammar_guy-1 2>&1 | grep "uncovered_callable_function_pairs" | head -1)
check_warn "G10 Advanced strategy" "$G10" "uncovered_callable"

echo ""
echo "--- C: coverage-guy ---"
C1=$(docker logs ${P}_coverage_guy-1 2>&1 | grep "Coverage-Guy starting" | head -1)
check "C1  coverage-guy started" "$C1" "Coverage-Guy starting"

C2=$(docker logs ${P}_coverage_guy-1 2>&1 | grep "Build outputs downloaded" | head -1)
check "C2  Build outputs downloaded" "$C2" "downloaded"

C3=$(docker logs ${P}_coverage_tracer_covguy-1 2>&1 | grep ".oss-fuzz-coverage_live.started" | head -1)
check "C3  covguy tracer buddy started" "$C3" "started"

C5=$(docker logs ${P}_coverage_guy-1 2>&1 | grep "SEEDS_ALREADY_TRACED" | tail -1)
check_warn "C5  Seeds traced > 0" "$C5" "Size of the SEEDS_ALREADY_TRACED is: [1-9]"

C6=$($NEO "MATCH (h:HarnessInputNode) RETURN count(h) AS c" 2>/dev/null | tail -1)
check_warn "C6  HarnessInputNode > 0" "$C6" "[1-9]"

C7=$($NEO "MATCH (h:HarnessInputNode)-[:COVERS]->(f:CFGFunction) RETURN count(DISTINCT f) AS c" 2>/dev/null | tail -1)
check_warn "C7  HarnessInputNode COVERS > 0" "$C7" "[1-9]"

echo ""
echo "--- M: GrammarRoomba ---"
M1=$(docker logs ${P}_grammaroomba-1 2>&1 | grep "GrammarRoomba starting" | head -1)
check "M1  Roomba started" "$M1" "GrammarRoomba starting"

M2=$(docker logs ${P}_coverage_tracer_roomba-1 2>&1 | grep ".oss-fuzz-coverage_live.started" | head -1)
check "M2  Roomba tracer buddy started" "$M2" "started"

M3=$(docker logs ${P}_grammaroomba-1 2>&1 | grep "FunctionMetaStack.*Now contains" | tail -1)
check_warn "M3  FunctionMetaStack > 0" "$M3" "contains [1-9]"

M4=$(docker logs ${P}_grammaroomba-1 2>&1 | grep "Invoking.*check_grammar_coverage" | head -1)
check_warn "M4  LLM refinement invoked" "$M4" "check_grammar_coverage"

M5=$(docker logs ${P}_grammaroomba-1 2>&1 | grep "Coverage Report" | head -1)
check_warn "M5  Coverage report produced" "$M5" "Coverage Report"

M6=$(docker logs ${P}_grammaroomba-1 2>&1 | grep -E "improved coverage|fully covered" | head -1)
check_warn "M6  Refinement result" "$M6" "improved|covered"

echo ""
echo "--- N: Neo4j Final State ---"
N1=$($NEO "MATCH (n) RETURN labels(n) AS type, count(n) AS cnt ORDER BY cnt DESC" 2>/dev/null)
echo "  Neo4j nodes: $(echo "$N1" | grep -v "type, cnt" | tr '\n' ' ')"

N2=$($NEO "MATCH (n)-[r]->(m) RETURN type(r), count(*) ORDER BY count(*) DESC" 2>/dev/null)
echo "  Neo4j rels:  $(echo "$N2" | grep -v "type(r)" | tr '\n' ' ')"

N3=$($NEO "MATCH (h:HarnessInputNode)-[:COVERS]->(f:CFGFunction)<-[:COVERS]-(g:Grammar) RETURN count(DISTINCT f) AS overlap" 2>/dev/null | tail -1)
check_warn "N3  HarnessInput∩Grammar overlap > 0" "$N3" "[1-9]"

echo ""
echo "--- Budget ---"
echo "  Grammar-Guy: $(docker logs ${P}_grammar_guy-1 2>&1 | grep "Budget Usage" | tail -1 | grep -oP '\$[\d.]+ / \$[\d.]+')"
echo "  Roomba:      $(docker logs ${P}_grammaroomba-1 2>&1 | grep "Budget Usage" | tail -1 | grep -oP '\$[\d.]+ / \$[\d.]+')"

echo ""
echo "========================================"
echo "Results: ✅ $PASS passed, ❌ $FAIL failed, ⚠️  $WARN need more time"
echo "========================================"
