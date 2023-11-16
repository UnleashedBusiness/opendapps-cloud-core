// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.7;

import {ERC721, ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {Counters} from "@openzeppelin/contracts/utils/Counters.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

    error NFTSoulboundError();

contract SoulboundNftCollection is Ownable, ERC721Enumerable, ERC721URIStorage {
    using Counters for Counters.Counter;

    string internal _contractURI;
    Counters.Counter private _tokenIdTracker;

    constructor(string memory _name, string memory _ticker, string memory __contractURI) ERC721(_name, _ticker) {
        _contractURI = __contractURI;
    }

    function nextTokenId() external view returns (uint256) {
        return _tokenIdTracker.current();
    }

    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    function tokenURI(uint256 tokenId) public view override(ERC721URIStorage, ERC721) returns (string memory) {
        return ERC721URIStorage.tokenURI(tokenId);
    }

    function mint(address to, string memory _metadataUri) public onlyOwner {
        // We cannot just use balanceOf to create the new tokenId because tokens
        // can be burned (destroyed), so we need a separate counter.
        _mint(to, _tokenIdTracker.current());
        _setTokenURI(_tokenIdTracker.current(), _metadataUri);
        _tokenIdTracker.increment();
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721Enumerable, ERC721URIStorage) returns (bool) {
        return ERC721Enumerable.supportsInterface(interfaceId);
    }

    function _burn(uint256 tokenId) internal virtual override(ERC721URIStorage, ERC721) {
        ERC721URIStorage._burn(tokenId);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    ) internal virtual override(ERC721Enumerable, ERC721) {
        if (from != address(0) && to != address(0)) {
            revert NFTSoulboundError();
        }

        ERC721Enumerable._beforeTokenTransfer(from, to, tokenId, batchSize);
    }

}
