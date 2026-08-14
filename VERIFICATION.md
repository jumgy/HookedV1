# HookedV1 — Uniswap Labs verification pack

## Hook details (checkboxes)
- [x] **My hook uses a delta flag** (`afterSwapReturnDelta`)
- [ ] My deployment address starts with 0x91
- [ ] Major token pairs — **no** (USDG + test token)
- [ ] None of the above

## Chains
- **Robinhood Chain** · chain id **`4663`**

## Name
```
HookedV1
```

## Description
```
Uniswap v4 hook for gated MainToken/USDG listings. Owner-gated pool init, LP via configured position manager, exact-input swaps only. Fixed fees via afterSwapReturnDelta: buy 10% of Main out (6.5% rewards in MainToken, 2% USDG jackpot + 1.5% USDG ops after one nested convert); sell 3.5% of USDG out (2% jackpot, 1.5% ops). Notifies IFeeCollector on buys and IJackpot on buy/sell with buyId attribution. Immutable fee rates; owner can update collector/jackpot/ops addresses. No prize payout logic in the hook.
```

## Deployed addresses (Robinhood Chain mainnet)

| Role | Address |
|------|---------|
| **HookedV1** | [`0x46C4455F65Da6d0E8Bb0274E257F99733ddE2544`](https://robinhoodchain.blockscout.com/address/0x46C4455F65Da6d0E8Bb0274E257F99733ddE2544) |
| MainToken (TTFA) | [`0x900CB66B4B418BC6EA610e9b96319d933fFe0A12`](https://robinhoodchain.blockscout.com/address/0x900CB66B4B418BC6EA610e9b96319d933fFe0A12) |
| USDG (quote) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| FeeCollector (mock) | `0x851Dcca04E50937Edd21E4093E968F42b2784Ed9` |
| Jackpot (mock) | `0x9E4a4a464e4dEbE59b3382BD58dAF88F022501b4` |
| LiquidityRouter | `0x0349A9f6D3b74289E157Dd5e7c645aD9E67e590a` |
| SwapRouter | `0xf9636e6D09a59e5E2E0ffcda1fe2Ba15a2BcdaDC` |
| Owner | `0xF5830af934cb05B81F935B932C01060fe6De29C1` |
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |

**PoolId:** `0x12d060f5e55b84e5882955278c090ad43ac43b48148401bbb8959d671f40ba75`

**Smoke test:** LP seeded (`liquidityDelta=1e6` ≈ 0.95 USDG) · penny buy `50_000` USDG → `42734` Main · half sold · `buyCount=1`

**Blockscout:** HookedV1 source verified.

## Public source
https://github.com/jumgy/hook (push `src/core/HookedV1.sol` + base/interfaces/libraries)
