// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeZKIdentity} from "../../src/dezkId/DeZKIdentity.sol";

contract DeZKIdentityTest is Test {
    DeZKIdentity public identity;

    uint256 internal managerPk = 0xA11CE;
    address internal manager;
    uint256 internal issuerPk = 0xB0B;
    address internal issuer;
    address internal stranger = makeAddr("stranger");

    uint256 internal constant KYC_TOPIC = 1;

    function setUp() public {
        manager = vm.addr(managerPk);
        issuer = vm.addr(issuerPk);
        identity = new DeZKIdentity(manager);
    }

    function test_ConstructorSetsManagementKey() public view {
        bytes32 keyHash = identity.keyForAddress(manager);
        assertTrue(identity.keyHasPurpose(keyHash, identity.MANAGEMENT()));

        bytes32[] memory keys = identity.getKeysByPurpose(identity.MANAGEMENT());
        assertEq(keys.length, 1);
        assertEq(keys[0], keyHash);
    }

    function test_ConstructorRevertsOnZeroAddress() public {
        vm.expectRevert(DeZKIdentity.ZeroKey.selector);
        new DeZKIdentity(address(0));
    }

    function test_AddAndRemoveActionKey() public {
        bytes32 actionKey = identity.keyForAddress(makeAddr("action"));

        vm.prank(manager);
        identity.addKey(actionKey, identity.ACTION(), identity.KEYTYPE_ECDSA());
        assertTrue(identity.keyHasPurpose(actionKey, identity.ACTION()));

        vm.prank(manager);
        identity.removeKey(actionKey, identity.ACTION());
        assertFalse(identity.keyHasPurpose(actionKey, identity.ACTION()));
    }

    function test_CannotRemoveLastManagementKey() public {
        bytes32 keyHash = identity.keyForAddress(manager);

        vm.prank(manager);
        vm.expectRevert(DeZKIdentity.CannotRemoveLastManagementKey.selector);
        identity.removeKey(keyHash, identity.MANAGEMENT());
    }

    function test_NonManagerCannotAddKey() public {
        vm.prank(stranger);
        vm.expectRevert(DeZKIdentity.NotManagementKey.selector);
        identity.addKey(identity.keyForAddress(stranger), identity.ACTION(), identity.KEYTYPE_ECDSA());
    }

    function test_AddAndRemoveClaim() public {
        bytes memory data = abi.encode(uint256(0), keccak256("kyc"));
        bytes memory signature = _signClaim(issuerPk, address(identity), KYC_TOPIC, data);

        vm.prank(manager);
        bytes32 claimId = identity.addClaim(
            KYC_TOPIC,
            identity.SCHEME_ECDSA(),
            issuer,
            signature,
            data,
            "ipfs://claim"
        );

        assertTrue(identity.isClaimValid(claimId));

        (uint256 topic, uint256 scheme, address claimIssuer,, bytes memory storedData, string memory uri) =
            identity.getClaim(claimId);
        assertEq(topic, KYC_TOPIC);
        assertEq(scheme, identity.SCHEME_ECDSA());
        assertEq(claimIssuer, issuer);
        assertEq(storedData, data);
        assertEq(uri, "ipfs://claim");

        vm.prank(manager);
        identity.removeClaim(claimId);
        assertFalse(identity.isClaimValid(claimId));
    }

    function test_AddClaimRevertsOnInvalidSignature() public {
        bytes memory data = abi.encode(uint256(0), keccak256("kyc"));
        bytes memory badSig = _signClaim(managerPk, address(identity), KYC_TOPIC, data);

        vm.prank(manager);
        vm.expectRevert(DeZKIdentity.InvalidClaimSignature.selector);
        identity.addClaim(KYC_TOPIC, identity.SCHEME_ECDSA(), issuer, badSig, data, "");
    }

    function test_SetAndGetData() public {
        bytes32 dataKey = keccak256("profile");
        bytes memory value = bytes("arweave-tx-id");

        vm.prank(manager);
        identity.setData(dataKey, value);
        assertEq(identity.getData(dataKey), value);
    }

    function test_SupportsIdentityInterfaces() public view {
        assertTrue(identity.supportsInterface(0x01ffc9a7)); // ERC-165
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
