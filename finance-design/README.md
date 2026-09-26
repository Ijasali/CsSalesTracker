# Personal finance tracker: sample design

Mobile screens (390 px wide) for a personal finance app that tracks income and expenses across
several bank accounts and credit cards, shows spending by category, and tracks monthly budgets.

The screens are Design canvas artboards (`project/*.dc.html`, laid out by `project/canvas.json`).
All figures are sample data for September 2026, and they add up across the screens.

| Screen | File | What it answers |
|---|---|---|
| Home | `Main.dc.html` | Household net worth split into Me and Wife (bank and cash plus assets minus card dues), this month's income, spending and savings, budget progress with over-budget alerts, top categories, recent transactions |
| Accounts | `Accounts.dc.html` | Switch between Everyone, Me and Wife. Net worth for that person, balance of every bank account and cash, assets (mutual funds, PPF, fixed deposit, gold) with current value and gain, and for each credit card the amount owed, limit used and due date |
| Insights | `Spending.dc.html` | Spending (or income) by category for the month, share of total, change from last month, and which account or card paid |
| Budgets | `Budgets.dc.html` | Spent against budget overall and per category, amount left, safe amount to spend per day, over-budget warnings |
| Transactions | `Transactions.dc.html` | Search and filter (expenses, income, transfers, account) with a daily total for each day |
| Add transaction | `AddTransaction.dc.html` | Expense, income or transfer; amount, category, account, date and note |

## Data model the design implies

- **people**: id, name (Me, Wife)
- **accounts**: id, owner (a person), name, type (`savings` / `current` / `cash` / `credit_card` /
  `mutual_fund` / `ppf` / `fixed_deposit` / `gold`), last 4 digits, opening balance, credit limit
  and statement due day (cards only)
- **asset_values**: account_id, date, current value (asset accounts only; entered by hand or fetched)
- **categories**: id, name, kind (`expense` / `income`)
- **transactions**: id, date, amount, kind (`expense` / `income` / `transfer`), account_id,
  to_account_id (transfers, including money moved into an asset), category_id, payee, note
- **budgets**: month, category_id, limit

Balances and totals are calculated from transactions. A card payment is a transfer from a bank
account to the card, so it is not counted twice as spending. Money moved into an asset (a SIP, a
PPF deposit) is also a transfer: it counts as saving, not spending. An asset's worth is its latest
`asset_values` entry, and its gain is that value minus the money transferred in. Net worth is bank
and cash balances plus asset values minus the amounts owed on cards, for each person or for the
household.
