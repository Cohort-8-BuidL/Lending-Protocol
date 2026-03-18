# Lending Protocol

A modular decentralized lending protocol written in **Solidity** using **Foundry**, featuring collateralized borrowing, interest rate models, and liquidation logic.

This project demonstrates the architecture of a DeFi lending market where users can deposit collateral, borrow assets, repay loans, and where under-collateralized positions can be liquidated to maintain system solvency.

---

## Overview

The protocol enables:

- Collateral deposits
- Borrowing against collateral
- Interest accrual on outstanding debt
- Liquidation of unhealthy positions
- Secure smart-contract-based lending markets

The system is designed to follow best practices used in production DeFi protocols while remaining simple enough for educational exploration.

---

## Tech Stack

Core technologies used in this project:

- Solidity smart contracts
- Foundry development framework
- Prettier for formatting
- Solhint for Solidity linting
- ESLint for JavaScript/TypeScript tooling
- Husky Git hooks
- lint-staged for pre-commit formatting
- pnpm package manager

---

## Project Architecture

Example structure:

```
lending-protocol/
├── .husky/                  # Git hooks (pre-commit, pre-push, etc.)
├── lib/                     # External dependencies, libraries, contracts
├── src/                     # Solidity smart contracts
├── test/                    # Foundry unit/integration tests
├── scripts/                 # Deployment, interaction, or helper scripts
├── .vscode/                 # VSCode editor settings (formatting, linting)
├── .gitignore               # Ignored files (artifacts, cache, node_modules)
├── .lintstagedrc             # Pre-commit staged file formatting rules
├── .prettierrc               # Prettier configuration
├── .solhint.json             # Solidity linter rules
├── package.json              # Node dependencies & scripts (linting, formatting)
├── foundry.toml              # Foundry project config
├── README.md                 # Project overview & instructions
└── CONTRIBUTING.md           # Contribution guidelines

---

## Key Concepts

### Collateralized Lending

Users deposit assets as collateral and can borrow another asset against it. Borrow limits depend on collateral value and loan-to-value ratios.

### Interest Rate Model

Borrowed assets accumulate interest over time based on protocol-defined parameters.

### Liquidation

If a borrower's collateral falls below the required threshold, their position can be liquidated to protect the protocol.

---

## Installation

Clone the repository:

```

git clone https://github.com/Cohort-8-BuidL/Lending-Protocol.git
cd Lending-Protocol

```

Install JavaScript dependencies:

```

pnpm install

```

Install Foundry (if not installed):

```

curl -L https://foundry.paradigm.xyz | bash
foundryup

```

---

## Development

Build the contracts:

```

forge build

```

Run tests:

```

forge test

```

Run tests with verbose output:

```

forge test -vvvv

```

Format contracts:

```

forge fmt

```

---

## Linting

Run JavaScript/TypeScript linting:

```

pnpm lint

```

Auto-fix issues:

```

pnpm lint:fix

```

Run Solidity linting:

```

pnpm solhint

```

---

## Formatting

Format all files:

```

pnpm format

```

Check formatting:

```

pnpm format:check

```

Formatting is also enforced automatically through Git hooks.

---

## Git Hooks

This project uses **Husky** to enforce repository standards.

Hooks include:

* Pre-commit formatting checks
* Pre-push branch protection
* Lint-staged file formatting

These checks ensure code quality and prevent accidental pushes to protected branches.

---

## Branch Protection

The `main` branch is protected.

Only authorized maintainers are allowed to push directly to `main`.

All contributions must be made through pull requests.

---

## Contributing

We welcome contributions.

Please read **CONTRIBUTING.md** before opening a pull request.

---

## Security

Smart contract security is critical in DeFi systems.

If you discover a vulnerability, please report it responsibly rather than opening a public issue.

---

## License

MIT License
```
