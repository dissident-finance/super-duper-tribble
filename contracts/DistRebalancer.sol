/**
 * @title: Dist Rebalancer contract
 * @summary: Used for calculating amounts to lend on each implemented protocol.
 *           This implementation works with Compound and Fulcrum only,
 *           when a new protocol will be added this should be replaced
 * @author: Dissident Labs Inc., dissident.finance
 */
pragma solidity 0.5.16;

import "./interfaces/IDistRebalancerV1.sol";

import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract DistRebalancer is IDistRebalancerV1, Ownable {
    using SafeMath for uint256;
    uint256[] public lastAmounts;
    address[] public lastAmountsAddresses;
    address public rebalancerManager;
    address public distToken;
    uint256 private constant MAX_PERC = 100000;

    /**
    * @param _protocolTokens : array of interest bearing tokens
    * @param _rebalancerManager : rebalancerManager address
    */

    constructor(address[] memory _protocolTokens, address _rebalancerManager) public {
        require(_rebalancerManager != address(0), 'manager addr is 0');
        rebalancerManager = _rebalancerManager;
        lastAmounts = new uint256[](_protocolTokens.length);
        lastAmountsAddresses = new address[](_protocolTokens.length);

        lastAmounts[0] = MAX_PERC;
        lastAmountsAddresses[0] = _protocolTokens[0];
        for(uint256 i = 1; i < _protocolTokens.length; i++) {
            require(_protocolTokens[i] != address(0), 'some addr is 0');
            // Initially 100% on first lending protocol
            lastAmountsAddresses[i] = _protocolTokens[i];
        }
    }

    /**
    * Throws if called by any account other than rebalancerManager.
    */
    modifier onlyRebalancerAndDist() {
        require(msg.sender == rebalancerManager || msg.sender == distToken, "Only rebalacer and Dist");
        _;
    }

    /**
    * It allows owner to set the allowed rebalancer address
    *
    * @param _rebalancerManager : rebalance manager address
    */
    function setRebalancerManager(address _rebalancerManager)
        external onlyOwner {
            require(_rebalancerManager != address(0), "_rebalancerManager addr is 0");

            rebalancerManager = _rebalancerManager;
    }

    function setDistToken(address _distToken)
        external onlyOwner {
            require(distToken == address(0), "distToken addr already set");
            require(_distToken != address(0), "_distToken addr is 0");
            distToken = _distToken;
    }

    /**
    * It adds a new token address to lastAmountsAddresses list
    *
    * @param _newToken : new interest bearing token address
    */
    function setNewToken(address _newToken)
        external onlyOwner {
        require(_newToken != address(0), "New token should be != 0");
        for (uint256 i = 0; i < lastAmountsAddresses.length; i++) {
            if (lastAmountsAddresses[i] == _newToken) {
                return;
            }
        }

        lastAmountsAddresses.push(_newToken);
        lastAmounts.push(0);
    }
    // end onlyOwner

    /**
    * Used by Rebalance manager to set the new allocations
    *
    * @param _allocations : array with allocations in percentages (100% => MAX_PERC)
    * @param _addresses : array with addresses of tokens used, should be equal to lastAmountsAddresses
    */
    function setAllocations(uint256[] calldata _allocations, address[] calldata _addresses)
        external onlyRebalancerAndDist
    {
        require(_allocations.length == lastAmounts.length, "Alloc lengths are different, allocations");
        require(_allocations.length == _addresses.length, "Alloc lengths are different, addresses");

        uint256 total;
        for (uint256 i = 0; i < _allocations.length; i++) {
            require(_addresses[i] == lastAmountsAddresses[i], "Addresses do not match");
            total = total.add(_allocations[i]);
            lastAmounts[i] = _allocations[i];
        }
        require(total == MAX_PERC, "Not allocating 100%");
    }

    function getAllocations()
        external view returns (uint256[] memory _allocations) {
        return lastAmounts;
    }

    function getAllocationsLength()
        external view returns (uint256) {
        return lastAmounts.length;
    }

}