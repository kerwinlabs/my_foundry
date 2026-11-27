// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";

import "./BaseScript.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUNFT} from "../src/UUNFT.sol";

/// @notice 部署 UUPS 可升级 NFT（UUNFT）：
///         1. 部署 UUNFT 作为实现合约（构造函数已 _disableInitializers，不能直接初始化）；
///         2. 部署 ERC1967Proxy 指向实现合约，并在代理构造函数中调用 initialize 完成初始化；
///         3. 代理地址保存为 deployments/UUNFT_<chainId>.json —— 对外统一使用这个地址；
///            实现合约地址保存为 deployments/UUNFT_Impl_<chainId>.json，升级时替换实现用。
/// 用法（需要环境变量 PRIVATE_KEY）:
///   PRIVATE_KEY=$PRIVATE_KEY \
///     forge script script/UUNFT.s.sol:UUNFTScript \
///     --rpc-url $RPC_URL --broadcast
/// owner 默认为部署者，可用环境变量 ADMIN_ADDRESS 覆盖:
///   ADMIN_ADDRESS=$ADMIN_ADDRESS PRIVATE_KEY=$PRIVATE_KEY \
///     forge script script/UUNFT.s.sol:UUNFTScript \
///     --rpc-url $RPC_URL --broadcast
contract UUNFTScript is BaseScript {
    UUNFT public implementation;
    ERC1967Proxy public proxy;
    UUNFT public nft;

    function run() public broadcaster {
        // 1. 部署实现合约
        implementation = new UUNFT();
        console.log("UUNFT implementation deployed on %s", address(implementation));

        // 2. 编码 initialize 调用，owner 默认是部署者
        address initialOwner = vm.envOr("ADMIN_ADDRESS", deployer);
        bytes memory initData = abi.encodeCall(UUNFT.initialize, (initialOwner));

        // 3. 部署代理并初始化；owner / nextTokenId / version 等状态都会写入代理存储
        proxy = new ERC1967Proxy(address(implementation), initData);
        nft = UUNFT(address(proxy));
        console.log("UUNFT proxy (use this address) deployed on %s", address(proxy));

        console.log("");
        console.log("implementation : %s", address(implementation));
        console.log("proxy          : %s", address(proxy));
        console.log("owner          : %s", nft.owner());
        console.log("nextTokenId    : %s", nft.nextTokenId());
        console.log("version        : %s", nft.version());

        // 4. 保存合约地址到本地
        saveContract("UUNFT", address(proxy));
        saveContract("UUNFT_Impl", address(implementation));
    }
}
