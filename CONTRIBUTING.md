# Contributing to Lending Protocol

Thank you for your interest in contributing.

This document describes the development workflow, contribution guidelines, and repository standards.

---

## Development Workflow

1. Fork the repository
2. Clone your fork locally
3. Create a new branch
4. Implement your changes
5. Run tests and formatting
6. Open a pull request

---

## Getting Started

Clone the repository:

```
git clone https://github.com/Cohort-8-BuidL/Lending-Protocol.git
cd Lending-Protocol
```

Install dependencies:

```
pnpm install
```

Install Foundry if needed:

```
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

---

## Branch Naming Convention

Branches should follow this format:

```
feature/<description>
fix/<description>
refactor/<description>
release/<version>
```

Examples:

```
feature/add-liquidation-logic
fix/interest-calculation
refactor/vault-architecture
```

---

## Commit Message Guidelines

Use clear and descriptive commit messages.

Recommended format:

```
feat: add borrowing logic
fix: correct collateral ratio calculation
test: add liquidation unit tests
refactor: simplify interest model
```

Commit types:

| Type     | Purpose               |
| -------- | --------------------- |
| feat     | New feature           |
| fix      | Bug fix               |
| refactor | Code improvement      |
| test     | Test changes          |
| docs     | Documentation updates |
| chore    | Maintenance tasks     |

---

## Pull Request Checklist

Before submitting a PR:

- Code compiles successfully
- Tests pass
- Formatting checks pass
- Linting checks pass
- Documentation updated if necessary

Example checklist:

```
- [ ] Contracts compile
- [ ] Tests pass
- [ ] Code formatted
- [ ] No unnecessary files committed
```

---

## Code Style

This repository enforces formatting and linting automatically.

Tools used:

- Prettier
- Solhint
- ESLint
- Husky
- lint-staged

Formatting runs automatically during commits.

---

## Testing

All core functionality should include tests.

Run tests:

```
forge test
```

Verbose mode:

```
forge test -vvvv
```

Tests should cover:

- expected behavior
- edge cases
- failure conditions
- security considerations

---

## Smart Contract Guidelines

Follow best practices for Solidity development:

- Avoid unnecessary external calls
- Use checks-effects-interactions pattern
- Validate all inputs
- Prevent reentrancy
- Write extensive tests

---

## Security

Security is critical in DeFi protocols.

Avoid:

- unchecked external calls
- unbounded loops
- insecure arithmetic
- improper access control

Always test edge cases.

---

## Code Reviews

All pull requests are reviewed before merging.

The review process may include:

- architecture evaluation
- security review
- gas optimization suggestions
- test coverage validation

---

## Protected Branches

The `main` branch is protected.

Direct pushes are restricted and enforced via Git hooks and repository settings.

All changes must go through pull requests.

---

## Reporting Issues

If you find bugs or vulnerabilities:

1. Check existing issues
2. Provide clear reproduction steps
3. Include relevant logs or error messages

Security vulnerabilities should be reported privately.

---

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
