# Petition Protocol Contracts

Solidity contracts for **Petition.io** — on-chain petitions, user profiles, and **deZK** self-sovereign identity.

Built with [Foundry](https://book.getfoundry.sh/) and [OpenZeppelin](https://docs.openzeppelin.com/contracts) `v5`.

<p>
  <img alt="Solidity" src="https://img.shields.io/badge/Solidity-0.8.20-363636?logo=solidity&logoColor=white" />
  <img alt="Foundry" src="https://img.shields.io/badge/Foundry-Forge-000000?logo=ethereum&logoColor=white" />
  <img alt="OpenZeppelin" src="https://img.shields.io/badge/OpenZeppelin-v5.7-4E5EE4?logo=openzeppelin&logoColor=white" />
  <img alt="License" src="https://img.shields.io/badge/License-MIT-green" />
</p>

---

## Overview

This repository holds the protocol layer:

| Layer | What it does |
| --- | --- |
| **Core** | Campaigns, signatures, profiles, and petition lifecycle |
| **deZK Identity** | Per-user on-chain passports, claims, and issuer-backed verification |
| **Governance** | 48-hour timelock so issuer changes cannot be applied instantly |

A wallet owns a `DeZKIdentity`. Trusted issuers sign claims off-chain. The user stores those claims on their identity. `DeZKIdentityRegistry` is the check other contracts use: *is this wallet verified for this topic?*

```
User wallet
    │  MANAGEMENT key
    ▼
DeZKIdentity          ← ERC-734 keys + ERC-735 claims
    │  registerIdentity()
    ▼
DeZKIdentityRegistry  ← trusted issuer + valid sig + not expired
    │
    ▼
PetitionCore / Profile
```

Issuer add/remove on the registry is meant to go through `TimelockGovernor` (propose → 48h delay → execute).

---

## Contracts

### deZK Identity

| Contract | Path | Role |
| --- | --- | --- |
| `DeZKIdentity` | [`src/dezkId/DeZKIdentity.sol`](src/dezkId/DeZKIdentity.sol) | One contract per user. Key management (ERC-734), claims (ERC-735), and an ERC-725Y data store. |
| `DeZKIdentityRegistry` | [`src/dezkId/DeZKIdentityRegistry.sol`](src/dezkId/DeZKIdentityRegistry.sol) | Directory of identities. `isVerified(wallet, topic)` requires a registered identity, a valid claim, a trusted issuer, and a non-expired payload. |
| `TimelockGovernor` | [`src/dezkId/TimelockGovernor.sol`](src/dezkId/TimelockGovernor.sol) | Thin wrapper around OpenZeppelin `TimelockController`. Recommended delay: **48 hours**. |

**Claim data convention** (signed by the issuer):

```solidity
abi.encode(uint256 expiresAt, bytes32 payloadHash)
// expiresAt = unix seconds; 0 = never expires
```

Users self-register by proving they hold the identity’s `MANAGEMENT` key. No admin approval.

### Core

| Contract | Path | Role |
| --- | --- | --- |
| `PetitionCore` | [`src/core/PetitionCore.sol`](src/core/PetitionCore.sol) | Campaign create/sign flow, fees, Chainlink price feed, EIP-712, governance and relay executors. |
| `Profile` | [`src/core/Profile.sol`](src/core/Profile.sol) | Arweave-backed profile pointers, signature versions, campaign shares, and module authorization. |

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
forge test -vvv                  # traces
forge test --match-path test/dezkId
forge test --match-contract DeZKIdentityTest
forge test --match-test test_AddAndRemoveClaim
```

| File | Coverage |
| --- | --- |
| [`test/dezkId/DeZKIdentity.t.sol`](test/dezkId/DeZKIdentity.t.sol) | Management keys, claims, signatures, ERC-725Y data |
| [`test/dezkId/DeZKIdentityRegistry.t.sol`](test/dezkId/DeZKIdentityRegistry.t.sol) | Register / deregister, `isVerified`, expiry, untrusted issuer |
| [`test/dezkId/TimelockGovernor.t.sol`](test/dezkId/TimelockGovernor.t.sol) | Roles, 48h delay, schedule → execute |
| [`test/core/Profile.t.sol`](test/core/Profile.t.sol) | Owner, governance executor, modules, profile updates |
| [`test/core/PetitionCore.t.sol`](test/core/PetitionCore.t.sol) | Owner, price feed, governance / relay executors |

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
  dezkId/        DeZKIdentity, DeZKIdentityRegistry, TimelockGovernor
test/
  core/
  dezkId/
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
