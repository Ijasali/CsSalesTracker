# Personal finance tracker: sample design

Mobile screens (390 px wide) for a personal finance app that tracks income and expenses across
several bank accounts and credit cards, shows spending by category, and tracks monthly budgets.

The screens are Design canvas artboards (`project/*.dc.html`, laid out by `project/canvas.json`).
All figures are sample data for September 2026, and they add up across the screens.

| Screen | File | What it answers |
|---|---|---|
| Home | `Main.dc.html` | Net worth (bank and cash minus card dues), this month's income, spending and savings, budget progress with over-budget alerts, top categories, recent transactions |
| Accounts | `Accounts.dc.html` | Balance of every bank account and cash; for each credit card, the amount owed, limit used and due date |
| Insights | `Spending.dc.html` | Spending (or income) by category for the month, share of total, change from last month, and which account or card paid |
| Budgets | `Budgets.dc.html` | Spent against budget overall and per category, amount left, safe amount to spend per day, over-budget warnings |
| Transactions | `Transactions.dc.html` | Search and filter (expenses, income, transfers, account) with a daily total for each day |
| Add transaction | `AddTransaction.dc.html` | Expense, income or transfer; amount, category, account, date and note |

## Data model the design implies

- **accounts**: id, name, type (`savings` / `current` / `cash` / `credit_card`), last 4 digits,
  opening balance, credit limit and statement due day (cards only)
- **categories**: id, name, kind (`expense` / `income`)
- **transactions**: id, date, amount, kind (`expense` / `income` / `transfer`), account_id,
  to_account_id (transfers), category_id, payee, note
- **budgets**: month, category_id, limit

Balances and totals are calculated from transactions. A card payment is a transfer from a bank
account to the card, so it is not counted twice as spending. Net worth is the bank and cash
balances minus the amounts owed on cards.
