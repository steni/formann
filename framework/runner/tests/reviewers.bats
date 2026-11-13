#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Prompt-text suite for the review steps and the reviewer agents (#22). The
# steps and agents are prompts a model follows, so no test runs them; these
# pin the contract a caller depends on: which agents a step dispatches, the
# sections it records, what blocks the gate, and what each reviewer reads.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  STEPS="$HERE/../steps"
  AGENTS="$HERE/../../agents"
}

# Print the numbered step of a prompt that starts with "<n>. **<title>.**",
# up to the next numbered step.
numbered_step() {
  awk -v start="$2. **$3" '
    index($0, start) == 1 { on = 1; print; next }
    on && /^[0-9]+\. \*\*/ { exit }
    on { print }
  ' "$1"
}

# === review-and-gate.md ====================================================

@test "review-and-gate dispatches review-issue and review-claims" {
  run -0 grep -F '`subagent_type`: `"review-issue"`' "$STEPS/review-and-gate.md"
  run -0 grep -F '`subagent_type`: `"review-claims"`' "$STEPS/review-and-gate.md"
}

@test "review-and-gate records the claims review under its own heading" {
  run -0 grep -F '## Claims review' "$STEPS/review-and-gate.md"
}

@test "review-and-gate's classify step blocks on a Critical from the claims review" {
  run -0 numbered_step "$STEPS/review-and-gate.md" 4 "Classify."
  assert_output --partial 'review-claims'
  assert_output --partial 'not shown'
  assert_output --partial '`blocked`'
}

@test "review-and-gate tells review-claims where the evidence lives" {
  run -0 grep -F 'Evidence block' "$STEPS/review-and-gate.md"
  run -0 numbered_step "$STEPS/review-and-gate.md" 3 "Run the claims review."
  assert_output --partial 'where the evidence lives'
}

# === review.md =============================================================

@test "review dispatches review-issue and review-claims" {
  run -0 grep -F '`subagent_type`: `"review-issue"`' "$STEPS/review.md"
  run -0 grep -F '`subagent_type`: `"review-claims"`' "$STEPS/review.md"
}

@test "review records the claims review under its own heading" {
  run -0 grep -F '## Claims review' "$STEPS/review.md"
}

@test "review's classify step counts a Critical from the claims review" {
  run -0 numbered_step "$STEPS/review.md" 4 "Classify."
  assert_output --partial 'review-claims'
  assert_output --partial '`blocked`'
}

# === gate.md ===============================================================

@test "gate classifies every section of the findings comment, the claims review included" {
  run -0 grep -F '## Claims review' "$STEPS/gate.md"
}

# === review-claims agent ===================================================

@test "review-claims agent exists under its own name" {
  run -0 grep -x 'name: review-claims' "$AGENTS/review-claims.md"
}

@test "review-claims gives each verdict its severity: not shown Critical, weakly shown Important" {
  run -0 grep -F '🔴 Critical' "$AGENTS/review-claims.md"
  run -0 grep -F '🟡 Important' "$AGENTS/review-claims.md"
  run -0 grep -iF 'not shown' "$AGENTS/review-claims.md"
  run -0 grep -iF 'weakly shown' "$AGENTS/review-claims.md"
}

@test "review-claims never reads the production code or the narrative" {
  run -0 grep -F 'Never read the production code' "$AGENTS/review-claims.md"
  run -0 grep -F "implementer's narrative" "$AGENTS/review-claims.md"
}

@test "review-claims takes an optional list of criteria for a delta gate" {
  run -0 grep -F 'Only these criteria' "$AGENTS/review-claims.md"
}

@test "review-claims names no project: it learns where evidence lives from its dispatcher" {
  run -0 grep -F '**Where the evidence lives**' "$AGENTS/review-claims.md"
  run -1 grep -E 'https?://|[a-z0-9-]+\.(net|com|io|org)\b' "$AGENTS/review-claims.md"
}

# === review-issue agent ====================================================

@test "review-issue makes a red-team pass over each entry point" {
  run -0 grep -F '**Red-team pass.**' "$AGENTS/review-issue.md"
  run -0 grep -F 'entry points it tried' "$AGENTS/review-issue.md"
}

@test "review-issue leaves claims against criteria to review-claims" {
  run -1 grep -F '**Evidence-check.**' "$AGENTS/review-issue.md"
  run -0 grep -F 'review-claims' "$AGENTS/review-issue.md"
}
