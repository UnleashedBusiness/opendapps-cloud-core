pragma solidity ~0.8.7;


import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AddressUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import {SafeMathUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {PaymentSplitterUpgradeable} from "@openzeppelin/contracts-upgradeable/finance/PaymentSplitterUpgradeable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";

import {IPendingRewardProvider} from  "@unleashed/opendapps-cloud-interfaces/rewards/IPendingRewardProvider.sol";

contract PaymentSplitterRewardProviderUpgradeable is Initializable, OwnableUpgradeable,
    IPendingRewardProvider, ERC165Upgradeable, PaymentSplitterUpgradeable {
    struct RewardToken {
        bool enabled;
        bool interactedWith;
        address tokenContract;
        mapping(address => uint256) pendingWithdrawals;
    }

    address[] private interactedRewardTokens;

    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeMathUpgradeable for uint256;
    using AddressUpgradeable for address;

    constructor() {
        _disableInitializers();
    }

    function initialize(address[] memory payees, uint256[] memory shares_) external initializer {
        super.__Ownable_init();
        super.__PaymentSplitter_init_unchained(payees, shares_);
    }

    function getRewardTokens() external view returns(address[] memory) {
        return interactedRewardTokens;
    }

    function getPendingRewards(address rewardToken, address receiver) public virtual view returns(uint256) {
        if (rewardToken == address(0))
            return releasable(receiver);
        return releasable(IERC20Upgradeable(rewardToken), receiver);
    }

    function withdrawTokenRewards(address rewardToken) virtual public {
        require(getPendingRewards(rewardToken, msg.sender) > 0, "No pending rewards for you in selected token!");

        if (rewardToken == address(0))
            return release(payable(msg.sender));
        release(IERC20Upgradeable(rewardToken), msg.sender);
    }

    function withdrawTokenRewardForReceiver(address rewardToken, address receiver) external onlyOwner {
        require(getPendingRewards(rewardToken,receiver) > 0, "No pending rewards for you in selected token!");

        if (rewardToken == address(0))
            return release(payable(receiver));
        release(IERC20Upgradeable(rewardToken), receiver);
    }

    function supportsInterface(bytes4 interfaceId) public override view returns (bool) {
        return
            interfaceId == type(IPendingRewardProvider).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}