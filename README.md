# brew-dependent-shard-e2e

Local Next.js GUI to visualize Homebrew dependent-test sharding behavior.

## Run locally

Requirements:
- Node.js 20+
- Ruby 3+
- Internet access (first run fetches `https://formulae.brew.sh/api/formula.json`)

Commands:

```bash
npm install
npm run dev
```

Then open: [http://localhost:3000](http://localhost:3000)

## What it does

- Lets you pick a formula and shard controls (`max-runners`, `min-per-runner`, runner tag, include build/test edges).
- Runs a Ruby backend simulation from `scripts/simulate_sharding.rb` through `app/api/simulate/route.js`.
- Shows:
  - discovered dependents
  - runner-compatible dependents
  - computed shard count
  - shard membership and feature-load distribution
  - estimated duplicate work in "core-compat" mode.

## Notes

- This app is local-only (not deployed).
- Formula API responses are cached for 1 hour at `tmp/formula-cache.json`.
