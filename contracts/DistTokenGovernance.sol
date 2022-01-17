/**
 * @title: Dissident Token Governance main contract
 * @summary: ERC20 that holds pooled user funds together
 *           Each token represent a share of the underlying pools
 *           and with each token user have the right to redeem a portion of these pools
 * @author: Dissident Finance, dissident.finance
 */
pragma solidity 0.5.16;
import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/SafeERC20.sol";

import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/ERC20Detailed.sol";

import "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/lifecycle/Pausable.sol";

import "@openzeppelin/upgrades/contracts/Initializable.sol";


contract DistTokenGovernance is Initializable, ERC20, ERC20Detailed, ReentrancyGuard, Ownable, Pausable {
  using SafeERC20 for IERC20;
  using SafeMath for uint256;

  // eg. [COMPAddress, CRVAddress, ...]
  address[] public govTokens;
  // eg. [cTokenAddress, iTokenAddress, ...]
  address[] public allAvailableTokens;
  // eg. cTokenAddress => DistCompoundAddress
  mapping(address => address) public protocolWrappers;


  // ERROR MESSAGES:
  // 0 = is 0
  // 1 = already initialized
  // 2 = length is different
  // 3 = Not greater then
  // 4 = lt
  // 5 = too high
  // 6 = not authorized
  // 7 = not equal
  // 8 = error on flash loan execution
  // 9 = Reentrancy

  // onlyOwner
  /**
   * It allows owner to modify allAvailableTokens array in case of emergency
   * ie if a bug on a interest bearing token is discovered and reset protocolWrappers
   * associated with those tokens.
   *
   * @param protocolTokens : array of protocolTokens addresses (eg [cDAI, iDAI, ...])
   * @param wrappers : array of wrapper addresses (eg [DistCompound, DistFulcrum, ...])
   * @param _newGovTokens : array of governance token addresses
   * @param _newGovTokensEqualLen : array of governance token addresses for each
   *  protocolToken (addr0 should be used for protocols with no govToken)
   */
   function setAllAvailableTokensAndWrappers(
       address[] calldata protocolTokens,
       address[] calldata wrappers,
       address[] calldata _newGovTokens,
       address[] calldata _newGovTokensEqualLen
   ) external onlyOwner {
       require(protocolTokens.length == wrappers.length, "2");
       require(_newGovTokensEqualLen.length >= protocolTokens.length, "3");

       govTokens = _newGovTokens;

       address newGov;
       address protToken;
       for (uint256 i = 0; i < protocolTokens.length; i++) {
           protToken = protocolTokens[i];
           require(protToken != address(0) && wrappers[i] != address(0), "0");
           protocolWrappers[protToken] = wrappers[i];

           //set protocol token to gov token mapping
        //    newGov = _newGovTokensEqualLen[i];
        //    if (newGov != DIST) {
        //        protocolTokenToGov[protToken] = newGov;
        //    }
       }

       allAvailableTokens = protocolTokens;
   }




}