// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "./interfaces/IERC734.sol";
import "./interfaces/IERC735.sol";

/**
 * @title DeZKIdentity
 * @dev Self-sovereign on-chain identity for the deZK protocol.
 *
 * One contract per user — their on-chain "passport." The user owns it via a
 * MANAGEMENT key (their wallet). Trusted issuers (e.g. deZK) sign claims off-chain;
 * the user stores them here. Any protocol can then verify those claims on-chain.
 *
 * Implements three standards (the same stack ONCHAINID uses, so deZK identities
 * interoperate with ERC-3643 tokens and any ONCHAINID-compatible system):
 *   - ERC-734  : key management (who controls this identity)
 *   - ERC-735  : claims (verifiable attestations from issuers)
 *   - ERC-725Y : generic key-value metadata store
 *
 * ERC-725X (the execute proxy) is intentionally omitted in v1 — it adds attack
 * surface and is not needed for the identity/claims use case.
 *
 * SIGNATURE MODEL
 * ---------------
 * A claim is valid when the recovered signer of:
 *     ethSignedMessage( keccak256(abi.encode(address(this), topic, data)) )
 * equals the claim's stated `issuer`. The signature binds the claim to THIS
 * identity and THIS topic, so it cannot be replayed onto another identity.
 * Whether that issuer is *trusted* is decided by the IssuerRegistry, not here —
 * this contract only proves the signature is authentic.
 */
