// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.7;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1155URIStorage} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155URIStorage.sol";
import {ERC1155Supply, ERC1155} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {Counters} from "@openzeppelin/contracts/utils/Counters.sol";
import {GovernanceSharesOwnershipInterface} from "@unleashed/opendapps-cloud-interfaces/governance/GovernanceSharesOwnershipInterface.sol";

contract OwnershipSharesNFTCollection is GovernanceSharesOwnershipInterface, Ownable, ERC1155Supply, ERC1155URIStorage {
    event ContractURIUpdated(string newUri);

    using Counters for Counters.Counter;
    uint256 public constant TOTAL_SHARES = 1000;

    string internal _contractURI;
    Counters.Counter private _tokenIdTracker;

    mapping(address => mapping(uint256 => uint256)) private _latestBalanceUpdate;

    constructor(string memory __contractURI) ERC1155("") {
        _contractURI = __contractURI;

        emit ContractURIUpdated(__contractURI);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(GovernanceSharesOwnershipInterface).interfaceId ||
            super.supportsInterface(interfaceId);
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

    function latestBalanceUpdate(address wallet, uint256 tokenId) public view returns (uint256) {
        return _latestBalanceUpdate[wallet][tokenId];
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

    function _afterTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal virtual override {
        for (uint256 i = 0; i < ids.length; i++) {
            if (amounts[i] <= 0) continue;

            _latestBalanceUpdate[from][ids[i]] = block.number;
            _latestBalanceUpdate[to][ids[i]] = block.number;
        }
        super._afterTokenTransfer(operator, from, to, ids, amounts, data);
    }
}
