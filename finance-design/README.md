# Personal finance tracker: sample design

Mobile screens (390 px wide) for a household finance app in Canada (CAD). It tracks income and
expenses across both partners' bank accounts, credit cards, investments and mortgage, shows
spending by category with month-by-month history, and tracks monthly budgets.

The screens are Design canvas artboards (`project/*.dc.html`, laid out by `project/canvas.json`).
All figures are sample data for September 2026, and they add up across the screens. The Home
expenses category and its April–September totals follow a screenshot of the owner's current app.
Its breakdown for months before September, and its totals before April, are sample figures.

| Screen | File | What it answers |
|---|---|---|
| Home | `Main.dc.html` | Household net worth split into Me, Wife and Joint; bank, investments and home, and money owed; this month's income, spending and savings; budget progress with over-budget alerts; top categories; recent transactions |
| Accounts | `Accounts.dc.html` | Switch between Everyone, Me and Wife. Bank accounts, investments (TFSA, RRSP, GIC) and the home with value and gain, credit cards with amount owed, limit used and due date, and the mortgage (joint accounts show only under Everyone) |
| Insights | `Spending.dc.html` | Household spending (or income) by category for the month, share of total, change from last month, and which account or card paid. Tapping a category opens its history in place |
| Category history | `CategoryDetail.dc.html` | One category's total for each of the last 12 months as bars that scroll sideways (opens on the latest month; tap a month), change from the previous month and from the 12-month average, the category's budget, and its subcategories with share and amount |
| Budgets | `Budgets.dc.html` | Spent against budget overall and per category, amount left, safe amount to spend per day, over-budget warnings; each category links to its history |
| Transactions | `Transactions.dc.html` | Search and filter (expenses, income, transfers, person) with a daily total for each day |
| Add transaction | `AddTransaction.dc.html` | Expense, income or transfer; amount, category and subcategory, account (either partner's), transfer destination including investments, date and note |

## Data model the design implies

- **people**: id, name (Me, Wife); an account owned by both is `joint`
- **accounts**: id, owner (a person or joint), name, institution, type (`chequing` / `savings` /
  `credit_card` / `tfsa` / `rrsp` / `gic` / `property` / `mortgage`), last 4 digits, opening
  balance, credit limit and statement due day (cards), rate and renewal date (mortgage, GIC)
- **asset_values**: account_id, date, current value (investments and property; entered by hand or
  fetched)
- **categories**: id, name, parent_id (subcategories such as Mortgage or Hydro One under Home
  expenses), kind (`expense` / `income`)
- **transactions**: id, date, amount, kind (`expense` / `income` / `transfer`), account_id,
  to_account_id (transfers, including money moved into an investment), category_id, payee, note
- **budgets**: month, category_id, limit

Balances and totals are calculated from transactions. A card payment is a transfer from a bank
account to the card, so it is not counted twice as spending. Money moved into an investment (a
TFSA or RRSP contribution) is also a transfer: it counts as saving, not spending. An investment's
worth is its latest `asset_values` entry, and its gain is that value minus the money transferred
in. Net worth is bank balances plus investments and property minus card balances and the
mortgage, for each person, for joint items, or for the household.