contract DeZKIdentity is IERC734, IERC735, IERC165 {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ── Constants ──────────────────────────────────────────────────────────────

    uint256 public constant MANAGEMENT   = 1;
    uint256 public constant ACTION       = 2;
    uint256 public constant CLAIM_SIGNER = 3;

    uint256 public constant KEYTYPE_ECDSA = 1;
    uint256 public constant SCHEME_ECDSA  = 1;

    // ── Custom Errors ──────────────────────────────────────────────────────────

    error NotManagementKey();
    error ZeroKey();
    error KeyAlreadyHasPurpose();
    error KeyDoesNotHavePurpose();
    error CannotRemoveLastManagementKey();
    error ZeroIssuer();
    error InvalidClaimSignature();
    error UnsupportedScheme();
    error ClaimDoesNotExist();

    // ── Storage ────────────────────────────────────────────────────────────────

    struct Key {
        uint256[] purposes;
        uint256   keyType;
        bytes32   key;
    }

    struct Claim {
        uint256 topic;
        uint256 scheme;
        address issuer;
        bytes   signature;
        bytes   data;
        string  uri;
    }

    mapping(bytes32 => Key)       private _keys;             // keyHash => Key
    mapping(uint256 => bytes32[]) private _keysByPurpose;    // purpose => keyHashes
    uint256                       private _managementKeyCount;

    mapping(bytes32 => Claim)     private _claims;           // claimId => Claim
    mapping(uint256 => bytes32[]) private _claimsByTopic;    // topic   => claimIds

    mapping(bytes32 => bytes)     private _store;            // ERC-725Y key-value store

    // ── Constructor ────────────────────────────────────────────────────────────

    /// @param initialManager the wallet that receives the first MANAGEMENT key (the owner)
    constructor(address initialManager) {
        if (initialManager == address(0)) revert ZeroKey();
        bytes32 keyHash = keyForAddress(initialManager);
        _keys[keyHash].key     = keyHash;
        _keys[keyHash].keyType = KEYTYPE_ECDSA;
        _keys[keyHash].purposes.push(MANAGEMENT);
        _keysByPurpose[MANAGEMENT].push(keyHash);
        _managementKeyCount = 1;
        emit KeyAdded(keyHash, MANAGEMENT, KEYTYPE_ECDSA);
    }

    // ── Modifiers ──────────────────────────────────────────────────────────────

    modifier onlyManagement() {
        if (!keyHasPurpose(keyForAddress(msg.sender), MANAGEMENT)) revert NotManagementKey();
        _;
    }

    // ── ERC-734: Key Management ──────────────────────────────────────────────────

    function addKey(bytes32 key, uint256 purpose, uint256 keyType)
        external
        onlyManagement
        returns (bool)
    {
        if (key == bytes32(0))                  revert ZeroKey();
        if (keyHasPurpose(key, purpose))        revert KeyAlreadyHasPurpose();

        if (_keys[key].key == bytes32(0)) {
            _keys[key].key     = key;
            _keys[key].keyType = keyType;
        }
        _keys[key].purposes.push(purpose);
        _keysByPurpose[purpose].push(key);

        if (purpose == MANAGEMENT) {
            unchecked { ++_managementKeyCount; }
        }

        emit KeyAdded(key, purpose, keyType);
        return true;
    }

    function removeKey(bytes32 key, uint256 purpose)
        external
        onlyManagement
        returns (bool)
    {
        if (!keyHasPurpose(key, purpose)) revert KeyDoesNotHavePurpose();

        // Lockout protection: never remove the last MANAGEMENT key
        if (purpose == MANAGEMENT && _managementKeyCount == 1) {
            revert CannotRemoveLastManagementKey();
        }

        uint256 keyType = _keys[key].keyType;
        _removePurposeFromKey(key, purpose);
        _removeKeyFromPurposeList(key, purpose);

        if (purpose == MANAGEMENT) {
            unchecked { --_managementKeyCount; }
        }

        emit KeyRemoved(key, purpose, keyType);
        return true;
    }

    function getKey(bytes32 key)
        external
        view
        returns (uint256[] memory purposes, uint256 keyType, bytes32 keyValue)
    {
        Key storage k = _keys[key];
        return (k.purposes, k.keyType, k.key);
    }

    function getKeyPurposes(bytes32 key) external view returns (uint256[] memory) {
        return _keys[key].purposes;
    }

    function getKeysByPurpose(uint256 purpose) external view returns (bytes32[] memory) {
        return _keysByPurpose[purpose];
    }

    function keyHasPurpose(bytes32 key, uint256 purpose) public view returns (bool) {
        // Exact-match only: a key reports a purpose ONLY if it was explicitly granted.
        // (We deliberately do NOT let MANAGEMENT silently satisfy every purpose check —
        //  an external protocol asking "does this key have CLAIM_SIGNER?" must get the truth.)
        uint256[] storage purposes = _keys[key].purposes;
        uint256 len = purposes.length;
        for (uint256 i = 0; i < len; ) {
            if (purposes[i] == purpose) return true;
            unchecked { ++i; }
        }
        return false;
    }

    // ── ERC-735: Claims ──────────────────────────────────────────────────────────

    function addClaim(
        uint256        topic,
        uint256        scheme,
        address        issuer,
        bytes calldata signature,
        bytes calldata data,
        string calldata uri
    ) external onlyManagement returns (bytes32 claimId) {
        if (issuer == address(0))      revert ZeroIssuer();
        if (scheme != SCHEME_ECDSA)    revert UnsupportedScheme();

        // Verify the issuer actually signed this claim for THIS identity + topic.
        if (!_verifyClaim(topic, issuer, signature, data)) revert InvalidClaimSignature();

        claimId = keccak256(abi.encode(issuer, topic));

        bool isNew = _claims[claimId].issuer == address(0);
        _claims[claimId] = Claim(topic, scheme, issuer, signature, data, uri);

        if (isNew) {
            _claimsByTopic[topic].push(claimId);
            emit ClaimAdded(claimId, topic, scheme, issuer, signature, data, uri);
        } else {
            emit ClaimChanged(claimId, topic, scheme, issuer, signature, data, uri);
        }
    }

    function removeClaim(bytes32 claimId) external onlyManagement returns (bool) {
        Claim memory c = _claims[claimId];
        if (c.issuer == address(0)) revert ClaimDoesNotExist();

        _removeClaimFromTopicList(claimId, c.topic);
        delete _claims[claimId];

        emit ClaimRemoved(claimId, c.topic, c.scheme, c.issuer, c.signature, c.data, c.uri);
        return true;
    }

    function getClaim(bytes32 claimId)
        external
        view
        returns (
            uint256 topic,
            uint256 scheme,
            address issuer,
            bytes memory signature,
            bytes memory data,
            string memory uri
        )
    {
        Claim storage c = _claims[claimId];
        return (c.topic, c.scheme, c.issuer, c.signature, c.data, c.uri);
    }

    function getClaimIdsByTopic(uint256 topic) external view returns (bytes32[] memory) {
        return _claimsByTopic[topic];
    }

    /**
     * @dev Re-verifies a stored claim's signature against its issuer. Anyone can call.
     *      Returns false if the claim does not exist or the signature no longer recovers
     *      to the stated issuer. Whether the issuer is TRUSTED is decided elsewhere
     *      (IssuerRegistry) — this only proves authenticity.
     */
    function isClaimValid(bytes32 claimId) external view returns (bool) {
        Claim storage c = _claims[claimId];
        if (c.issuer == address(0)) return false;
        if (c.scheme != SCHEME_ECDSA) return false;
        return _verifyClaim(c.topic, c.issuer, c.signature, c.data);
    }

    // ── ERC-725Y: Key-Value Store ────────────────────────────────────────────────

    function setData(bytes32 dataKey, bytes calldata dataValue) external onlyManagement {
        _store[dataKey] = dataValue;
    }

    function getData(bytes32 dataKey) external view returns (bytes memory) {
        return _store[dataKey];
    }

    // ── ERC-165 ──────────────────────────────────────────────────────────────────

    /// @dev Lets ERC-3643 tokens / ONCHAINID systems confirm this is a valid identity
    ///      contract before trusting its claims.
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return
            interfaceId == type(IERC734).interfaceId ||
            interfaceId == type(IERC735).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    // ── Helpers ──────────────────────────────────────────────────────────────────

    /// @dev Canonical key hash for an ECDSA address.
    function keyForAddress(address addr) public pure returns (bytes32) {
        return keccak256(abi.encode(addr));
    }

    function _verifyClaim(
        uint256       topic,
        address       issuer,
        bytes memory  signature,
        bytes memory  data
    ) internal view returns (bool) {
        bytes32 dataHash     = keccak256(abi.encode(address(this), topic, data));
        bytes32 prefixedHash = dataHash.toEthSignedMessageHash();
        (address recovered, ECDSA.RecoverError err, ) = ECDSA.tryRecover(prefixedHash, signature);
        if (err != ECDSA.RecoverError.NoError) return false;
        return recovered == issuer;
    }

    function _removePurposeFromKey(bytes32 key, uint256 purpose) internal {
        uint256[] storage purposes = _keys[key].purposes;
        uint256 len = purposes.length;
        for (uint256 i = 0; i < len; ) {
            if (purposes[i] == purpose) {
                purposes[i] = purposes[len - 1];
                purposes.pop();
                break;
            }
            unchecked { ++i; }
        }
        // If the key has no purposes left, clear its record entirely.
        if (purposes.length == 0) {
            delete _keys[key];
        }
    }

    function _removeKeyFromPurposeList(bytes32 key, uint256 purpose) internal {
        bytes32[] storage list = _keysByPurpose[purpose];
        uint256 len = list.length;
        for (uint256 i = 0; i < len; ) {
            if (list[i] == key) {
                list[i] = list[len - 1];
                list.pop();
                break;
            }
            unchecked { ++i; }
        }
    }

    function _removeClaimFromTopicList(bytes32 claimId, uint256 topic) internal {
        bytes32[] storage list = _claimsByTopic[topic];
        uint256 len = list.length;
        for (uint256 i = 0; i < len; ) {
            if (list[i] == claimId) {
                list[i] = list[len - 1];
                list.pop();
                break;
            }
            unchecked { ++i; }
        }
    }
}