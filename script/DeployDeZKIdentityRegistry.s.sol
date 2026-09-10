// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {DeZKIdentityRegistry} from "../src/dezkId/DeZKIdentityRegistry.sol";

contract DeployDeZKIdentityRegistry is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address issuerRegistry = vm.envAddress("ISSUER_REGISTRY");

        vm.startBroadcast(deployerKey);
        DeZKIdentityRegistry registry = new DeZKIdentityRegistry(issuerRegistry);
        vm.stopBroadcast();

        console.log("DeZKIdentityRegistry deployed at", address(registry));
        console.log("issuerRegistry", issuerRegistry);
    }
}
