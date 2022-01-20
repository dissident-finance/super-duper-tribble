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

import "./interfaces/ILendingProtocol.sol";
import "./interfaces/DistController.sol";
import "./interfaces/IAaveIncentivesController.sol";
import "./interfaces/AToken.sol";
import "./interfaces/Comptroller.sol";
import "./interfaces/CERC20.sol";


contract DistTokenGovernance is Initializable, ERC20, ERC20Detailed, ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // State variables
    uint256 private constant ONE_18 = 10**18;
    // eg. DAI address
    address public token;
    // eg. iDAI address
    address private iToken;
    // eg. cDAI address
    address private cToken;
    // Dist rebalancer current implementation address
    address public rebalancer;
    // Address collecting underlying fees
    address public feeAddress;
    // Max unlent assets percentage for gas friendly swaps
    uint256 public maxUnlentPerc; // 100000 == 100% -> 1000 == 1%
    // Current fee on interest gained
    uint256 public fee;
    // eg. 18 for DAI
    uint256 private tokenDecimals;
    // eg. [COMPAddress, CRVAddress, ...]
    address[] public govTokens;
    // eg. [cTokenAddress, iTokenAddress, ...]
    address[] public allAvailableTokens;
    // eg. cTokenAddress => DistCompoundAddress
    mapping(address => address) public protocolWrappers;
    // Map that saves avg distToken price paid for each user, used to calculate earnings
    mapping(address => uint256) public userAvgPrices;
    // global indices for each gov tokens used as a reference to calculate a fair share for each user
    mapping (address => uint256) public govTokensIndexes;
    // array with last balance recorded for each gov tokens
    mapping (address => uint256) public govTokensLastBalances;
    // govToken -> user_address -> user_index eg. usersGovTokensIndexes[govTokens[0]][msg.sender] = 1111123;
    mapping (address => mapping (address => uint256)) public usersGovTokensIndexes;

    // DistToken helper address
    address public tokenHelper;

    // Addresses for stkAAVE distribution from Aave
    address public constant stkAAVE = address(0x4da27a545c0c5B758a6BA100e3a049001de870f5);
    address private aToken;

    // ########## DistToken updates
    // Dist governance token
    address public constant DIST = address(0x875773784Af8135eA0ef43b5a374AaD105c5D39e);
    // Compound governance token
    address public constant COMP = address(0xc00e94Cb662C3520282E6f5717214004A7f26888);
    uint256 private constant FULL_ALLOC = 100000;

    // Dist distribution controller
    address public constant distController = address(0x275DA8e61ea8E02d51EDd8d0DC5c0E62b4CDB0BE);
    // oracle used for calculating the avgAPR with gov tokens
    address public oracle;
    // eg cDAI -> COMP
    mapping(address => address) private protocolTokenToGov;
    // last allocations submitted by rebalancer
    uint256[] private lastRebalancerAllocations;
    // variable used for avoid the call of mint and redeem in the same tx
    bytes32 private _minterBlock;

    // Events
    event Rebalance(address _rebalancer, uint256 _amount);
    event Referral(uint256 _amount, address _ref);

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

    /**
    * It allows owner to set the cToken address
    *
    * @param _cToken : new cToken address
    */
    function setCToken(address _cToken)
        external onlyOwner {
        require((cToken = _cToken) != address(0), "0");
    }

    /**
    * It allows owner to set the aToken address
    *
    * @param _aToken : new aToken address
    */
    function setAToken(address _aToken)
        external onlyOwner {
        require((aToken = _aToken) != address(0), "0");
    }

    /**
    * It allows owner to set the tokenHelper address
    *
    * @param _tokenHelper : new tokenHelper address
    */
    function setTokenHelper(address _tokenHelper)
        external onlyOwner {
        require((tokenHelper = _tokenHelper) != address(0), "0");
    }

    /**
    * It allows owner to set the DistRebalancerV3_1 address
    *
    * @param _rebalancer : new DistRebalancerV3_1 address
    */
    function setRebalancer(address _rebalancer)
        external onlyOwner {
        require((rebalancer = _rebalancer) != address(0), "0");
    }

    /**
    * It allows owner to set the fee (1000 == 10% of gained interest)
    *
    * @param _fee : fee amount where 100000 is 100%, max settable is 10%
    */
    function setFee(uint256 _fee)
        external onlyOwner {
        // 100000 == 100% -> 10000 == 10%
        require((fee = _fee) <= FULL_ALLOC / 10, "5");
    }

    /**
    * It allows owner to set the fee address
    *
    * @param _feeAddress : fee address
    */
    function setFeeAddress(address _feeAddress)
        external onlyOwner {
        require((feeAddress = _feeAddress) != address(0), "0");
    }

    /**
    * It allows owner to set the oracle address for getting avgAPR
    *
    * @param _oracle : new oracle address
    */
    function setOracleAddress(address _oracle)
        external onlyOwner {
        require((oracle = _oracle) != address(0), "0");
    }

    /**
    * It allows owner to set the max unlent asset percentage (1000 == 1% of unlent asset max)
    *
    * @param _perc : max unlent perc where 100000 is 100%
    */
    function setMaxUnlentPerc(uint256 _perc)
        external onlyOwner {
        require((maxUnlentPerc = _perc) <= 100000, "5");
    }

    /**
    * Used by Rebalancer to set the new allocations
    *
    * @param _allocations : array with allocations in percentages (100% => 100000)
    */
    function setAllocations(uint256[] calldata _allocations) external {
        require(msg.sender == rebalancer || msg.sender == owner(), "6");
        _setAllocations(_allocations);
    }

    /**
    * Used by Rebalancer or in openRebalance to set the new allocations
    *
    * @param _allocations : array with allocations in percentages (100% => 100000)
    */
    function _setAllocations(uint256[] memory _allocations) internal {
        require(_allocations.length == allAvailableTokens.length, "2");
        uint256 total;
        for (uint256 i = 0; i < _allocations.length; i++) {
            total = total.add(_allocations[i]);
        }
        lastRebalancerAllocations = _allocations;
        require(total == FULL_ALLOC, "7");
    }

    // view
    /**
    * Get latest allocations submitted by rebalancer
    *
    * @return : array of allocations ordered as allAvailableTokens
    */
    function getAllocations() external view returns (uint256[] memory) {
        return lastRebalancerAllocations;
    }

    /**
    * Get currently used gov tokens
    *
    * @return : array of govTokens supported
    */
    function getGovTokens() external view returns (address[] memory) {
        return govTokens;
    }

    /**
    * Get currently used protocol tokens (cDAI, aDAI, ...)
    *
    * @return : array of protocol tokens supported
    */
    function getAllAvailableTokens() external view returns (address[] memory) {
        return allAvailableTokens;
    }

    /**
    * Get gov token associated to a protocol token eg protocolTokenToGov[cDAI] = COMP
    *
    * @return : address of the gov token
    */
    function getProtocolTokenToGov(address _protocolToken) external view returns (address) {
        return protocolTokenToGov[_protocolToken];
    }

    /**
    * DistToken price for a user considering fees, in underlying
    * this is useful when you need to redeem exactly X underlying
    *
    * @return : price in underlying token counting fees for a specific user
    */
    function tokenPriceWithFee(address user)
        external view
        returns (uint256 priceWFee) {
            uint256 userAvgPrice = userAvgPrices[user];
            priceWFee = _tokenPrice();
            if (userAvgPrice != 0 && priceWFee > userAvgPrice) {
                priceWFee = priceWFee.mul(FULL_ALLOC).sub(fee.mul(priceWFee.sub(userAvgPrice))).div(FULL_ALLOC);
            }
    }

    /**
    * DistToken price calculation, in underlying
    *
    * @return : price in underlying token
    */
    function tokenPrice()
        external view
        returns (uint256) {
        return _tokenPrice();
    }


    function _tokenPrice() internal view returns (uint256 price) {
        uint256 totSupply = totalSupply();
        if (totSupply == 0) {
            return 10**(tokenDecimals);
        }

        address currToken;
        uint256 totNav = _contractBalanceOf(token).mul(ONE_18); // eventual underlying unlent balance
        address[] memory _allAvailableTokens = allAvailableTokens;
        for (uint256 i = 0; i < _allAvailableTokens.length; i++) {
            currToken = _allAvailableTokens[i];
            totNav = totNav.add(
                // NAV = price * poolSupply
                _getPriceInToken(protocolWrappers[currToken]).mul(
                    _contractBalanceOf(currToken)
                )
            );
        }

        price = totNav.div(totSupply); // distToken price in token wei
    }

    function _contractBalanceOf(address _token) private view returns (uint256) {
        // Original implementation:
        //
        // return IERC20(_token).balanceOf(address(this));

        // Optimized implementation inspired by uniswap https://github.com/Uniswap/uniswap-v3-core/blob/main/contracts/UniswapV3Pool.sol#L144
        //
        // 0x70a08231 -> selector for 'function balanceOf(address) returns (uint256)'
        (bool success, bytes memory data) =
            _token.staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        require(success);
        return abi.decode(data, (uint256));
    }

    /**
    * Get price of 1 protocol token in underlyings
    *
    * @param _token : address of the protocol token
    * @return price : price of protocol token
    */
    function _getPriceInToken(address _token) private view returns (uint256) {
        return ILendingProtocol(_token).getPriceInToken();
    }


    // external
    /**
    * Used to mint DistTokens, given an underlying amount (eg. DAI).
    * This method triggers a rebalance of the pools if _skipRebalance is set to false
    * NOTE: User should 'approve' _amount of tokens before calling mintDistToken
    * NOTE 2: this method can be paused
    *
    * @param _amount : amount of underlying token to be lended
    * @param : not used anymore
    * @param _referral : referral address
    * @return mintedTokens : amount of DistTokens minted
    */
    function mintDistToken(uint256 _amount, bool, address _referral)
        external nonReentrant whenNotPaused
        returns (uint256 mintedTokens) {
        _minterBlock = keccak256(abi.encodePacked(tx.origin, block.number));
        _redeemGovTokens(msg.sender);
        // Get current DistToken price
        uint256 distPrice = _tokenPrice();
        // transfer tokens to this contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), _amount);

        mintedTokens = _amount.mul(ONE_18).div(distPrice);
        _mint(msg.sender, mintedTokens);

        // Update avg price and user idx for each gov tokens
        _updateUserInfo(msg.sender, mintedTokens);
        _updateUserFeeInfo(msg.sender, mintedTokens, distPrice);

        if (_referral != address(0)) {
        emit Referral(_amount, _referral);
        }
    }

    /**
    * Redeem unclaimed governance tokens and update governance global index and user index if needed
    * if called during redeem it will send all gov tokens accrued by a user to the user
    *
    * @param _to : user address
    */
    function _redeemGovTokens(address _to) internal {
        _redeemGovTokensInternal(_to, new bool[](govTokens.length));
    }


    /**
    * Redeem unclaimed governance tokens and update governance global index and user index if needed
    * if called during redeem it will send all gov tokens accrued by a user to the user
    *
    * @param _to : user address
    * @param _skipGovTokenRedeem : array of flag for redeeming or not gov tokens
    */
    function _redeemGovTokensInternal(address _to, bool[] memory _skipGovTokenRedeem) internal {
        address[] memory _govTokens = govTokens;
        if (_govTokens.length == 0) {
        return;
        }
        uint256 supply = totalSupply();
        uint256 usrBal = balanceOf(_to);
        address govToken;

        if (supply > 0) {
        for (uint256 i = 0; i < _govTokens.length; i++) {
            govToken = _govTokens[i];

            _redeemGovTokensFromProtocol(govToken);

            // get current gov token balance
            uint256 govBal = _contractBalanceOf(govToken);
            if (govBal > 0) {
            // update global index with ratio of govTokens per distToken
            govTokensIndexes[govToken] = govTokensIndexes[govToken].add(
                // check how much gov tokens for each distToken we gained since last update
                govBal.sub(govTokensLastBalances[govToken]).mul(ONE_18).div(supply)
            );
            // update global var with current govToken balance
            govTokensLastBalances[govToken] = govBal;
            }

            if (usrBal > 0) {
            uint256 usrIndex = usersGovTokensIndexes[govToken][_to];
            // check if user has accrued something
            uint256 delta = govTokensIndexes[govToken].sub(usrIndex);
            if (delta != 0) {
                uint256 share = usrBal.mul(delta).div(ONE_18);
                uint256 bal = _contractBalanceOf(govToken);
                // To avoid rounding issue
                if (share > bal) {
                share = bal;
                }
                if (_skipGovTokenRedeem[i]) { // -> gift govTokens[i] accrued to the pool
                // update global index with ratio of govTokens per distToken
                govTokensIndexes[govToken] = govTokensIndexes[govToken].add(
                    // check how much gov tokens for each distToken we gained since last update
                    share.mul(ONE_18).div(supply.sub(usrBal))
                );
                } else {
                uint256 feeDue;
                // no fee for DIST governance token
                if (feeAddress != address(0) && fee > 0 && govToken != DIST) {
                    feeDue = share.mul(fee).div(FULL_ALLOC);
                    // Transfer gov token fee to feeAddress
                    _transferTokens(govToken, feeAddress, feeDue);
                }
                // Transfer gov token to user
                _transferTokens(govToken, _to, share.sub(feeDue));
                // Update last balance
                govTokensLastBalances[govToken] = _contractBalanceOf(govToken);
                }
            }
            }
            // save current index for this gov token
            usersGovTokensIndexes[govToken][_to] = govTokensIndexes[govToken];
        }
        }
    }

    /**
    * Helper method for mintDistToken, updates minter gov indexes and avg price
    *
    * @param _to : minter account
    * @param _mintedTokens : number of newly minted tokens
    */
    function _updateUserInfo(address _to, uint256 _mintedTokens) internal {
        address govToken;
        uint256 usrBal = balanceOf(_to);
        uint256 _usrIdx;

        for (uint256 i = 0; i < govTokens.length; i++) {
        govToken = govTokens[i];
        _usrIdx = usersGovTokensIndexes[govToken][_to];

        // calculate user idx
        usersGovTokensIndexes[govToken][_to] = _usrIdx.add(
            _mintedTokens.mul(govTokensIndexes[govToken].sub(_usrIdx)).div(usrBal)
        );
        }
    }

    /**
    * Update receiver userAvgPrice paid for each dist token,
    * receiver will pay fees accrued
    *
    * @param usr : user that should have balance update
    * @param qty : new amount deposited / transferred, in distToken
    * @param price : sender userAvgPrice
    */
    function _updateUserFeeInfo(address usr, uint256 qty, uint256 price) private {
        uint256 usrBal = balanceOf(usr);
        // ((avgPrice * oldBalance) + (senderAvgPrice * newQty)) / totBalance
        userAvgPrices[usr] = userAvgPrices[usr].mul(usrBal.sub(qty)).add(price.mul(qty)).div(usrBal);
    }

    /**
    * Redeem a specific gov token
    *
    * @param _govToken : address of the gov token to redeem
    */
    function _redeemGovTokensFromProtocol(address _govToken) internal {
        // In case new Gov tokens will be supported this should be updated
        if (_govToken == COMP || _govToken == DIST || _govToken == stkAAVE) {
        address[] memory holders = new address[](1);
        holders[0] = address(this);

        if (_govToken == DIST) {
            // For DIST, the distribution is done only to DistTokens, so `holders` and
            // `tokens` parameters are the same and equal to address(this)
            DistController(distController).claimDist(holders, holders);
            return;
        }

        address[] memory tokens = new address[](1);
        if (_govToken == stkAAVE && aToken != address(0)) {
            tokens[0] = aToken;
            IAaveIncentivesController _ctrl = IAaveIncentivesController(AToken(tokens[0]).getIncentivesController());
            _ctrl.claimRewards(tokens, _ctrl.getUserUnclaimedRewards(address(this)), address(this));
            return;
        }
        if (cToken != address(0)) {
            tokens[0] = cToken;
            Comptroller(CERC20(tokens[0]).comptroller()).claimComp(holders, tokens, false, true);
        }
        }
    }

    function _transferTokens(address _token, address _to, uint256 _amount) internal {
        IERC20(_token).safeTransfer(_to, _amount);
    }

}