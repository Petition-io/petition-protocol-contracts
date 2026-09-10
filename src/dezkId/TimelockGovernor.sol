// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title TimelockGovernor
 * @dev Time-delayed governor for the deZK protocol's IssuerRegistry.
 *
 * WHY THIS EXISTS
 * ---------------
 * IssuerRegistry.addIssuer / removeIssuer can be called by a "governor" address.
 * If that governor were a single key (or even a plain multisig), a compromised key
 * could instantly remove every trusted issuer and invalidate every live attestation
 * that Petition.io's PTNR token, DAO, and quadratic funding rely on.
 *
 * The fix (per the ERC-3643 and ICP architecture research): route ALL issuer
 * changes through a TimelockController. Every change must be:
 *   1. Proposed by an authorized proposer (the deZK DAO / multisig)
 *   2. Wait through MIN_DELAY (48 hours) — gives protocols time to react
 *   3. Executed by anyone after the delay
 *   4. Cancellable by a guardian during the delay window (emergency brake)
 *
 * HANDOFF FLOW
 * ------------
 *   1. Deploy TimelockGovernor(proposers, executors, admin)
 *   2. On IssuerRegistry, the owner calls setGovernor(address(thisTimelock))
 *   3. From then on, issuer changes go: DAO proposes → 48h wait → execute
 *   4. IssuerRegistry owner can still act as the emergency owner until ownership
 *      itself is transferred to the timelock or a DAO multisig.
 *
 * This is a thin wrapper around OpenZeppelin's audited TimelockController. We add
 * no custom logic — only a named deployment with deZK's recommended delay so the
 * configuration is explicit and self-documenting on-chain.
 */
contract TimelockGovernor is TimelockController {

    /// @dev Recommended minimum delay for issuer governance actions: 48 hours.
    ///      Matches the "48-hour delay on removeIssuer" requirement from the
    ///      ERC-3643 decentralization blueprint. The actual delay is set at
    ///      deploy time via the constructor; this constant documents the intended value.
    uint256 public constant RECOMMENDED_MIN_DELAY = 48 hours;

    /**
     * @param minDelay   Minimum seconds between proposal and execution (use 48 hours = 172800).
     * @param proposers  Addresses allowed to schedule actions (the deZK DAO / multisig).
     * @param executors  Addresses allowed to execute after the delay.
     *                   Pass [address(0)] to allow anyone to execute (open execution).
     * @param admin      Optional bootstrap admin that can grant/revoke roles.
     *                   Pass address(0) for full self-administration (most decentralized);
     *                   the timelock then governs its own roles via timelocked proposals.
     */
    constructor(
        uint256          minDelay,
        address[] memory proposers,
        address[] memory executors,
        address          admin
    ) TimelockController(minDelay, proposers, executors, admin) {}
}