# blocked-passes fixture

Six issue timelines, each written twice: once as a local-markdown issue file
(`issues/<NN>-<slug>.md`) and once as the `gh issue view --json comments`
response the github-issues binding reads (`github/<NN>.json`). The two forms
carry the same comments in the same order.

`expected.tsv` holds the Blocked pass count both bindings' `blocked-passes`
must print for each issue: the number of `Blocked` comments since the latest
`Implementation` comment.

| NN | Timeline | Count |
|----|----------|-------|
| 01 | no comments | 0 |
| 02 | Implementation, Blocked, Review, Blocked | 2 |
| 03 | Implementation, then three Blocked (one same-day suffixed) | 3 |
| 04 | two Blocked, then a rework's new Implementation, then one Blocked | 1 |
| 05 | two Blocked, no Implementation comment | 2 |
| 06 | Blocked headings quoted in a code block or inline don't count | 1 |
