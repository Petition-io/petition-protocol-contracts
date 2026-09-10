// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TimelockGovernor} from "../src/dezkId/TimelockGovernor.sol";

contract DeployTimelockGovernor is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address[] memory proposers = new address[](1);
        proposers[0] = vm.envOr("PROPOSER", deployer);

        address[] memory executors = new address[](1);
        executors[0] = vm.envOr("EXECUTOR", address(0));

        address admin = vm.envOr("ADMIN", deployer);
        uint256 minDelay = vm.envOr("MIN_DELAY", uint256(48 hours));

        vm.startBroadcast(deployerKey);
        TimelockGovernor governor = new TimelockGovernor(minDelay, proposers, executors, admin);
        vm.stopBroadcast();

        console.log("TimelockGovernor deployed at", address(governor));
        console.log("minDelay", minDelay);
        console.log("proposer", proposers[0]);
        console.log("admin", admin);
    }
}
