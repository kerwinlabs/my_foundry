// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";

import "./BaseScript.s.sol";
import {Upgrades} from "@openzeppelin/foundry-upgrades/Upgrades.sol";
import {UUNFT} from "../src/UUNFT.sol";

/// @notice 使用 OpenZeppelin Upgrades for Foundry 部署 UUPS 可升级 NFT（UUNFT）：
///         1. Upgrades.deployUUPSProxy 会先部署 UUNFT 实现合约，并做升级安全性校验；
///         2. 再部署 ERC1967Proxy 指向该实现，并在构造时调用 initialize 完成初始化；
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
/// 注意：插件依赖 AST / storageLayout 等编译产物，首次运行或修改合约后请先 forge clean，
///       或在命令中加 --force，否则可能读到旧的编译结果。
contract UUNFTScript is BaseScript {
    UUNFT public nft;
    address public implementation;

    function run() public broadcaster {
        // owner 默认是部署者
        address initialOwner = vm.envOr("ADMIN_ADDRESS", deployer);
        bytes memory initData = abi.encodeCall(UUNFT.initialize, (initialOwner));

        // 部署实现合约 + 代理，并初始化；
        // 插件内部会校验存储布局兼容性、initializer 是否安全等
        address proxy = Upgrades.deployUUPSProxy("UUNFT.sol:UUNFT", initData);

        nft = UUNFT(proxy);
        implementation = Upgrades.getImplementationAddress(proxy);

        console.log("UUNFT proxy (use this address) deployed on %s", proxy);
        console.log("");
        console.log("implementation : %s", implementation);
        console.log("proxy          : %s", proxy);
        console.log("owner          : %s", nft.owner());
        console.log("nextTokenId    : %s", nft.nextTokenId());
        console.log("version        : %s", nft.version());

        // 保存合约地址到本地
        saveContract("UUNFT", proxy);
        saveContract("UUNFT_Impl", implementation);
    }
}
