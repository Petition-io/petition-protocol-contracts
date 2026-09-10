// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Profile} from "../../src/core/Profile.sol";

contract ProfileTest is Test {
    Profile public profile;

    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");
    address internal executor = makeAddr("executor");

    function setUp() public {
        profile = new Profile(owner);
    }

    function test_ConstructorSetsOwner() public view {
        assertEq(profile.owner(), owner);
    }

    function test_OwnerCanSetGovernanceExecutor() public {
        vm.prank(owner);
        profile.setGovernanceExecutor(executor);
        assertEq(profile.governanceExecutor(), executor);
    }

    function test_NonOwnerCannotSetGovernanceExecutor() public {
        vm.prank(user);
        vm.expectRevert();
        profile.setGovernanceExecutor(executor);
    }

    function test_GovernanceCanAuthorizeModule() public {
        vm.prank(owner);
        profile.setGovernanceExecutor(executor);

        vm.prank(executor);
        profile.authorizeModule(user, true);
        assertTrue(profile.isAuthorizedModule(user));
    }

    function test_NonGovernanceCannotPause() public {
        vm.prank(user);
        vm.expectRevert(Profile.Profile__UnauthorizedModule.selector);
        profile.pause();
    }

    function test_UpdateProfileStoresPointers() public {
        vm.prank(user);
        profile.updateProfile(
            "profile-tx",
            "profile-hash",
            "avatar-tx",
            "avatar-hash",
            "first-tx",
            "first-hash",
            "last-tx",
            "last-hash",
            "bio-tx",
            "bio-hash",
            "tw-tx",
            "tw-hash",
            "gh-tx",
            "gh-hash",
            "es-tx",
            "es-hash",
            "tg-tx",
            "tg-hash",
            "ens-tx",
            "ens-hash"
        );
    }
}
