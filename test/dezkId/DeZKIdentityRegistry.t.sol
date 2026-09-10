// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeZKIdentity} from "../../src/dezkId/DeZKIdentity.sol";
import {DeZKIdentityRegistry} from "../../src/dezkId/DeZKIdentityRegistry.sol";

contract MockIssuerRegistry {
    mapping(address => bool) public trusted;

    function setTrusted(address issuer, bool isTrusted) external {
        trusted[issuer] = isTrusted;
    }

    function isTrustedIssuer(address issuer) external view returns (bool) {
        return trusted[issuer];
    }
}

contract DeZKIdentityRegistryTest is Test {
    DeZKIdentity public identity;
    DeZKIdentityRegistry public registry;
    MockIssuerRegistry public issuers;

    uint256 internal userPk = 0xA11CE;
    address internal user;
    uint256 internal issuerPk = 0xB0B;
    address internal issuer;

    uint256 internal constant KYC_TOPIC = 1;

    function setUp() public {
        user = vm.addr(userPk);
        issuer = vm.addr(issuerPk);

        issuers = new MockIssuerRegistry();
        issuers.setTrusted(issuer, true);

        identity = new DeZKIdentity(user);
        registry = new DeZKIdentityRegistry(address(issuers));
    }

    function test_ConstructorRevertsOnZeroIssuerRegistry() public {
        vm.expectRevert(DeZKIdentityRegistry.ZeroAddress.selector);
        new DeZKIdentityRegistry(address(0));
    }

    function test_RegisterAndDeregisterIdentity() public {
        vm.prank(user);
        registry.registerIdentity(address(identity));

        assertTrue(registry.isRegistered(user));
        assertEq(registry.identityOf(user), address(identity));

        vm.prank(user);
        registry.deregisterIdentity();

        assertFalse(registry.isRegistered(user));
        assertEq(registry.identityOf(user), address(0));
    }

    function test_RegisterRevertsIfNotIdentityOwner() public {
        address other = makeAddr("other");
        vm.prank(other);
        vm.expectRevert(DeZKIdentityRegistry.NotIdentityOwner.selector);
        registry.registerIdentity(address(identity));
    }

    function test_RegisterRevertsIfAlreadyRegistered() public {
        vm.startPrank(user);
        registry.registerIdentity(address(identity));
        vm.expectRevert(DeZKIdentityRegistry.AlreadyRegistered.selector);
        registry.registerIdentity(address(identity));
        vm.stopPrank();
    }

    function test_IsVerifiedRequiresTrustedUnexpiredClaim() public {
        bytes memory data = abi.encode(uint256(0), keccak256("kyc"));
        bytes memory signature = _signClaim(issuerPk, address(identity), KYC_TOPIC, data);

        vm.startPrank(user);
        identity.addClaim(KYC_TOPIC, identity.SCHEME_ECDSA(), issuer, signature, data, "");
        registry.registerIdentity(address(identity));
        vm.stopPrank();

        assertTrue(registry.isVerified(user, KYC_TOPIC));

        uint256[] memory topics = new uint256[](1);
        topics[0] = KYC_TOPIC;
        assertTrue(registry.isVerifiedAll(user, topics));
    }

    function test_IsVerifiedFalseWhenUnregistered() public view {
        assertFalse(registry.isVerified(user, KYC_TOPIC));
    }

    function test_IsVerifiedFalseWhenIssuerUntrusted() public {
        bytes memory data = abi.encode(uint256(0), keccak256("kyc"));
        bytes memory signature = _signClaim(issuerPk, address(identity), KYC_TOPIC, data);

        vm.startPrank(user);
        identity.addClaim(KYC_TOPIC, identity.SCHEME_ECDSA(), issuer, signature, data, "");
        registry.registerIdentity(address(identity));
        vm.stopPrank();

        issuers.setTrusted(issuer, false);
        assertFalse(registry.isVerified(user, KYC_TOPIC));
    }

    function test_IsVerifiedFalseWhenClaimExpired() public {
        uint256 expiresAt = block.timestamp + 1 days;
        bytes memory data = abi.encode(expiresAt, keccak256("kyc"));
        bytes memory signature = _signClaim(issuerPk, address(identity), KYC_TOPIC, data);

        vm.startPrank(user);
        identity.addClaim(KYC_TOPIC, identity.SCHEME_ECDSA(), issuer, signature, data, "");
        registry.registerIdentity(address(identity));
        vm.stopPrank();

        assertTrue(registry.isVerified(user, KYC_TOPIC));

        vm.warp(expiresAt + 1);
        assertFalse(registry.isVerified(user, KYC_TOPIC));
    }

    function _signClaim(uint256 pk, address identityAddr, uint256 topic, bytes memory data)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 dataHash = keccak256(abi.encode(identityAddr, topic, data));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", dataHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethHash);
        return abi.encodePacked(r, s, v);
    }
}
