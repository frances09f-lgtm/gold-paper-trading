# Additional Oro/Sona paper-terminal requirements

Source: owner WhatsApp message October9,2026 09:55:33 IST, message identifier wamid.HBgMOTE5NTI5ODQzNDE0FQIAEhggQUMyNEYzNjFEMkU1NzM4NkM2MUUzMjQ4NjRFOTRGQjUA. Full tail relayed by main09:55:58. Requirements record, not an implemented-feature claim.

## 7. Spread, slippage and swap

These are the trading costs your app must calculate.

- Spread: Difference between the buy price (ask) and sell price (bid). It creates an immediate cost when a position opens.
- Slippage: Difference between the expected execution price and the actual fill price.
- Swap: Overnight financing charge or credit, if applicable. It can vary by instrument, broker and holding day.

Example: Gold's bid is $4,200.00 and ask is $4,200.30. If you buy 1 oz at the ask and immediately close at the bid, your gross trading loss is $0.30, before other charges.

Important for Oro: If you calculate P&L using actual bid/ask execution prices, don't subtract the spread a second time. That would double-count the cost.

## 8. What to implement in Oro

1. Live market prices: Track bid, ask, spread and last update time.
2. Order execution: Buy/sell, quantity, entry fill, slippage and rejected orders.
3. Live P&L: Recalculate unrealized profit/loss using the correct closing-side price.
4. Risk management: Stop loss, take profit, margin requirements and insufficient-funds checks.
5. Account calculations: Balance, equity, used margin, free margin and margin level.
6. Automatic closing: Trigger SL/TP from executable prices, record the closing fill and update the balance once.
7. Trade history: Store entry/exit prices, quantity, gross P&L, costs and net P&L.
8. Safety controls: Maximum daily loss, position limits, alerts and configurable margin-call/stop-out rules.

## 9. Rules for correct calculations

- Keep calculations at full precision; round only displayed values.
- Use decimal-safe arithmetic for prices, quantities and money.
- Deduct trading costs exactly once.
- When a trade closes, move its net P&L into the balance exactly once.
- Use configurable contract size, leverage and margin rules rather than hardcoding one broker's settings.
- If your app converts USD profit into INR, use a defined USD/INR conversion rate and show the conversion separately.
- Clearly label Oro as a paper-trading simulator if orders are simulated rather than sent to a broker.

One key detail remains: your actual trading platform may use a different gold contract size or quantity unit. Confirm its instrument specifications before matching Oro's calculations to it.

## Implementation gap notes

Current source has bid/ask-side helpers and optional adverse slippage, but double arithmetic and estimated margin hardcoded1:500. No claim that current implementation meets decimal-safe accounting, swap, configurable broker rules or liquidation. Broker specs/quantity semantics remain unresolved; never infer a broker identity or bind paper calculations to one. No live trading authorized; Friday remains informational only. Backend balance-close atomicity must be validated separately before shipping new accounting.
