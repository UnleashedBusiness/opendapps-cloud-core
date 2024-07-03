// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.7;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IReferralsEngine} from "@unleashed/opendapps-cloud-interfaces/deployer/IReferralsEngine.sol";
import {IContractDeployerInterface} from "@unleashed/opendapps-cloud-interfaces/deployer/IContractDeployerInterface.sol";
import {ServiceDeployableInterface} from "@unleashed/opendapps-cloud-interfaces/deployer/ServiceDeployableInterface.sol";
import {SecondaryServiceDeployableInterface} from "@unleashed/opendapps-cloud-interfaces/deployer/SecondaryServiceDeployableInterface.sol";
import {VestingDeployerInterface} from "@unleashed/opendapps-cloud-interfaces/vesting/VestingDeployerInterface.sol";
import {VestingInterface} from "@unleashed/opendapps-cloud-interfaces/vesting/VestingInterface.sol";

    error PermittedForOwnerOnly();
    error ProvidedAddressNotCompatibleWithRequiredInterfaces(address target, bytes4 interfaceId);
    error OnlyOwnerPermittedOperation(address sender);

contract VestingDeployer is VestingDeployerInterface, Initializable, ERC165, AccessControlUpgradeable {
    uint256[150] private __gap;

    event VestingDeployed(address indexed creator, address contractAddress);

    bytes32 public constant LOCAL_MANAGER_ROLE = keccak256("LOCAL_MANAGER_ROLE");

    bytes32 public constant GROUP_VESTING = keccak256("GROUP_VESTING");

    address public contractDeployer;
    address public rewardsTreasury;
    uint256 public vestingServiceTax;

    using SafeMath for uint256;
    using Address for address;

    function initialize(address _contractDeployer, address _rewardsTreasury, address vestingLibrary, uint256 _tax, uint256 _vestingServiceTax) public initializer {
        if (!ERC165Checker.supportsInterface(_contractDeployer, type(IContractDeployerInterface).interfaceId)) {
            revert ProvidedAddressNotCompatibleWithRequiredInterfaces(_contractDeployer, type(IContractDeployerInterface).interfaceId);
        }

        super.__Context_init_unchained();
        super.__AccessControl_init_unchained();

        super._grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        contractDeployer = _contractDeployer;
        rewardsTreasury = _rewardsTreasury;

        bytes4[] memory vestingInterfaces = new bytes4[](1);
        vestingInterfaces[0] = type(VestingInterface).interfaceId;

        IContractDeployerInterface(contractDeployer).registerTemplate(
            GROUP_VESTING, 0,
            vestingInterfaces,
            vestingLibrary, _tax
        );

        vestingServiceTax = _vestingServiceTax;
    }

    function supportsInterface(bytes4 interfaceId) public override(AccessControlUpgradeable, ERC165) view returns (bool) {
        return interfaceId == type(VestingDeployerInterface).interfaceId
        || AccessControlUpgradeable.supportsInterface(interfaceId)
            || ERC165.supportsInterface(interfaceId);
    }

    // METHODS - MANAGER
    function setVestingLibraryAddress(address _libraryAddress) external onlyRole(LOCAL_MANAGER_ROLE) {
        IContractDeployerInterface(contractDeployer).upgradeTemplate(
            GROUP_VESTING,
            0,
            _libraryAddress
        );
    }

    function refreshVestingLibraryInterfaces() external onlyRole(LOCAL_MANAGER_ROLE) {
        bytes4[] memory vestingInterfaces = new bytes4[](1);
        vestingInterfaces[0] = type(VestingInterface).interfaceId;

        IContractDeployerInterface(contractDeployer).upgradeTemplateInterfaceList(GROUP_VESTING, 0, vestingInterfaces);
    }

    function setDeployTax(uint256 taxSize) external onlyRole(LOCAL_MANAGER_ROLE) {
        IContractDeployerInterface(contractDeployer).upgradeDeployTax(
            GROUP_VESTING,
            0,
            taxSize
        );
    }

    // METHODS - PUBLIC
    function deploy(bytes32 refCode) payable external returns (address) {
        address vesting = IContractDeployerInterface(contractDeployer)
            .deployTemplateWithProxy{value: msg.value}(msg.sender, GROUP_VESTING, 0, bytes(""), refCode);

        (address[] memory controllerList, uint256[] memory controllerPercentList) = _buildControllerList(refCode);

        Address.functionCall(
            vesting,
            abi.encodeWithSignature(
                "initialize(address[],uint256[])",
                controllerList,
                controllerPercentList
            )
        );

        Ownable(vesting).transferOwnership(msg.sender);

        emit VestingDeployed(msg.sender, vesting);

        return vesting;
    }

    function upgrade(address vesting) payable external returns (address) {
        if (Ownable(vesting).owner() != msg.sender) {
            revert PermittedForOwnerOnly();
        }

        IContractDeployerInterface(contractDeployer).upgradeContractWithProxy(
            GROUP_VESTING,
            vesting
        );

        return IContractDeployerInterface(contractDeployer).currentTemplate(GROUP_VESTING, 0);
    }

    function _buildControllerList(bytes32 refCode) internal view returns (address[] memory, uint256[] memory) {
        address referralEngine = IContractDeployerInterface(contractDeployer).referralsEngine();

        (uint256 percent, address referral) = IReferralsEngine(referralEngine).getCompensationPercent(refCode);

        address[] memory controllerList = new address[](referral != address(0) ? 2 : 1);
        uint256[] memory controllerPercentList = new uint256[](referral != address(0) ? 2 : 1);
        controllerList[0] = rewardsTreasury;
        if (referral != address(0)) {
            controllerList[1] = referral;
            controllerPercentList[1] = percent.mul(vestingServiceTax).div(100);
            controllerPercentList[0] = vestingServiceTax.sub(controllerPercentList[1]);
        } else {
            controllerPercentList[0] = vestingServiceTax;
        }

        return (controllerList, controllerPercentList);
    }
}