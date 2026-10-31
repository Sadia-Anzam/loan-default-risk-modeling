# SQL Layer — Dataset Construction & Data Quality

This directory documents how the analytical dataset was constructed from transactional
loan data. The SQL examples in this repository are sanitized methodological
representations; they do not expose production schemas, identifiers, or business codes.

## Pipeline overview

```text
Supporting feature inputs
        |
        v
Eligible loan population
        |
        v
Early-life observation boundary
        |
        v
Transaction and provision processing
        |
        v
Loan-level behavioral features
        |
        v
Final analytical dataset
        |
        v
Data-quality review and documented exclusions
```

## Source-work inventory

The original development work falls into the following groups.

### 1. Final dataset-construction pipeline

**Public file planned:** `final_dataset/01_analytical_dataset_pipeline.sql`

The final version of the dataset procedure is the v4 iteration. It supersedes the
earlier base, v2, and v3 versions.

Its main stages include:

- defining the eligible loan population using the study's disbursement and
  one-third-lifecycle criteria;
- excluding selected out-of-scope populations before feature construction;
- identifying the transaction/provision state at the observation boundary;
- deriving early missed-installment and overdue measures;
- constructing monthly and general overdue calculations;
- attaching geographic/demographic hierarchy information;
- assembling the loan-level modeling table;
- adding supporting savings-related aggregates where applicable;
- creating indexes for downstream joins and retrieval.

The one-third lifecycle boundary is a methodological control: predictors must be
based on information available by the intended prediction point.

### 2. Supporting feature procedures

**Public files planned:**

- `supporting/01_member_history_features.sql`
- `supporting/02_identity_duplication_features.sql`

These procedures prepare additional information used to enrich the modeling dataset.

The member-history procedure calculates member-level historical loan/provision and
pass-due information. The identity-duplication procedure normalizes identity values
and derives duplication indicators/counts.

These are supporting feature sources, not alternative versions of the main dataset
pipeline.

### 3. Historical development versions

The base, v2, and v3 dataset procedures are earlier iterations of the final v4
pipeline. They are useful for understanding how the population definition,
transaction processing, and feature construction evolved.

They are not presented as separate current pipeline stages in this public repository.
A concise research decision log should describe meaningful changes without publishing
the old production SQL.

An earlier behavioral table-construction script is also historical development
material: it demonstrates initial transaction-derived missed-collection and savings
features, but it is not the final dataset procedure.

### 4. Data-quality investigation and rectification

**Public files planned:**

- `data_quality/01_transaction_rectification.sql`
- `data_quality/02_analytical_dataset_quality_filters.sql`
- `data_quality/03_installment_and_duration_diagnostics.sql`
- `data_quality/04_collection_date_investigation.sql`
- `data_quality/discrepancy_analysis.md`

The supplied cleaning and investigation scripts cover several distinct issues:

- portfolio-status transitions and status-history rectification;
- settlement/status anomalies;
- disbursement-date corrections;
- repayment-frequency changes;
- missing monthly provision records;
- late-settlement handling;
- office/project/group transfers;
- collection-date and target-date discrepancies;
- installment-count versus collection/target-count mismatches;
- loan-duration extensions and voucher-related overdue changes;
- consecutive missed-collection-date investigation.

The discrepancy report records four concrete cases involving missing collection dates,
missing provision records, missing regular collection provisions, and target amounts
appearing on non-installment collection dates.

These cases should be described as data-quality findings. A case investigation does
not, by itself, prove that every record with a similar pattern is invalid.

## Important distinction: source cleaning vs analytical exclusion

Some scripts modify or filter source/intermediate transaction data. Others remove
records from the analytical modeling population after the final dataset has been
assembled.

The public documentation should preserve that distinction:

- **source rectification:** correct or scope transaction history before feature
  calculation;
- **analytical exclusion:** remove loans from the modeling population when the
  available history is not sufficiently reliable for the study definition;
- **diagnostic analysis:** identify and quantify possible inconsistencies without
  automatically changing the data.

## Public release rules

Before publishing any SQL implementation:

1. Replace every production table, column, procedure, schema, and function name.
2. Remove member, loan, office, project, and other internal identifiers.
3. Remove credentials, hostnames, internal paths, and proprietary codes.
4. Generalize business-specific exclusion values and operational statuses.
5. Review comments: comments can disclose sensitive implementation details too.
6. Keep only logic that can be explained and safely represented with a generic schema.

The public scripts should be short, human-readable, and commented only where a
non-obvious analytical decision needs context. The original SQL remains private.

## Execution note

The sanitized SQL examples are intended to communicate methodology. They are not
drop-in scripts for the company's database and may require a generic demonstration
schema to execute.
