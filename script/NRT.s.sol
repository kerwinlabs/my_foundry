// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";

import "./BaseScript.s.sol";
import {esRNT} from "../src/NRT.sol";

/// @notice 部署 esRNT（NRT）合约，并把地址写入 deployments/esRNT_<chainId>.json
///
///         esRNT 构造函数没有参数，会在构造函数里初始化 11 条 LockInfo 记录：
///         user = address(i + 1)，startTime = block.timestamp * 2 - i，amount = 1e18 * (i + 1)。
///
/// 用法（需要环境变量 PRIVATE_KEY）:
///   PRIVATE_KEY=$PRIVATE_KEY \
///     forge script script/NRT.s.sol:NRTScript \
///     --rpc-url $RPC_URL --broadcast
///
/// 也可以改用 keystore 账号（会交互式输入密码）:
///   forge script script/NRT.s.sol:NRTScript \
///     --rpc-url $RPC_URL --account <account-name> --broadcast
contract NRTScript is BaseScript {
    esRNT public nrt;

    function run() public broadcaster {
        nrt = new esRNT();
        console.log("esRNT deployed at %s", address(nrt));

        // 保存合约地址到本地
        saveContract("esRNT", address(nrt));
    }
}
