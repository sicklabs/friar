// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {FriarPositionManager} from "../src/FriarPositionManager.sol";

/// @notice Deploys the FriarPositionManager. No address mining needed (not a hook).
/// Verify the source on the explorer immediately after deploy.
///
/// Usage:
///   forge script script/DeployFriarPositionManager.s.sol --rpc-url $RH_RPC_URL \
///     --broadcast --account tuck-deployer
///
/// Overrides:
///   PERF_FEE_BPS     fee share in bps (default 1000 = 10%, hard cap 2000)
///   TREASURY     perf fee recipient   (default: the broadcasting sender)
///   PERF_FEE_EXEMPT  house bot        (default: the broadcasting sender)
contract DeployFriarPositionManager is Script {
    // Uniswap v4 PoolManager on Robinhood Chain (4663):
    // https://developers.uniswap.org/contracts/v4/deployments
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    function run() external {
        uint16 perfFeeBps = uint16(vm.envOr("PERF_FEE_BPS", uint256(1000)));

        vm.startBroadcast();
        address sender = msg.sender;
        address treasury = vm.envOr("TREASURY", sender);
        address perfFeeExempt = vm.envOr("PERF_FEE_EXEMPT", sender);

        FriarPositionManager fpm = new FriarPositionManager(IPoolManager(POOL_MANAGER), perfFeeBps, treasury, perfFeeExempt);
        vm.stopBroadcast();

        console2.log("FriarPositionManager deployed:", address(fpm));
        console2.log("  perfFeeBps:", perfFeeBps);
        console2.log("  treasury:", treasury);
        console2.log("  perfFeeExempt:", perfFeeExempt);
    }
}
