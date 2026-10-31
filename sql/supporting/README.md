# Supporting Feature Generation

These scripts represent two supporting procedures used to enrich the loan-level
analytical dataset.

## 1. Member history

`01_member_history_features.sql` combines historical loan-provision information,
creates a fallback for closed loans without a matching provision record, and uses
window functions to calculate the member's prior maximum days past due and prior
loan count.

The window frame ends at `1 PRECEDING`, so the current loan is not included in its
own prior-history count. This is important for avoiding self-history contamination.

## 2. Identity quality

`02_identity_duplication_features.sql` normalizes identity-like values and derives
potential duplication indicators and branch-level patterns.

The public example deliberately does not preserve raw identity values. A match is
only a potential duplicate signal; it does not establish that records belong to
the same individual.

## Confidentiality and execution

All schemas, table names, fields and categories are generic placeholders. These
scripts illustrate the analytical logic and require a compatible demonstration
schema. They are not executable against the production database as supplied.
