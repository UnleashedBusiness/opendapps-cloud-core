// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.7;

import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {IERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/IERC165Upgradeable.sol";
import {IERC721ReceiverUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";
import {IERC1155ReceiverUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155ReceiverUpgradeable.sol";
import {DoubleEndedQueueUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/structs/DoubleEndedQueueUpgradeable.sol";
import {SafeCastUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";
import {TimersUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/TimersUpgradeable.sol";

import {ProposalGovernorInterface} from "@unleashed/opendapps-cloud-interfaces/governance/ProposalGovernorInterface.sol";

import "./BaseGovernor.sol";

/**
 * Forked from openzeppelin Governor 4.3 and fixes some issues
 */
abstract contract BaseProposalGovernor is ERC165Upgradeable, ProposalGovernorInterface, IERC721ReceiverUpgradeable,
        IERC1155ReceiverUpgradeable, BaseGovernor {
    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }

    using DoubleEndedQueueUpgradeable for DoubleEndedQueueUpgradeable.Bytes32Deque;
    using SafeCastUpgradeable for uint256;
    using TimersUpgradeable for TimersUpgradeable.BlockNumber;

    struct ProposalCore {
        TimersUpgradeable.BlockNumber voteStart;
        TimersUpgradeable.BlockNumber voteEnd;
        bool executed;
        bool canceled;
    }

    string private _name;

    mapping(uint256 => ProposalCore) private _proposals;

    DoubleEndedQueueUpgradeable.Bytes32Deque private _governanceCall;

    modifier onlyGovernance() {
        require(msg.sender == _executor(), "Governor: onlyGovernance");
        if (_executor() != address(this)) {
            bytes32 msgDataHash = keccak256(msg.data);
            // loop until popping the expected operation - throw if deque is empty (operation not authorized)
            while (_governanceCall.popFront() != msgDataHash) {}
        }
        _;
    }

    function __BaseProposalGovernor_init(string memory name_) internal onlyInitializing {
        __BaseGovernor_init_unchained();
        __BaseProposalGovernor_init_unchained(name_);
    }

    function __BaseProposalGovernor_init_unchained(string memory name_) internal onlyInitializing {
        _name = name_;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(IERC165Upgradeable, ERC165Upgradeable, BaseGovernor) returns (bool) {
       return
        interfaceId == type(ProposalGovernorInterface).interfaceId ||
        interfaceId == type(IERC1155ReceiverUpgradeable).interfaceId ||
        BaseGovernor.supportsInterface(interfaceId) ||
        super.supportsInterface(interfaceId);
    }

    function name() public view virtual returns (string memory) {
        return _name;
    }

    function buildProposalId(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public pure virtual override returns (uint256) {
        return uint256(keccak256(abi.encode(targets, values, calldatas, descriptionHash)));
    }

    function proposalState(uint256 proposalId) public view virtual override returns (uint8) {
        ProposalCore storage proposal = _proposals[proposalId];

        if (proposal.executed) {
            return uint8(ProposalState.Executed);
        }

        if (proposal.canceled) {
            return uint8(ProposalState.Canceled);
        }

        uint256 snapshot = proposalVoteStartBlock(proposalId);

        if (snapshot == 0) {
            revert("Governor: unknown proposal id");
        }

        if (snapshot >= block.number) {
            return uint8(ProposalState.Pending);
        }

        uint256 deadline = proposalVoteEndBlock(proposalId);

        if (deadline >= block.number) {
            return uint8(_quorumReached(proposalId) && _voteSucceeded(proposalId)
                ? ProposalState.Succeeded
                : ProposalState.Active);
        }

        if (_quorumReached(proposalId) && _voteSucceeded(proposalId)) {
            return uint8(ProposalState.Succeeded);
        } else {
            return uint8(ProposalState.Defeated);
        }
    }

    function proposalVoteStartBlock(uint256 proposalId) public view virtual override returns (uint256) {
        return _proposals[proposalId].voteStart.getDeadline();
    }

    function proposalVoteEndBlock(uint256 proposalId) public view virtual override returns (uint256) {
        return _proposals[proposalId].voteEnd.getDeadline();
    }

    function proposalThreshold() public view virtual returns (uint256) {
        return 0;
    }

    function _quorumReached(uint256 proposalId) internal view virtual returns (bool);

    function _voteSucceeded(uint256 proposalId) internal view virtual returns (bool);

    function votingPeriod() public view virtual returns (uint256);

    function votingDelay() public view virtual returns (uint256){
        return 0;
    }

    function quorum(uint256 blockNumber) public view virtual returns (uint256);

    function _getVotes(
        address account,
        uint256 blockNumber
    ) internal view virtual returns (uint256);

    function _countVote(
        uint256 proposalId,
        address account,
        uint256 weight
    ) internal virtual;

    function makeProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public virtual override {
        require(
            getVotes(msg.sender, block.number - 1) >= proposalThreshold(),
            "Governor: proposer votes below proposal threshold"
        );

        uint256 proposalId = buildProposalId(targets, values, calldatas, keccak256(bytes(description)));

        require(targets.length == values.length, "Governor: invalid proposal length");
        require(targets.length == calldatas.length, "Governor: invalid proposal length");
        require(targets.length > 0, "Governor: empty proposal");

        ProposalCore storage proposal = _proposals[proposalId];
        require(proposal.voteStart.isUnset(), "Governor: proposal already exists");

        uint64 snapshot = block.number.toUint64() + votingDelay().toUint64();
        uint64 deadline = snapshot + votingPeriod().toUint64();

        proposal.voteStart.setDeadline(snapshot);
        proposal.voteEnd.setDeadline(deadline);

        emit ProposalCreated(
            proposalId,
            msg.sender,
            targets,
            values,
            new string[](targets.length),
            calldatas,
            snapshot,
            deadline,
            description
        );
    }

    function _executeCallInternal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override virtual returns (bytes[] memory) {
        uint256 proposalId = buildProposalId(targets, values, calldatas, descriptionHash);

        ProposalState status = ProposalState(proposalState(proposalId));
        require(
            status == ProposalState.Succeeded || status == ProposalState.Queued,
            "Governor: proposal not successful"
        );
        _proposals[proposalId].executed = true;

        _beforeExecute(proposalId, targets, values, calldatas, descriptionHash);
        bytes[] memory results = super._executeCallInternal(targets, values, calldatas, descriptionHash);
        _afterExecute(proposalId, targets, values, calldatas, descriptionHash);

        emit ProposalExecuted(proposalId, msg.sender);

        return results;
    }

    function _beforeExecute(
        uint256, /* proposalId */
        address[] memory targets,
        uint256[] memory, /* values */
        bytes[] memory calldatas,
        bytes32 /*descriptionHash*/
    ) internal virtual {
        if (_executor() != address(this)) {
            for (uint256 i = 0; i < targets.length; ++i) {
                if (targets[i] == address(this)) {
                    _governanceCall.pushBack(keccak256(calldatas[i]));
                }
            }
        }
    }

    function _afterExecute(
        uint256, /* proposalId */
        address[] memory, /* targets */
        uint256[] memory, /* values */
        bytes[] memory, /* calldatas */
        bytes32 /*descriptionHash*/
    ) internal virtual {
        if (_executor() != address(this)) {
            if (!_governanceCall.empty()) {
                _governanceCall.clear();
            }
        }
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal virtual returns (uint256) {
        uint256 proposalId = buildProposalId(targets, values, calldatas, descriptionHash);
        ProposalState status = ProposalState(proposalState(proposalId));

        require(
            status != ProposalState.Canceled && status != ProposalState.Expired && status != ProposalState.Executed,
            "Governor: proposal not active"
        );
        _proposals[proposalId].canceled = true;

        return proposalId;
    }

    function getVotes(address account, uint256 blockNumber) public view virtual returns (uint256) {
        return _getVotes(account, blockNumber);
    }

    function voteForProposal(uint256 proposalId) public virtual {
        address voter = msg.sender;

        ProposalCore storage proposal = _proposals[proposalId];
        require(proposalState(proposalId) == uint8(ProposalState.Active), "Governor: vote not currently active");

        uint256 weight = _getVotes(voter, proposal.voteStart.getDeadline());
        _countVote(proposalId, voter, weight);

        emit VoteCast(voter, proposalId);
    }

    function _executor() internal view virtual returns (address) {
        return address(this);
    }

    /**
     * @dev See {IERC721Receiver-onERC721Received}.
     */
    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /**
     * @dev See {IERC1155Receiver-onERC1155Received}.
     */
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    /**
     * @dev See {IERC1155Receiver-onERC1155BatchReceived}.
     */
    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    uint256[46] private __gap;
}