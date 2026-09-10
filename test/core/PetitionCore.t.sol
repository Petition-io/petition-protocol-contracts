// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PetitionCore} from "../../src/core/PetitionCore.sol";

contract MockPriceFeed {
    int256 public answer = 2000e8;
    uint8 public decimals_ = 8;

    function decimals() external view returns (uint8) {
        return decimals_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

contract PetitionCoreTest is Test {
    PetitionCore public core;
    MockPriceFeed public feed;

    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");

    function setUp() public {
        feed = new MockPriceFeed();
        core = new PetitionCore(owner, address(feed));
    }

    function test_ConstructorSetsOwnerAndPriceFeed() public view {
        assertEq(core.owner(), owner);
        assertEq(address(core.priceFeed()), address(feed));
    }

    function test_ConstructorRevertsOnZeroPriceFeed() public {
        vm.expectRevert("Invalid price feed address");
        new PetitionCore(owner, address(0));
    }

    function test_OwnerCanSetGovernanceExecutor() public {
        address executor = makeAddr("executor");
        vm.prank(owner);
        core.setGovernanceExecutor(executor);
        assertEq(core.governanceExecutor(), executor);
    }

    function test_OwnerCanSetRelayExecutor() public {
        address relay = makeAddr("relay");
        vm.prank(owner);
        core.setRelayExecutor(relay);
        assertEq(core.relayExecutor(), relay);
    }

    function test_NonOwnerCannotSetGovernanceExecutor() public {
        vm.prank(user);
        vm.expectRevert();
        core.setGovernanceExecutor(makeAddr("executor"));
    }
}
