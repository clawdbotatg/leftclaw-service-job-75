//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DeployHelpers.s.sol";
import { DeployZeitgeistPayment } from "./DeployZeitgeistPayment.s.sol";

/**
 * @notice Main deployment script for all contracts.
 * @dev Run this when you want to deploy multiple contracts at once.
 *
 * Example: yarn deploy # runs this script(without`--file` flag)
 */
contract DeployScript is ScaffoldETHDeploy {
    function run() external {
        // Deploys ZeitgeistPayment to the configured network.
        DeployZeitgeistPayment deployZeitgeistPayment = new DeployZeitgeistPayment();
        deployZeitgeistPayment.run();
    }
}
