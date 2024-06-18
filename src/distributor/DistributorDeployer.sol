// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.7;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IReferralsEngine} from "@unleashed/opendapps-cloud-interfaces/deployer/IReferralsEngine.sol";
import {IContractDeployerInterface} from "@unleashed/opendapps-cloud-interfaces/deployer/IContractDeployerInterface.sol";
import {DistributorDeployerInterface_v1} from "@unleashed/opendapps-cloud-interfaces/distributor/DistributorDeployerInterface_v1.sol";
import {DistributorInterface_v1} from "@unleashed/opendapps-cloud-interfaces/distributor/DistributorInterface_v1.sol";

    error PermittedForOwnerOnly();
    error ProvidedAddressNotCompatibleWithRequiredInterfaces(address target, bytes4 interfaceId);
    error OnlyOwnerPermittedOperation(address sender);

contract DistributorDeployer is DistributorDeployerInterface_v1, Initializable, ERC165, Ownable2StepUpgradeable {
    uint256[150] private __gap;

    event DistributorDeployed(address indexed creator, address contractAddress);

    bytes32 public constant GROUP_DISTRIBUTOR = keccak256("GROUP_DISTRIBUTOR");
    uint256 public constant PERCENT_SCALING = 10 ** 3;

    address public contractDeployer;
    address public swapL2Router;

    address public serviceTaxReceiver;
    uint256 public serviceTax;

    function initialize(
        address _contractDeployer, address _swapL2Router, address _serviceTaxReceiver,
        address _distributorLibrary, uint256 _deployTax, uint256 _serviceTax
    ) public initializer {
        if (!ERC165Checker.supportsInterface(_contractDeployer, type(IContractDeployerInterface).interfaceId)) {
            revert ProvidedAddressNotCompatibleWithRequiredInterfaces(_contractDeployer, type(IContractDeployerInterface).interfaceId);
        }

        super.__Ownable2Step_init();

        contractDeployer = _contractDeployer;
        swapL2Router = _swapL2Router;
        serviceTaxReceiver = _serviceTaxReceiver;

        bytes4[] memory distributorInterfaces = new bytes4[](1);
        distributorInterfaces[0] = type(DistributorInterface_v1).interfaceId;

        IContractDeployerInterface(contractDeployer).registerTemplate(
            GROUP_DISTRIBUTOR, 0,
            distributorInterfaces,
            _distributorLibrary, _deployTax
        );

        serviceTax = _serviceTax;
    }

    function supportsInterface(bytes4 interfaceId) public override view returns (bool) {
        return interfaceId == type(DistributorDeployerInterface_v1).interfaceId
            || ERC165.supportsInterface(interfaceId);
    }

    // METHODS - OWNER
    function setDistributorLibraryAddress(address _libraryAddress) external onlyOwner {
        IContractDeployerInterface(contractDeployer).upgradeTemplate(
            GROUP_DISTRIBUTOR,
            0,
            _libraryAddress
        );
    }

    function refreshDistributorLibraryInterfaces() external onlyOwner {
        bytes4[] memory distributorInterfaces = new bytes4[](1);
        distributorInterfaces[0] = type(DistributorDeployerInterface_v1).interfaceId;

        IContractDeployerInterface(contractDeployer).upgradeTemplateInterfaceList(GROUP_DISTRIBUTOR, 0, distributorInterfaces);
    }

    function setDeployTax(uint256 taxSize) external onlyOwner {
        IContractDeployerInterface(contractDeployer).upgradeDeployTax(
            GROUP_DISTRIBUTOR,
            0,
            taxSize
        );
    }

    function setServiceTaxReceiverAddress(address _address) external onlyOwner {
        serviceTaxReceiver = _address;
    }

    // METHODS - PUBLIC
    function deploy(bytes32 refCode) payable external returns (address) {
        address distributor = IContractDeployerInterface(contractDeployer)
            .deployTemplateWithProxy{value: msg.value}(msg.sender, GROUP_DISTRIBUTOR, 0, bytes(""), refCode);

        (address[] memory receiverList, uint256[] memory receiverPercentList) = _buildServiceTaxationReceivers(refCode);

        Address.functionCall(
            distributor,
            abi.encodeWithSignature(
                "initialize(address,uint256,address[],uint256[])",
                swapL2Router,
                PERCENT_SCALING,
                receiverList,
                receiverPercentList
            )
        );

        Ownable(distributor).transferOwnership(msg.sender);

        emit DistributorDeployed(msg.sender, distributor);

        return distributor;
    }

    function upgrade(address distributor) payable external returns (address) {
        if (Ownable(distributor).owner() != msg.sender) {
            revert PermittedForOwnerOnly();
        }

        IContractDeployerInterface(contractDeployer).upgradeContractWithProxy(
            GROUP_DISTRIBUTOR,
            distributor
        );

        return IContractDeployerInterface(contractDeployer).currentTemplate(GROUP_DISTRIBUTOR, 0);
    }

    function _buildServiceTaxationReceivers(bytes32 refCode) internal view returns (address[] memory, uint256[] memory) {
        address referralEngine = IContractDeployerInterface(contractDeployer).referralsEngine();

        (uint256 percent, address referral) = IReferralsEngine(referralEngine).getCompensationPercent(refCode);

        address[] memory receiverList = new address[](referral != address(0) ? 2 : 1);
        uint256[] memory receiverPercentList = new uint256[](referral != address(0) ? 2 : 1);
        receiverList[0] = serviceTaxReceiver;
        if (referral != address(0)) {
            receiverList[1] = referral;
            receiverPercentList[1] = serviceTax * percent / 100;
            receiverPercentList[0] = serviceTax - receiverPercentList[1];
        } else {
            receiverPercentList[0] = serviceTax;
        }

        return (receiverList, receiverPercentList);
    }
}