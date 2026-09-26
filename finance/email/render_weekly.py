"""Renders the weekly budget email (HTML) from the JSON that app_weekly_report returns.

    python3 render_weekly.py report.json > email.html

Email clients ignore most CSS, so the layout is tables with inline styles, 600px wide, light
background, system fonts. Colours follow the app: blue = within budget, orange = over.
"""
import json
import sys
from datetime import date
from html import escape

NAVY, GOLD, INK, MUTED, LINE, TRACK, BG = "#0E1B2E", "#C9A24B", "#15171A", "#5B5F64", "#E3E0D8", "#ECE9E2", "#F4F2ED"
BLUE, ORANGE, ORANGE_TEXT, GREEN_TEXT = "#2A6CC4", "#C2571A", "#A8430F", "#1C7147"
FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"
APP_URL = "https://ijasali.github.io/CsSalesTracker/finance/app/"


def money(n, cents=True):
    n = float(n)
    s = f"${abs(n):,.2f}" if cents else f"${abs(n):,.0f}"
    return ("−" if n < 0 else "") + s


def bar(pct, over):
    """A 10px progress bar made of table cells (works in Outlook and Gmail)."""
    fill = max(0, min(100, round(pct)))
    color = ORANGE if over else BLUE
    cells = f'<td width="{fill}%" style="background:{color};height:10px;font-size:0;line-height:0;border-radius:5px">&nbsp;</td>' if fill else ""
    if fill < 100:
        cells += f'<td style="height:10px;font-size:0;line-height:0">&nbsp;</td>'
    return (f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0" '
            f'style="background:{TRACK};border-radius:5px;border-collapse:separate"><tr>{cells}</tr></table>')


def cat_row(c, days_left):
    budget, spent = float(c["budget"]), float(c["spent"])
    pct = spent / budget * 100 if budget else 0
    over = spent > budget
    left = budget - spent
    note = (f'<span style="color:{ORANGE_TEXT};font-weight:700">{money(-left)} over</span>' if over
            else f'<span style="color:{INK};font-weight:700">{money(left)} left</span>'
            + (f'<span style="color:{MUTED}"> · {money(left / days_left, cents=False)}/day</span>' if days_left and left > 0 else ""))
    return f'''
<tr><td style="padding:12px 0 4px;font:600 15px {FONT};color:{INK}">{escape(c["name"])}</td>
    <td align="right" style="padding:12px 0 4px;font:13px {FONT};color:{MUTED};white-space:nowrap">{money(spent, False)} of {money(budget, False)} · <b style="color:{ORANGE_TEXT if over else INK}">{round(pct)}%</b></td></tr>
<tr><td colspan="2">{bar(pct, over)}</td></tr>
<tr><td colspan="2" style="padding:4px 0 8px;font:13px {FONT}">{note}</td></tr>'''


def section(title, body, sub=""):
    return f'''
<tr><td style="padding:0 24px 16px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#FFFFFF;border-radius:14px">
<tr><td style="padding:20px 20px 8px"><div style="font:700 17px {FONT};color:{INK}">{title}</div>{f'<div style="font:13px {FONT};color:{MUTED};padding-top:2px">{sub}</div>' if sub else ""}</td></tr>
<tr><td style="padding:0 20px 14px">{body}</td></tr></table></td></tr>'''


