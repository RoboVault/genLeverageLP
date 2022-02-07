// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";
import "./interfaces/tarot.sol";
import "./interfaces/uniswap.sol";
import "./interfaces/vaults.sol";
import "./interfaces/ctoken.sol";
import "./interfaces/farm.sol";
import "./interfaces/uniswap.sol";
import "./interfaces/ipriceoracle.sol";


struct StrategyConfig {
    // A portion of want token is depoisited into a lending platform to be used as
    // collateral. Short token is borrowed and compined with the remaining want token
    // and deposited into LP and farmed.
    address want;
    address short;
    /*****************************/
    /*             Farm           */
    /*****************************/
    // Liquidity pool address for base <-> short tokens
    address wantShortLP;
    // Address for short Vault i.e rvBTC
    address shortVault;

    /*****************************/
    /*        Money Market       */
    /*****************************/
    // Base token cToken @ MM
    address cTokenLend;
    // Short token cToken @ MM
    address cTokenBorrow;
    // Lend/Borrow rewards
    address compToken;
    address compTokenLP;
    // address compLpAddress = 0x613BF4E46b4817015c01c6Bb31C7ae9edAadc26e;
    address comptroller;
    /*****************************/
    /*            AMM            */
    /*****************************/
    // Liquidity pool address for base <-> short tokens @ the AMM.
    // @note: the AMM router address does not need to be the same
    // AMM as the farm, in fact the most liquid AMM is prefered to
    // minimise slippage.
    address router;
    uint256 minDeploy;
}

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    uint256 public collatUpper = 6700;
    uint256 public collatTarget = 6000;
    uint256 public collatLower = 5300;

    // protocal limits & upper, target and lower thresholds for ratio of debt to collateral
    uint256 public collatLimit = 7500;

    // ERC20 Tokens;
    IERC20 public short;
    IUniswapV2Pair wantShortLP; // This is public because it helps with unit testing

    IERC20 compToken;

    // Contract Interfaces
    ICTokenErc20 cTokenLend;
    ICTokenErc20 cTokenBorrow;

    IUniswapV2Router01 router;
    IComptroller comptroller;
    IPriceOracle oracle;
    IVault public shortVault;

    uint256 public slippageAdj = 9900; // 99%
    uint256 public slippageAdjHigh = 10100; // 101%

    uint256 constant BASIS_PRECISION = 10000;
    uint256 constant STD_PRECISION = 1e18;
    uint256 farmPid;
    address weth;
    uint256 public minDeploy;


    constructor(address _vault, StrategyConfig memory _config) public BaseStrategy(_vault) {

        // initialise token interfaces
        short = IERC20(_config.short);
        wantShortLP = IUniswapV2Pair(_config.wantShortLP);
        compToken = IERC20(_config.compToken);

        // initialise other interfaces
        cTokenLend = ICTokenErc20(_config.cTokenLend);
        cTokenBorrow = ICTokenErc20(_config.cTokenBorrow);
        //farm = IFarmMasterChef(_config.farmMasterChef);
        router = IUniswapV2Router01(_config.router);
        comptroller = IComptroller(_config.comptroller);
        weth = router.WETH();

        enterMarket();
        // _updateLendAndDebtAllocation();

        maxReportDelay = 7200;
        minReportDelay = 3600;
        profitFactor = 1500;
        debtThreshold = 1_000_000 * 1e18;
        minDeploy = _config.minDeploy;
        shortVault = IVault(_config.shortVault);

    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "SimpleLeverage";
    }

    function enterMarket() internal onlyAuthorized {
        address[] memory cTokens = new address[](1);
        cTokens[0] = address(cTokenLend);
        comptroller.enterMarkets(cTokens);
    }

    // calculate total value of vault assets
    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(balanceDeployed());
    }

    function balanceOfWant() public view returns (uint256) {
        return (want.balanceOf(address(this)));
    }

    // calculate total value of vault assets
    function balanceDeployed() public view returns (uint256) {
        return
            balanceLend().add(balanceShortVaultWantEq()).add(balanceShortWantEq()).sub(
                balanceDebt()
            );
    }

    function balanceLend() public view returns (uint256) {
        return (
            cTokenLend
                .balanceOf(address(this))
                .mul(cTokenLend.exchangeRateStored())
                .div(1e18)
        );
    }

    function balanceShortWantEq() public view returns (uint256) {
        return (convertShortToWantLP(short.balanceOf(address(this))));
    }

    function balanceShortInVault() public view returns (uint256) {
        return(shortVault.balanceOf(address(this)).mul(shortVault.pricePerShare()).div(shortVault.decimals()));
    }

    function balanceShortVaultWantEq() public view returns (uint256) {
        return (convertShortToWantLP(balanceShortInVault()));
    }    

    // value of borrowed tokens in value of want tokens
    function balanceDebt() public view returns (uint256) {
        return convertShortToWantLP(balanceDebtInShort());
    }

    function balanceDebtOracle() public view returns (uint256) {
        return convertShortToWantOracle(balanceDebtInShort());
    }

    // value of borrowed tokens in value of want tokens
    function balanceDebtInShort() public view returns (uint256) {
        return cTokenBorrow.borrowBalanceStored(address(this));
    }

    function balancePendingHarvest() public view virtual returns (uint256) {
        return (balanceShortVaultWantEq().sub(balanceDebt()));
    }

    function convertShortToWantLP(uint256 _amountShort)
        internal
        view
        returns (uint256)
    {
        (uint256 wantInLp, uint256 shortInLp) = getLpReserves();
        return (_amountShort.mul(wantInLp).div(shortInLp));
    }

    function convertShortToWantOracle(uint256 _amountShort)
        internal
        view
        returns (uint256)
    {
        return _amountShort.mul(oracle.getPrice()).div(1e18);
    }

    function convertWantToShortLP(uint256 _amountWant)
        internal
        view
        returns (uint256)
    {
        (uint256 wantInLp, uint256 shortInLp) = getLpReserves();
        return _amountWant.mul(shortInLp).div(wantInLp);
    }


    function getLpReserves()
        public
        view
        returns (uint256 _wantInLp, uint256 _shortInLp)
    {
        (uint112 reserves0, uint112 reserves1, ) = wantShortLP.getReserves();
        if (wantShortLP.token0() == address(want)) {
            _wantInLp = uint256(reserves0);
            _shortInLp = uint256(reserves1);
        } else {
            _wantInLp = uint256(reserves1);
            _shortInLp = uint256(reserves0);
        }
    }


    // calculate debt / collateral - used to trigger rebalancing of debt & collateral
    function calcCollateral() public view returns (uint256) {
        return
            balanceDebtOracle().mul(BASIS_PRECISION).div(
                balanceLend()
            );
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
    }

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        // TODO create an accurate price oracle
        return _amtInWei;
    }

    function getTokenOutPath(address _token_in, address _token_out)
        internal
        view
        returns (address[] memory _path)
    {
        bool is_weth =
            _token_in == address(weth) || _token_out == address(weth);
        _path = new address[](is_weth ? 2 : 3);
        _path[0] = _token_in;
        if (is_weth) {
            _path[1] = _token_out;
        } else {
            _path[1] = address(weth);
            _path[2] = _token_out;
        }
    }

    function approveContracts() external virtual onlyGovernance {
        want.safeApprove(address(cTokenLend), uint256(-1));
        short.safeApprove(address(cTokenBorrow), uint256(-1));
        short.safeApprove(address(shortVault), uint256(-1));
        short.safeApprove(address(router), uint256(-1));
        compToken.safeApprove(address(router), uint256(-1));
    }

    function resetApprovals() external virtual onlyGovernance {
        want.safeApprove(address(cTokenLend), uint256(0));
        short.safeApprove(address(cTokenBorrow), uint256(0));
        short.safeApprove(address(shortVault), uint256(0));
        short.safeApprove(address(router), uint256(0));
        compToken.safeApprove(address(router), uint256(0));
    }

    function setSlippageAdj(uint256 _lower, uint256 _upper)
        external
        onlyAuthorized
    {
        slippageAdj = _lower;
        slippageAdjHigh = _upper;
    }

    function setCollateralThresholds(
        uint256 _lower,
        uint256 _target,
        uint256 _upper,
        uint256 _limit
    ) external onlyAuthorized {
        require(_limit <= BASIS_PRECISION);
        collatLimit = _limit;
        require(collatLimit > _upper);
        require(_upper >= _target);
        require(_target >= _lower);
        collatUpper = _upper;
        collatTarget = _target;
        collatLower = _lower;
        // _updateLendAndDebtAllocation();
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        uint256 totalAssets = estimatedTotalAssets();
        uint256 totalDebt = _getTotalDebt();
        if (totalAssets > totalDebt) {
            _profit = totalAssets.sub(totalDebt);
            (uint256 amountFreed, ) = _withdraw(_debtOutstanding.add(_profit));
            if (_debtOutstanding > amountFreed) {
                _debtPayment = amountFreed;
                _profit = 0;
            } else {
                _debtPayment = _debtOutstanding;
                _profit = amountFreed.sub(_debtOutstanding);
            }
            _loss = 0;
        } else {
            _withdraw(_debtOutstanding);
            _debtPayment = balanceOfWant();
            _loss = totalDebt.sub(totalAssets);
        }

        if (balancePendingHarvest() > 100) {
            _profit += _harvestInternal();
        }

        // Check if we're net loss or net profit
        if (_loss >= _profit) {
            _profit = 0;
            _loss = _loss.sub(_profit);
            //insurance.reportLoss(totalDebt, _loss);
        } else {
            _profit = _profit.sub(_loss);
            _loss = 0;
            /*
            uint256 insurancePayment =
                insurance.reportProfit(totalDebt, _profit);
            _profit = _profit.sub(insurancePayment);
            

            // double check insurance isn't asking for too much or zero
            if (insurancePayment > 0 && insurancePayment < _profit) {
                SafeERC20.safeTransfer(
                    want,
                    address(insurance),
                    insurancePayment
                );
            }
            */
        }
    }


    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _wantAvailable = balanceOfWant();
        if (_debtOutstanding >= _wantAvailable) {
            return;
        }
        uint256 toInvest = _wantAvailable.sub(_debtOutstanding);
        if (toInvest > 0) {
            _deploy(toInvest);
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // NOTE: Maintain invariant `want.balanceOf(this) >= _liquidatedAmount`
        // NOTE: Maintain invariant `_liquidatedAmount + _loss <= _amountNeeded`
        uint256 balanceWant = balanceOfWant();
        uint256 totalAssets = estimatedTotalAssets();

        // if estimatedTotalAssets is less than params.debtRatio it means there's
        // been a loss (ignores pending harvests). This type of loss is calculated
        // proportionally
        // This stops a run-on-the-bank if there's IL between harvests.
        uint256 totalDebt = _getTotalDebt();
        if (totalDebt > totalAssets) {
            uint256 ratio = totalAssets.mul(STD_PRECISION).div(totalDebt);
            uint256 newAmount = _amountNeeded.mul(ratio).div(STD_PRECISION);
            _loss = _amountNeeded.sub(newAmount);
        }

        (, _loss) = _withdraw(_amountNeeded);

        // Since we might free more than needed, let's send back the min
        _liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded).sub(_loss);
    }

    /**
     * function to remove funds from strategy when users withdraws funds in excess of reserves
     *
     * withdraw takes the following steps:
     * 1. Removes _amountNeeded worth of LP from the farms and pool
     * 2. Uses the short removed to repay debt (Swaps short or base for large withdrawals)
     * 3. Redeems the
     * @param _amountNeeded `want` amount to liquidate
     */
    function _withdraw(uint256 _amountNeeded)
        internal
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 balanceWant = balanceOfWant();
        if (_amountNeeded <= balanceWant) {
            return (0, 0);
        }

        uint256 balanceDeployed = balanceDeployed();

        // stratPercent: Percentage of the deployed capital we want to liquidate.
        uint256 stratPercent =
            _amountNeeded.sub(balanceWant).mul(BASIS_PRECISION).div(
                balanceDeployed
            );

        uint256 vaultShares = shortVault.balanceOf(address(this));
        shortVault.withdraw(vaultShares.mul(stratPercent).div(BASIS_PRECISION));
        _repayDebt();
        _redeemWant(_amountNeeded.sub(balanceWant));

    }

    function _getTotalDebt() internal view returns (uint256) {

        return vault.strategies(address(this)).totalDebt;
    }

    function liquidateAllPositions() internal override returns (uint256) {
        uint256 vaultShares = shortVault.balanceOf(address(this));
        shortVault.withdraw(vaultShares);
        _repayDebt();

        uint256 shortBalance = short.balanceOf(address(this));
        if (shortBalance>0){
            router.swapExactTokensForTokens(
                shortBalance,
                0,
                getTokenOutPath(address(short), address(want)),
                address(this),
                now
            );
        }

        return want.balanceOf(address(this));
    }

    // lend want tokens to lending platform
    function _lendWant(uint256 amount) internal {
        cTokenLend.mint(amount);
    }

    function _redeemWant(uint256 _redeem_amount) internal {
        cTokenLend.redeemUnderlying(_redeem_amount);
    }
    // borrow tokens woth _amount of want tokens
    function _borrowWantEq(uint256 _amount)
        internal
        returns (uint256 _borrowamount)
    {
        _borrowamount = convertWantToShortLP(_amount);
        _borrow(_borrowamount);
    }

    // borrow tokens woth _amount of want tokens
    // function _borrowWantEqOracle(uint256 _amount)
    //     internal
    //     returns (uint256 _borrowamount)
    // {
    //     _borrowamount = convertWantToShortOracle(_amount);
    //     _borrow(_borrowamount);
    // }

    function _borrow(uint256 borrowAmount) internal {
        cTokenBorrow.borrow(borrowAmount);
    }

    // automatically repays debt using any short tokens held in wallet up to total debt value
    function _repayDebt() internal {
        uint256 _bal = short.balanceOf(address(this));
        if (_bal == 0) return;

        uint256 _debt = balanceDebtInShort();
        if (_bal < _debt) {
            cTokenBorrow.repayBorrow(_bal);
        } else {
            cTokenBorrow.repayBorrow(_debt);
        }
    }


    function claimShortProfits() internal {
        uint256 shortBefore = short.balanceOf(address(this));
        uint256 shortProfit = balanceShortInVault().sub(balanceDebtInShort());
        uint256 withdrawAmt = shortProfit.mul(shortVault.decimals()).div(shortVault.pricePerShare());
        if (withdrawAmt == 0) return;
        shortVault.withdraw(withdrawAmt);
        shortProfit = short.balanceOf(address(this)).sub(shortBefore);
        router.swapExactTokensForTokens(
            shortProfit,
            0,
            getTokenOutPath(address(short), address(want)),
            address(this),
            now
        );

    }

    /// called by keeper to harvest rewards and either repay debt
    function _harvestInternal() internal returns (uint256 _wantHarvested) {
        uint256 wantBefore = balanceOfWant();
        /// harvest from farm & wantd on amt borrowed vs LP value either -> repay some debt or add to collateral
        claimShortProfits();
        comptroller.claimComp(address(this));
        _sellCompWant();
        _wantHarvested = balanceOfWant().sub(wantBefore);
    }

    function collateralCapReached(uint256 _amount)
        public
        view
        virtual
        returns (bool)
    {
        return
            cTokenLend.totalCollateralTokens().add(_amount) <
            cTokenLend.collateralCap();
    }

    /// rebalances RoboVault strat position to within target collateral range
    function rebalanceCollateral() external onlyKeepers {
        // ratio of amount borrowed to collateral
        uint256 collatRatio = calcCollateral();
        require(collatRatio <= collatLower || collatRatio >= collatUpper);
        _rebalanceCollateralInternal();
    }

    function _rebalanceCollateralInternal() internal {
        uint256 collatRatio = calcCollateral();
        uint256 shortPos = balanceDebt();
        uint256 lendPos = balanceLend();

        if (collatRatio > collatTarget) {
            uint256 percentAbove = collatRatio.sub(collatTarget);
            uint256 vaultShares = shortVault.balanceOf(address(this));
            shortVault.withdraw(vaultShares.mul(percentAbove).div(collatRatio));
            _repayDebt();


        } else if (collatRatio < collatTarget) {
            uint256 percentBelow = collatTarget.sub(collatRatio);
            uint256 borrowAmount = balanceDebtInShort().mul(percentBelow).div(collatRatio);
            _borrow(borrowAmount);
            _depositShort();
        }
    }

    // deploy assets according to vault strategy
    function _deploy(uint256 _amount) internal {
        if (_amount < minDeploy || collateralCapReached(_amount)) {
            return;
        }

        _lendWant(_amount);
        uint256 borrowAmtWant = collatTarget.mul(_amount).div(BASIS_PRECISION);
        uint256 borrowAmt = convertWantToShortLP(borrowAmtWant);
        _borrow(borrowAmt);
        _depositShort();
    }

    function _depositShort() internal {
        shortVault.deposit(short.balanceOf(address(this)));
    }

    function _sellCompWant() internal virtual {
        uint256 compBalance = compToken.balanceOf(address(this));
        if (compBalance == 0) return;
        router.swapExactTokensForTokens(
            compBalance,
            0,
            getTokenOutPath(address(compToken), address(want)),
            address(this),
            now
        );
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        // TODO - Fit this into the contract somehow
        address[] memory protected = new address[](4);
        protected[0] = address(short);
        protected[1] = address(shortVault);
        protected[2] = address(compToken);
        protected[3] = address(cTokenLend);
        return protected;
    }


}