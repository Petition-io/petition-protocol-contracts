// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Profile} from "../src/core/Profile.sol";

contract DeployProfile is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address initialOwner = vm.envOr("INITIAL_OWNER", vm.addr(deployerKey));

        vm.startBroadcast(deployerKey);
        Profile profile = new Profile(initialOwner);
        vm.stopBroadcast();

        console.log("Profile deployed at", address(profile));
        console.log("initialOwner", initialOwner);
    }
}