def render(r):
    start, end = date.fromisoformat(r["week_start"]), date.fromisoformat(r["week_end"])
    month_name = end.strftime("%B")
    days_left, month_days = int(r["days_left"]), int(r["month_days"])
    cats = r["budgets"]
    total_b = sum(float(c["budget"]) for c in cats)
    total_s = sum(float(c["spent"]) for c in cats)
    left = total_b - total_s
    pct = total_s / total_b * 100 if total_b else 0
    elapsed = (month_days - days_left) / month_days * 100
    over_cats = sorted([c for c in cats if float(c["spent"]) > float(c["budget"])],
                       key=lambda c: float(c["spent"]) - float(c["budget"]), reverse=True)
    ok_cats = [c for c in cats if float(c["spent"]) <= float(c["budget"])]
    week, prev = float(r["week_spent"]), float(r["prev_week_spent"])

    if left >= 0:
        headline = f"{money(left)} left in the budget"
        pace = ("On pace" if pct <= elapsed + 3 else "Spending faster than the month") + f" · {days_left} day{'s' if days_left != 1 else ''} to go"
        head_color = INK
    else:
        headline = f"{money(-left)} over budget"
        pace = f"{days_left} day{'s' if days_left != 1 else ''} left in {month_name}"
        head_color = ORANGE_TEXT
    diff = week - prev
    week_line = (f"{money(-diff, False)} less than the week before ({money(prev, False)})" if diff < 0
                 else f"{money(diff, False)} more than the week before ({money(prev, False)})")

    date_range = f"{start.strftime('%b')} {start.day} – {end.strftime('%b')} {end.day}, {end.year}"
    summary = f'''
<tr><td style="padding:0 24px 16px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#FFFFFF;border-radius:14px">
<tr><td style="padding:22px 20px 6px;font:600 13px {FONT};color:{MUTED};text-transform:uppercase;letter-spacing:.6px">{month_name} budget so far</td></tr>
<tr><td style="padding:0 20px;font:700 30px {FONT};color:{head_color}">{headline}</td></tr>
<tr><td style="padding:4px 20px 14px;font:14px {FONT};color:{MUTED}">{pace}</td></tr>
<tr><td style="padding:0 20px">{bar(pct, pct > 100)}</td></tr>
<tr><td style="padding:6px 20px 0;font:13px {FONT};color:{MUTED}">Spent <b style="color:{INK}">{money(total_s)}</b> of {money(total_b)} ({round(pct)}%) · {round(elapsed)}% of the month gone</td></tr>
<tr><td style="padding:16px 20px 20px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr>
  <td width="33%" style="padding:10px 12px;background:{BG};border-radius:10px"><div style="font:12px {FONT};color:{MUTED}">This week</div><div style="font:700 16px {FONT};color:{INK}">{money(week, False)}</div></td>
  <td width="8"></td>
  <td width="33%" style="padding:10px 12px;background:{BG};border-radius:10px"><div style="font:12px {FONT};color:{MUTED}">Income in {end.strftime('%b')}</div><div style="font:700 16px {FONT};color:{GREEN_TEXT}">{money(r["income"], False)}</div></td>
  <td width="8"></td>
  <td width="33%" style="padding:10px 12px;background:{BG};border-radius:10px"><div style="font:12px {FONT};color:{MUTED}">Kept so far</div><div style="font:700 16px {FONT};color:{GREEN_TEXT if float(r["income"]) >= float(r["month_spent"]) else ORANGE_TEXT}">{money(float(r["income"]) - float(r["month_spent"]), False)}</div></td>
</tr></table><div style="font:13px {FONT};color:{MUTED};padding-top:10px">This week: {week_line}.</div></td></tr>
</table></td></tr>'''

    body = ""
    if over_cats:
        rows = "".join(cat_row(c, days_left) for c in over_cats)
        body += section(f"Over budget ({len(over_cats)})",
                        f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0">{rows}</table>')
    if ok_cats:
        rows = "".join(cat_row(c, days_left) for c in ok_cats)
        body += section(f"Within budget ({len(ok_cats)})",
                        f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0">{rows}</table>')
    if r.get("week_top"):
        rows = "".join(f'''<tr><td style="padding:9px 0;border-top:1px solid {LINE};font:14px {FONT};color:{INK}">{escape(t["payee"] or "")}
<div style="font:12px {FONT};color:{MUTED}">{date.fromisoformat(t["d"]).strftime("%a %b")} {date.fromisoformat(t["d"]).day} · {escape(t["acct"])}</div></td>
<td align="right" style="padding:9px 0;border-top:1px solid {LINE};font:700 14px {FONT};color:{INK};white-space:nowrap">{money(t["amt"])}</td></tr>''' for t in r["week_top"])
        body += section("Biggest spends this week", f'<table role="presentation" width="100%" cellpadding="0" cellspacing="0">{rows}</table>')
    if r.get("unbudgeted"):
        items = " · ".join(f'{escape(u["name"])} {money(u["spent"], False)}' for u in r["unbudgeted"])
        body += section("Spending with no budget", f'<div style="font:14px {FONT};color:{INK}">{items}</div>')

    return f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light only"><title>Zasvia Finance · weekly budget</title></head>
<body style="margin:0;padding:0;background:{BG}">
<div style="display:none;max-height:0;overflow:hidden">{escape(headline)} · {week_line}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:{BG}"><tr><td align="center" style="padding:24px 8px">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="width:100%;max-width:600px">
<tr><td style="padding:0 24px 16px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:{NAVY};border-radius:14px">
<tr><td style="padding:20px"><div style="font:700 20px Georgia,'Times New Roman',serif;color:#FFFFFF;letter-spacing:.3px">Zasvia <span style="color:{GOLD}">Finance</span></div>
<div style="font:13px {FONT};color:#C9CCD1;padding-top:4px">Weekly budget check · {date_range}</div></td></tr></table></td></tr>
{summary}{body}
<tr><td align="center" style="padding:8px 24px 8px"><a href="{APP_URL}" style="display:inline-block;background:{NAVY};color:#FFFFFF;text-decoration:none;font:700 15px {FONT};padding:13px 28px;border-radius:12px">Open Zasvia Finance</a></td></tr>
<tr><td align="center" style="padding:12px 24px 24px;font:12px {FONT};color:{MUTED}">Sent every Sunday to Ijas and Sherifa. Budgets and amounts come from your household database;<br>change a budget in the app under Budgets → Budget setting.</td></tr>
</table></td></tr></table></body></html>'''


if __name__ == "__main__":
    print(render(json.load(open(sys.argv[1]) if len(sys.argv) > 1 else sys.stdin)))
