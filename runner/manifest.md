# Post-implement steps manifest.
# Each non-comment, non-blank line is a prompt path resolved against
# consumer root (runner/) first, then framework root (.formann/runner/steps/).
#
# Formann dogfoods the unrolled iterate pattern: a full review and gate, one
# fix round on its findings, then a fresh review and gate. The gate promotes
# to done only when no Critical finding remains, so an issue whose first gate
# found a Critical gets one unattended attempt at fixing it before it is left
# for a human; a clean first gate ends the walk at done and the rest never runs.
review-and-gate.md
fix.md
review-and-gate.md
