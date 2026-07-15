// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {Friar} from "../src/Friar.sol";

/// @notice Mines a hook address (AFTER_INITIALIZE | BEFORE_SWAP bits only) and deploys
/// the Friar via the canonical CREATE2 deployer. Verify the source on the explorer
/// immediately after — the hooklist analyzer reads verified source.
///
/// Usage:
///   forge script script/DeployFriar.s.sol --rpc-url $RH_RPC_URL --broadcast \
///     --private-key $DEPLOYER_PK
///
/// Parameter overrides (defaults mirror common LB presets; TUNE BEFORE REAL DEPLOY —
/// see docs/SPEC.md §6):
///   BASE_FACTOR, FILTER_PERIOD, DECAY_PERIOD, REDUCTION_FACTOR,
///   VARIABLE_FEE_CONTROL, MAX_VOL_ACC
contract DeployFriar is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    // Uniswap v4 PoolManager on Robinhood Chain (4663):
    // https://developers.uniswap.org/contracts/v4/deployments
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    function run() external {
        uint16 baseFactor = uint16(vm.envOr("BASE_FACTOR", uint256(5000)));
        uint16 filterPeriod = uint16(vm.envOr("FILTER_PERIOD", uint256(10)));
        uint16 decayPeriod = uint16(vm.envOr("DECAY_PERIOD", uint256(600)));
        uint16 reductionFactor = uint16(vm.envOr("REDUCTION_FACTOR", uint256(5000)));
        uint24 variableFeeControl = uint24(vm.envOr("VARIABLE_FEE_CONTROL", uint256(40_000)));
        uint24 maxVolAcc = uint24(vm.envOr("MAX_VOL_ACC", uint256(350_000)));

        bytes memory constructorArgs = abi.encode(
            IPoolManager(POOL_MANAGER),
            baseFactor,
            filterPeriod,
            decayPeriod,
            reductionFactor,
            variableFeeControl,
            maxVolAcc
        );

        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(Friar).creationCode, constructorArgs);

        console2.log("Mined Friar address:", hookAddress);
        console2.log("Salt:");
        console2.logBytes32(salt);

        vm.startBroadcast();
        Friar friar = new Friar{salt: salt}(
            IPoolManager(POOL_MANAGER),
            baseFactor,
            filterPeriod,
            decayPeriod,
            reductionFactor,
            variableFeeControl,
            maxVolAcc
        );
        vm.stopBroadcast();

        require(address(friar) == hookAddress, "address mismatch: CREATE2 deployer differs from miner assumption");
        console2.log("Friar deployed:", address(friar));
    }
}
