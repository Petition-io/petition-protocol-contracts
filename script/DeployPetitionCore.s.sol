// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PetitionCore} from "../src/core/PetitionCore.sol";

contract DeployPetitionCore is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address initialOwner = vm.envOr("INITIAL_OWNER", vm.addr(deployerKey));
        address priceFeed = vm.envAddress("PRICE_FEED");

        vm.startBroadcast(deployerKey);
        PetitionCore core = new PetitionCore(initialOwner, priceFeed);
        vm.stopBroadcast();

        console.log("PetitionCore deployed at", address(core));
        console.log("initialOwner", initialOwner);
        console.log("priceFeed", priceFeed);
    }
}
