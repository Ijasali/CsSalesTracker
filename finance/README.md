# Household finance tracker: database, app and data entry

The app is `app/index.html` ("Manalody Money"). The same page runs two ways:

- **As a website** (GitHub Pages, any phone browser). Each person signs in with their own email and
  password (Supabase Auth). The page calls one database function per screen or action
  (`supabase/migrations/20260927000000_web_app_api.sql`, all named `app_*`) with the project's
  publishable key; row level security limits every login to its own household. Screenshots are
  read by the `read-screenshots` Edge Function (`supabase/functions/`), which calls the Claude API
  with the project's `ANTHROPIC_API_KEY` secret.
- **As a Claude artifact** (private, owner only). It calls the same functions through the viewer's
  Supabase connector (`execute_sql`) and reads screenshots with the artifact's `sample` capability,
  so it needs no API key.

### Who can get in

A login becomes a household member in one of two ways: its email matches a member's `email`
(Ijas's is set), or a member approves it from Home → person button → Household ("This is
Sherifa"). A login that is neither sees nothing. Everyone who is let in can see and change
everything.

### Setup (once)

1. GitHub → repository Settings → Pages: deploy from branch `claude/finance-tracking-app-design-gfkmse`,
   folder `/ (root)`. The app is then at `https://ijasali.github.io/CsSalesTracker/finance/app/`.
2. Supabase → Authentication → Sign In / Providers → Email: turn off **Confirm email**. (Supabase's
   built-in mailer only sends to the organisation's own team, so a confirmation email to anyone
   else never arrives.)
3. Supabase → Authentication → URL Configuration: set **Site URL** to the app's address.
4. Both people create their logins; Ijas approves Sherifa's. Then turn off **Allow new users to
   sign up** (Authentication → Sign In / Providers) so no one else can create a login.
5. Optional, for reading screenshots on the website: Supabase → Edge Functions → Secrets, add
   `ANTHROPIC_API_KEY` (from console.anthropic.com). Each batch of up to 5 screenshots costs about
   5–10 cents with Claude Opus 5.

The screens are designed in `../finance-design/`. This folder holds the Supabase database
(`supabase/migrations/`) and how transactions get into it without typing each one.

The schema is applied to the Supabase project `household-finance` (ca-central-1), separate from
`cybersquare-outreach`, and was also tested on a local Postgres 16.

## History imported from Money Manager

The previous app's export (2018-09 to 2026-09) was imported once, with `source = 'legacy'`:

- Every account in the export became an account (owner Ijas, Sherifa or joint; business accounts are
  kept but have `include_in_totals = false`). Accounts with no activity in 18 months are inactive.
- Its two-level categories became `categories` as they were.
- Expenses and income became transactions; each transfer (exported as a money-out row and a
  money-in row) became one pair sharing a `transfer_group_id`. Rows of $0.00 were skipped.
- Each row has `external_id = 'mm:<hash of its fields>:<n>'`, so importing a later export from the
  same app adds only new rows.
- The free-text notes (mostly merchant names) became `payee`. A payee that went to the same category
  at least 80% of the time, 3+ times, became a `category_rules` row (`origin = 'legacy'`). Merchants
  used for many categories (Costco, Walmart, Dollarama) have no rule and are left for review.

Checked after import: transaction count and total per account equal the export's, and monthly
category totals match the old app.

The export has no opening balances, so account balances are only right once each account gets a
real balance: a `balance_snapshots` row (investments, loans) or an `opening_balance` (bank accounts
and cards).

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
