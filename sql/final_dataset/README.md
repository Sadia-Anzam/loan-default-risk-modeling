# Final Analytical Dataset Pipeline

`01_analytical_dataset_pipeline.sql` is a sanitized, generic-schema representation
of the final v4 workflow.

It shows the major analytical stages: eligibility, early-life snapshot selection,
transaction-derived behavior, overdue and missed-payment features, geography,
savings, overdue episodes, consecutive missed collections, policy diagnostics,
and outcome attachment.

The source schema, operational codes, internal identifiers and exact production
implementation are intentionally not reproduced. This script is a methodological
example and requires a compatible demonstration schema before it can run.

**Important:** the target is represented as a validated binary outcome source.
The production status-to-target mapping must be reviewed separately before any
public example claims to reproduce it exactly.
