// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TimelockGovernor} from "../../src/dezkId/TimelockGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract TimelockGovernorTest is Test {
    TimelockGovernor public governor;

    address public proposer = makeAddr("proposer");
    address public executor = makeAddr("executor");
    address public admin = makeAddr("admin");

    function setUp() public {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;

        address[] memory executors = new address[](1);
        executors[0] = executor;

        governor = new TimelockGovernor(48 hours, proposers, executors, admin);
    }

    function test_RecommendedMinDelayIs48Hours() public view {
        assertEq(governor.RECOMMENDED_MIN_DELAY(), 48 hours);
        assertEq(governor.getMinDelay(), 48 hours);
    }

    function test_ConstructorGrantsProposerRole() public view {
        assertTrue(governor.hasRole(governor.PROPOSER_ROLE(), proposer));
    }

    function test_ConstructorGrantsExecutorRole() public view {
        assertTrue(governor.hasRole(governor.EXECUTOR_ROLE(), executor));
    }

    function test_ConstructorGrantsAdminRole() public view {
        assertTrue(governor.hasRole(governor.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_ProposerCanScheduleAndExecutorCanExecute() public {
        address target = makeAddr("target");
        bytes memory data = "";
        bytes32 predecessor = bytes32(0);
        bytes32 salt = keccak256("salt");
        uint256 delay = governor.getMinDelay();

        vm.prank(proposer);
        governor.schedule(target, 0, data, predecessor, salt, delay);

        bytes32 id = governor.hashOperation(target, 0, data, predecessor, salt);
        assertEq(uint256(governor.getOperationState(id)), uint256(TimelockController.OperationState.Waiting));

        vm.warp(block.timestamp + delay + 1);

        vm.prank(executor);
        governor.execute(target, 0, data, predecessor, salt);

        assertEq(uint256(governor.getOperationState(id)), uint256(TimelockController.OperationState.Done));
    }

    function test_NonProposerCannotSchedule() public {
        vm.expectRevert();
        governor.schedule(address(0), 0, "", bytes32(0), bytes32(0), 48 hours);
    }
}
