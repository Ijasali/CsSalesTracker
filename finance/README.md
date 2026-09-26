# Household finance tracker: database and data entry

The screens are designed in `../finance-design/`. This folder holds the Supabase database
(`supabase/migrations/`) and how transactions get into it without typing each one.

The schema has been applied to a local Postgres 16 and tested, but not yet to a Supabase project.
It will go into a new project of its own, separate from `cybersquare-outreach`.

## Tables

| Table | Holds |
|---|---|
| `households`, `household_members` | The household and its people (Me, Wife). A member can have a login or not. |
| `accounts` | Bank accounts, cards, TFSA/RRSP/GIC, the home and the mortgage. `owner_member_id` null = joint. |
| `categories` | Two levels: Home expenses → Mortgage, Hydro One, … |
| `transactions` | One row per transaction per account. Signed amounts: money out is negative. |
| `import_batches`, `import_rows` | Each file, email or screenshot read, and its rows waiting for review. |
| `category_rules` | "Description contains COSTCO → Groceries, shown as Costco". |
| `budgets` | Limit per category per month. |
| `balance_snapshots` | Known balances: investment and home values, mortgage balance, statement balances. |

Views: `account_balances` (current balance and money contributed for each account) and
`monthly_category_spending` (the numbers behind Insights and the 12-month category chart).

Transfers between your own accounts (card payments, money into a TFSA) are two rows sharing a
`transfer_group_id` and never count as spending. Row level security limits every table to members
of the household.

## Getting transactions in without typing them

Every source goes through the same steps: read the rows into `import_rows`, check for duplicates,
suggest a category, then import. Only rows that need a decision are shown for review.

| Source | How | Effort |
|---|---|---|
| Bank and card files | Download the CSV or QFX for each account from online banking (TD, RBC, EQ, Tangerine and Amex all offer it) and upload it. QFX files carry the bank's own id for each transaction, which makes duplicates impossible. | A few minutes a month; complete and reliable |
| Transaction alert emails | Turn on alerts for every purchase in each bank's app. A daily task reads new alerts from Gmail and adds them. | None after setup; covers purchases as they happen |
| Screenshots | Send screenshots of transaction lists; Claude reads them and adds them. | Seconds per screenshot; best for the odd account without a file or alerts |
| Previous app's spreadsheet | One-time import of past years. Its payee → category pairs become the first categorisation rules. | Once |

### Avoiding duplicates

1. **Same row imported twice** (the same file uploaded again, overlapping screenshots): each row
   gets a fingerprint of account, date, amount and cleaned description, plus a counter for
   identical rows within the same file. The database refuses a fingerprint it already has, so two
   real $2.15 coffees on one day are both kept, but re-uploading the file adds nothing.
2. **Same purchase from two sources** (an email alert on the 24th, the statement row on the 25th
   reading "COSTCO WHOLESALE W1234"): `find_possible_duplicates` finds the same account and amount
   within 3 days and scores how alike the descriptions are. A close match is merged automatically
   (the statement row replaces the alert); anything uncertain is shown for review.
3. **Both sides of a transfer** (a card payment appears as money out of chequing and money into the
   card): matched into one transfer instead of being counted as an expense.
4. **Something missing**: a statement balance saved in `balance_snapshots` is compared with the
   calculated balance, so a gap shows up.

### Detecting categories

1. **Rules first**: `match_category_rule` checks the household's rules (exact, starts with,
   contains, or a pattern; optionally only for one account or an amount range). Rules also clean
   up names ("TIM HORTONS #4417 TORONTO" → "Tim Hortons").
2. **Learning**: when you change a transaction's category by hand, a rule is saved automatically,
   so the same shop is right next time.
3. **Your history**: the spreadsheet from the previous app seeds rules from years of payees you
   already categorised.
4. **Claude for the rest**: a new payee with no rule gets a suggested category with a confidence
   score. Low-confidence suggestions are marked `needs_review` and appear in a review list.
