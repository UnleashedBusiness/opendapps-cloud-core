pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1155URIStorage} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155URIStorage.sol";
import {ERC1155Supply, ERC1155} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {Counters} from "@openzeppelin/contracts/utils/Counters.sol";

contract OwnershipSharesNFTCollection is Ownable, ERC1155Supply, ERC1155URIStorage {
    using Counters for Counters.Counter;
    uint256 public constant TOTAL_SHARES = 1000;

    string internal _contractURI;
    Counters.Counter private _tokenIdTracker;

    constructor(string memory __contractURI) ERC1155("") {
        _contractURI = __contractURI;
    }

    function nextTokenId() external view returns (uint256) {
        return _tokenIdTracker.current();
    }

    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    function uri(uint256 tokenId) public view virtual override(ERC1155, ERC1155URIStorage) returns (string memory) {
        return ERC1155URIStorage.uri(tokenId);
    }

    function mint(address to, string memory _metadataUri) public onlyOwner {
        // We cannot just use balanceOf to create the new tokenId because tokens
        // can be burned (destroyed), so we need a separate counter.
        _mint(to, _tokenIdTracker.current(), TOTAL_SHARES, "");
        _setURI(_tokenIdTracker.current(), _metadataUri);
        _tokenIdTracker.increment();
    }

    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal virtual override(ERC1155Supply, ERC1155) {
        ERC1155Supply._beforeTokenTransfer(operator, from, to, ids, amounts, data);
    }
}
