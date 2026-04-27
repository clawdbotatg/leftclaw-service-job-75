// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DeployHelpers.s.sol";
import { ZeitgeistPayment } from "../contracts/ZeitgeistPayment.sol";

/**
 * @notice Deploy script for ZeitgeistPayment.
 * @dev Constructor inputs are hard-coded for Base mainnet:
 *      - priceFeed: Chainlink ETH/USD on Base = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
 *      - clawd:     CLAWD token on Base       = 0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07
 *      - initialOwner:        job.client      = 0xC99F74bC7c065d8c51BD724Da898d44F775a8a19
 *      - initialQueryPriceCLAWD = 5000 * 1e18 (owner can adjust later)
 *
 * Run via:
 *   yarn deploy --file DeployZeitgeistPayment.s.sol --network base
 */
contract DeployZeitgeistPayment is ScaffoldETHDeploy {
    address constant CHAINLINK_ETH_USD_BASE = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant CLAWD_TOKEN_BASE = 0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07;
    address constant INITIAL_OWNER = 0xC99F74bC7c065d8c51BD724Da898d44F775a8a19;
    uint256 constant INITIAL_QUERY_PRICE_CLAWD = 5000 * 1e18;

    function run() external ScaffoldEthDeployerRunner {
        ZeitgeistPayment zp = new ZeitgeistPayment(
            CHAINLINK_ETH_USD_BASE,
            CLAWD_TOKEN_BASE,
            INITIAL_OWNER,
            INITIAL_QUERY_PRICE_CLAWD
        );

        deployments.push(Deployment({ name: "ZeitgeistPayment", addr: address(zp) }));
    }
}
