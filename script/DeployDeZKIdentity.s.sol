// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {DeZKIdentity} from "../src/dezkId/DeZKIdentity.sol";

contract DeployDeZKIdentity is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address initialManager = vm.envOr("INITIAL_MANAGER", vm.addr(deployerKey));

        vm.startBroadcast(deployerKey);
        DeZKIdentity identity = new DeZKIdentity(initialManager);
        vm.stopBroadcast();

        console.log("DeZKIdentity deployed at", address(identity));
        console.log("initialManager", initialManager);
    }
}
