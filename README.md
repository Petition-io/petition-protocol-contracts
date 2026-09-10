# Petition Protocol Contracts

Solidity contracts for **Petition.io** — on-chain petitions, user profiles, and time-delayed governance.

Built with [Foundry](https://book.getfoundry.sh/) and [OpenZeppelin](https://docs.openzeppelin.com/contracts) `v5`.

<p>
  <img alt="Solidity" src="https://img.shields.io/badge/Solidity-0.8.20-363636?logo=solidity&logoColor=white" />
  <img alt="Foundry" src="https://img.shields.io/badge/Foundry-Forge-000000?logo=ethereum&logoColor=white" />
  <img alt="OpenZeppelin" src="https://img.shields.io/badge/OpenZeppelin-v5.7-4E5EE4?logo=openzeppelin&logoColor=white" />
  <img alt="License" src="https://img.shields.io/badge/License-MIT-green" />
</p>

---

## Overview

This repository is the protocol layer for campaigns and profiles:

| Layer | What it does |
| --- | --- |
| **Core** | Campaign create/sign flow, fees, and petition lifecycle |
| **Profile** | Arweave-backed user profiles, signature versions, and campaign shares |
| **Governance** | 48-hour timelock so sensitive admin actions cannot be applied instantly |

```
User wallet
    │
    ├─► Profile            ← identity pointers, signature versions, shares
    │
    └─► PetitionCore       ← campaigns, signatures, fees, price feed
                │
                ▼
        TimelockGovernor   ← propose → 48h delay → execute
```

---

## Contracts

| Contract | Path | Role |
| --- | --- | --- |
| `PetitionCore` | [`src/core/PetitionCore.sol`](src/core/PetitionCore.sol) | Campaign create/sign flow, fees, Chainlink price feed, EIP-712, governance and relay executors. |
| `Profile` | [`src/core/Profile.sol`](src/core/Profile.sol) | Arweave-backed profile pointers, signature versions, campaign shares, and module authorization. |
| `TimelockGovernor` | [`src/timelock/TimelockGovernor.sol`](src/timelock/TimelockGovernor.sol) | Wrapper around OpenZeppelin `TimelockController`. Recommended delay: **48 hours**. |

---

## Getting started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`)
- Git (submodules: `forge-std`, `openzeppelin-contracts`)

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Install

```bash
git clone <this-repo>
cd petition-protocol-contracts
forge install
```

`forge install` pulls **forge-std** and **OpenZeppelin Contracts** into `lib/`.

---

## Build, test, deploy

### Build

```bash
forge build
```

### Test

```bash
forge test
forge test -vvv                       # traces
forge test --match-path test/core
forge test --match-contract ProfileTest
forge test --match-test test_ConstructorSetsOwner
```

| File | Coverage |
| --- | --- |
| [`test/core/PetitionCore.t.sol`](test/core/PetitionCore.t.sol) | Owner, price feed, governance / relay executors |
| [`test/core/Profile.t.sol`](test/core/Profile.t.sol) | Owner, governance executor, modules, profile updates |
| [`test/timelock/TimelockGovernor.t.sol`](test/timelock/TimelockGovernor.t.sol) | Roles, 48h delay, schedule → execute |

### Format and gas

```bash
forge fmt
forge snapshot
```

### Local node

```bash
anvil
```

### Deploy scripts

Scripts live in [`script/`](script/). Put secrets in a local `.env` (gitignored) or export them in your shell.

| Script | Contract | Required env |
| --- | --- | --- |
| `script/DeployPetitionCore.s.sol` | `PetitionCore` | `PRIVATE_KEY`, `PRICE_FEED` · optional `INITIAL_OWNER` |
| `script/DeployProfile.s.sol` | `Profile` | `PRIVATE_KEY` · optional `INITIAL_OWNER` |
| `script/DeployTimelockGovernor.s.sol` | `TimelockGovernor` | `PRIVATE_KEY` · optional `PROPOSER`, `EXECUTOR`, `ADMIN`, `MIN_DELAY` |

**PetitionCore** (`PRICE_FEED` is a Chainlink AggregatorV3 feed):

```bash
export PRICE_FEED=0x...

forge script script/DeployPetitionCore.s.sol:DeployPetitionCore \
  --rpc-url $RPC_URL \
  --broadcast
```

**Profile:**

```bash
forge script script/DeployProfile.s.sol:DeployProfile \
  --rpc-url $RPC_URL \
  --broadcast
```

**Timelock** (defaults: proposer = deployer, executor = anyone, delay = 48h):

```bash
forge script script/DeployTimelockGovernor.s.sol:DeployTimelockGovernor \
  --rpc-url $RPC_URL \
  --broadcast
```

Dry-run (no broadcast) is the default if you omit `--broadcast`.

---

## Layout

```
src/
  core/          PetitionCore, Profile
  timelock/      TimelockGovernor
test/
  core/
  timelock/
script/          Foundry deploy scripts
lib/             forge-std, openzeppelin-contracts
foundry.toml
```

---

## Tooling

| Command | Purpose |
| --- | --- |
| `forge build` | Compile |
| `forge test` | Run tests |
| `forge script …` | Deploy / simulate |
| `forge fmt` | Format Solidity |
| `anvil` | Local chain |
| `cast` | RPC / encoding / calls |

Docs: [Foundry Book](https://book.getfoundry.sh/) · [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts)

---

## License

This project is licensed under the **MIT License**. See [`LICENSE`](LICENSE).

All first-party Solidity sources include `SPDX-License-Identifier: MIT`.

| Component | License |
| --- | --- |
| Petition protocol contracts (`src/`, `test/`, `script/`) | [MIT](LICENSE) |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | MIT |
| [forge-std](https://github.com/foundry-rs/forge-std) | MIT OR Apache-2.0 |
