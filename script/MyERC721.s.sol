// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {MyERC721} from "../src/MyERC721.sol";

/// @notice 部署 MyERC721，并把合约地址写入 deployments/MyERC721_<chainId>.json
/// 部署账号由命令行指定，例如:
///   forge script script/MyERC721.s.sol:MyERC721Script \
///     --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
/// 或使用 keystore:
///   forge script script/MyERC721.s.sol:MyERC721Script \
///     --rpc-url $SEPOLIA_RPC_URL --account <account-name> --broadcast --verify
contract MyERC721Script is Script {
    MyERC721 public nft;

    function run() public {
        vm.startBroadcast();
        nft = new MyERC721();
        vm.stopBroadcast();

        console.log("MyERC721 deployed at %s", address(nft));

        // 保存了合约地址到本地
        _saveContract("MyERC721", address(nft));
    }

    function _saveContract(string memory name, address addr) private {
        string memory finalJson = vm.serializeAddress("key", "address", addr);
        vm.writeJson(
            finalJson,
            string.concat("deployments/", name, "_", vm.toString(block.chainid), ".json")
        );
    }
}

/// @notice 为已部署的 MyERC721 铸造一个 NFT
/// 用法:
///   NFT_ADDRESS=0x... \
///     forge script script/MyERC721.s.sol:MyERC721MintScript \
///     --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
///
/// 接收方默认为部署账号，可通过 NFT_RECIPIENT 环境变量覆盖。
contract MyERC721MintScript is Script {
    function run() public {
        MyERC721 nft = MyERC721(0xC313F968aEc04E13906283C464681F1Dd7520d0C);
        // acc2
        address to = 0x2b7a2A5782981f7B58511d404332f3d35Df5D8Df;

        string memory tokenUri = "ipfs://bafkreiggyoishgulr42ny7thaxg6ezn6sx43qikbbnsairbyb44hpc7zgm";

        vm.startBroadcast();
        // 铸造 NFT
        uint256 tokenId = nft.mint(to, tokenUri);
        vm.stopBroadcast();

        console.log("Minted token %s to %s", tokenId, to);
    }
}
