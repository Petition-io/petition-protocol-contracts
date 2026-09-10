// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IDeZKIdentity.sol";
import "./interfaces/IIssuerRegistry.sol";

/**
 * @title DeZKIdentityRegistry
 * @dev The directory + verification authority for deZK identities.
 *
 * This is where a claim becomes *trustworthy*. The identity contract only proves a
 * claim's signature is authentic; this registry decides whether a wallet is actually
 * verified for a topic by checking ALL of:
 *   1. the wallet has a registered identity
 *   2. that identity holds a claim for the topic
 *   3. the claim signature still recovers to its issuer   (IDeZKIdentity.isClaimValid)
 *   4. the claim has not expired                          (deZK data convention, below)
 *   5. the issuer is currently trusted                    (IssuerRegistry)
 *
 * Self-registration (the decentralization win over ERC-3643): a user registers their
 * own identity by proving they hold its MANAGEMENT key. No admin approval needed.
 *
 * ── deZK CLAIM DATA CONVENTION ────────────────────────────────────────────────
 * A deZK claim's `data` field MUST be laid out as:
 *     abi.encode(uint256 expiresAt, bytes32 payloadHash)
 * so the first 32-byte word is the expiry (unix seconds; 0 = never expires).
 * Because the issuer signs over `data`, expiresAt is tamper-proof — changing it
 * invalidates the signature. The backend's ERC-735 signing path MUST encode it
 * this way so signatures verify here.
 */
contract DeZKIdentityRegistry {

    uint256 public constant MANAGEMENT = 1;

    // ── Custom Errors ──────────────────────────────────────────────────────────

    error ZeroAddress();
    error NotIdentityOwner();
    error AlreadyRegistered();
    error NotRegistered();

    // ── Events ─────────────────────────────────────────────────────────────────

    event IdentityRegistered(address indexed wallet, address indexed identity);
    event IdentityDeregistered(address indexed wallet, address indexed identity);

    // ── Storage ────────────────────────────────────────────────────────────────

    IIssuerRegistry public immutable issuerRegistry;
    mapping(address => address) private _identityOf; // wallet => identity contract

    // ── Constructor ────────────────────────────────────────────────────────────

    constructor(address issuerRegistry_) {
        if (issuerRegistry_ == address(0)) revert ZeroAddress();
        issuerRegistry = IIssuerRegistry(issuerRegistry_);
    }

    // ── Self-Registration ────────────────────────────────────────────────────────

    /**
     * @dev Registers the caller's identity. The caller must hold a MANAGEMENT key
     *      on `identity`, proving ownership. No admin approval needed.
     */
    function registerIdentity(address identity) external {
        if (identity == address(0))                  revert ZeroAddress();
        if (_identityOf[msg.sender] != address(0))   revert AlreadyRegistered();

        bytes32 keyHash = keccak256(abi.encode(msg.sender));
        if (!IDeZKIdentity(identity).keyHasPurpose(keyHash, MANAGEMENT)) revert NotIdentityOwner();

        _identityOf[msg.sender] = identity;
        emit IdentityRegistered(msg.sender, identity);
    }

    /// @dev Removes the caller's own identity registration.
    function deregisterIdentity() external {
        address identity = _identityOf[msg.sender];
        if (identity == address(0)) revert NotRegistered();

        delete _identityOf[msg.sender];
        emit IdentityDeregistered(msg.sender, identity);
    }

    // ── Verification ───────────────────────────────────────────────────────────

    /**
     * @dev The authoritative check: is `wallet` verified for `topic`?
     *      Returns true if it holds at least one valid, unexpired claim for the
     *      topic signed by a currently-trusted issuer.
     */
    function isVerified(address wallet, uint256 topic) public view returns (bool) {
        address identity = _identityOf[wallet];
        if (identity == address(0)) return false;

        bytes32[] memory claimIds = IDeZKIdentity(identity).getClaimIdsByTopic(topic);
        uint256 len = claimIds.length;
        for (uint256 i = 0; i < len; ) {
            bytes32 claimId = claimIds[i];
            (, , address issuer, , bytes memory data, ) = IDeZKIdentity(identity).getClaim(claimId);

            if (
                issuerRegistry.isTrustedIssuer(issuer) &&
                IDeZKIdentity(identity).isClaimValid(claimId) &&
                !_isExpired(data)
            ) {
                return true;
            }
            unchecked { ++i; }
        }
        return false;
    }

    /// @dev True only if `wallet` is verified for EVERY topic in `topics`.
    function isVerifiedAll(address wallet, uint256[] calldata topics) external view returns (bool) {
        uint256 len = topics.length;
        for (uint256 i = 0; i < len; ) {
            if (!isVerified(wallet, topics[i])) return false;
            unchecked { ++i; }
        }
        return true;
    }

    // ── Read ───────────────────────────────────────────────────────────────────

    function identityOf(address wallet) external view returns (address) {
        return _identityOf[wallet];
    }

    function isRegistered(address wallet) external view returns (bool) {
        return _identityOf[wallet] != address(0);
    }

    // ── Internal ───────────────────────────────────────────────────────────────

    /// @dev Reads expiresAt from the first 32-byte word of `data` (deZK convention).
    ///      Returns false (never expires) if no expiry is encoded or expiresAt == 0.
    function _isExpired(bytes memory data) internal view returns (bool) {
        if (data.length < 32) return false;
        uint256 expiresAt;
        assembly {
            expiresAt := mload(add(data, 32))
        }
        if (expiresAt == 0) return false;
        return block.timestamp >= expiresAt;
    }
}