// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721URIStorage, ERC721} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";

contract MyERC721 is ERC721URIStorage {
    uint256 public _nextTokenId = 1;

    constructor() ERC721(unicode"训练营", "MyMAMP") {}

    // @notice 铸造一个 NFT
    function mint(address to, string memory tokenURI) public returns (uint256) {
        uint256 newItemId = _nextTokenId++;
        _safeMint(to, newItemId);
        _setTokenURI(newItemId, tokenURI);
        return newItemId;
    }


}

