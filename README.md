# Zeitgeist 🔮

Pay $0.25 in ETH or CLAWD on Base mainnet, get an AI-synthesized cultural snapshot of any group — meme image plus written analysis pulled from real-time web signals.

- **Live frontend**: TBD (deployed to IPFS via bgipfs)
- **Smart contract**: [`ZeitgeistPayment` on Base](https://basescan.org/address/0x45fAeA3de5f9B6D4758EA1907eDc6B127E26081F) — verified
- **Networks**: Base mainnet (chain id 8453)

## How it works

1. User connects a wallet, types a cultural group ("Jets fans", "TikTok traders", "Crypto Twitter"), and chooses ETH or CLAWD as payment.
2. The payment is sent to `ZeitgeistPayment` on Base. The contract converts the $0.25 USD price into ETH using a Chainlink ETH/USD feed (with sequencer-uptime and staleness/bound checks), or accepts a fixed CLAWD amount.
3. The contract emits `QueryPaid(user, groupName, amount, isClawd)`. The frontend reads the resulting tx hash and polls a Vercel-hosted `/api/zeitgeist?txHash=...&groupName=...` endpoint.
4. The backend verifies the on-chain event, fans out to Brave Search for real-time signal, runs synthesis through GPT-4o, and generates a meme image with DALL-E. The result is cached in Vercel KV for 24h keyed by `(txHash, groupName)`.
5. The user gets back a meme image, a one-line mood headline, a few bullet signals, and a TLDR.

## Architecture

```
Browser (IPFS-hosted Next.js static export)
   │
   │ writeContract: queryETH / queryCLAWD on Base
   ▼
ZeitgeistPayment.sol  ──emits──►  QueryPaid event
   │
   │ tx hash + groupName
   ▼
GET /api/zeitgeist  (Vercel runtime)
   │
   ├─► Vercel KV cache (24h TTL)
   ├─► Base RPC (verify QueryPaid via getTransactionReceipt)
   ├─► Brave Search API
   └─► OpenAI GPT-4o + DALL-E 3
```

The frontend is a **static Next.js export hosted on IPFS** (no API routes shipped). The API stub at `app/api/zeitgeist/route.ts` returns a 503 in the static build; the real implementation lives in `app/api/zeitgeist/pipeline.ts` and runs on a separate Vercel deployment.

## Two-deployment setup

1. **Static frontend** → IPFS (bgipfs).
   ```bash
   cd packages/nextjs
   NEXT_PUBLIC_IPFS_BUILD=true yarn build
   npx bgipfs upload out
   ```
2. **Backend API** → Vercel.
   - Set the env vars listed in `packages/nextjs/.env.example` under "Backend".
   - Replace the stub `app/api/zeitgeist/route.ts` with a thin wrapper that calls `runZeitgeistPipeline` from `pipeline.ts` (and remove `dynamic = "force-static"`).
   - Deploy to Vercel: `yarn vercel --prod`.
   - Point `NEXT_PUBLIC_API_URL` in the IPFS build to the Vercel URL and rebuild the static site.

## Local development

```bash
yarn install
yarn chain          # local Anvil
yarn deploy         # deploy ZeitgeistPayment locally
yarn start          # frontend at http://localhost:3000
```

## Contract details

`ZeitgeistPayment` is `Ownable2Step` and `ReentrancyGuard`. ETH conversion uses Chainlink ETH/USD on Base with:
- Sequencer-uptime feed check (rejects calls during a recent L2 outage + 1h grace)
- 1h staleness window on the price update
- Min/max answer bounds (`$1` to `$1,000,000`)
- 1% slippage buffer accepted on `queryETH`; the contract refunds the excess.

Owner-only withdrawals (`withdraw`, `withdrawCLAWD`, `withdrawETH`) and `setQueryPriceCLAWD` for adjusting the CLAWD price.

## Built with

Scaffold-ETH 2 (Foundry flavor) · Next.js 15 · wagmi · viem · RainbowKit · DaisyUI · OpenZeppelin Contracts.
