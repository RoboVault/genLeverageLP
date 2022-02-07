// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity ^0.6.12;
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

interface IERC20Extended {
    function decimals() external view returns (uint8);
}

contract TarotStrategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using SafeERC20 for ILendingPoolToken;
    using Address for address;
    using SafeMath for uint256;

    struct PoolAlloc {
        address pool;
        uint256 alloc;
    }

    uint256 private constant BASIS_PRECISION = 10000;

    uint256 public minProfit;
    uint256 public minCredit;

    //Spookyswap as default
    IUniswapV2Router02 router =
        IUniswapV2Router02(0xF491e7B69E4244ad4002BC14e878a34207E38c29);
    address weth = router.WETH();

    //This records the current pools and allocs
    PoolAlloc[] public alloc;

    event Cloned(address indexed clone);

    constructor(address _vault, PoolAlloc[] memory _alloc)
        public
        BaseStrategy(_vault)
    {
        _initializeStrat(_alloc);
    }

    function _initializeStrat(PoolAlloc[] memory _alloc) internal {
        // You can set these parameters on deployment to whatever you want
        maxReportDelay = 6300;
        profitFactor = 1500;
        uint256 _decimals = IERC20Extended(address(want)).decimals();
        debtThreshold = 1_000_000 * 1e18;
        require(
            checkAllocTotal(_alloc),
            "Alloc total shouldnt be more than 10000"
        );
        _setAlloc(_alloc);
        addApprovals();
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        PoolAlloc[] memory _alloc
    ) external {
        //note: initialise can only be called once. in _initialize in BaseStrategy we have: require(address(want) == address(0), "Strategy already initialized");
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_alloc);
    }

    function cloneStrategy(address _vault, PoolAlloc[] memory _alloc)
        external
        returns (address newStrategy)
    {
        newStrategy = this.cloneStrategy(
            _vault,
            msg.sender,
            msg.sender,
            msg.sender,
            _alloc
        );
    }

    function cloneStrategy(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        PoolAlloc[] memory _alloc
    ) external returns (address newStrategy) {
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));

        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            newStrategy := create(0, clone_code, 0x37)
        }

        TarotStrategy(newStrategy).initialize(
            _vault,
            _strategist,
            _rewards,
            _keeper,
            _alloc
        );

        emit Cloned(newStrategy);
    }

    function name() external view override returns (string memory) {
        return "StrategyTarotLender";
    }

    function wantTobToken(address _pool, uint256 _requiredWant)
        internal
        view
        returns (uint256 _amount)
    {
        if (_requiredWant == 0) return _requiredWant;
        // This gives us the price per share of xToken
        uint256 pps = ILendingPool(_pool).exchangeRateLast();
        //Now calculate based on pps
        _amount = _requiredWant.mul(1e18).div(pps);
    }

    function bTokenToWant(address _pool, uint256 _bBal)
        public
        view
        returns (uint256 _amount)
    {
        if (_bBal == 0) return _bBal;
        // This gives us the price per share of xToken
        uint256 pps = ILendingPool(_pool).exchangeRateLast();
        _amount = (_bBal * pps) / 1e18;
    }

    function balanceInPool(address _pool) internal view returns (uint256 bal) {
        bal = bTokenToWant(
            _pool,
            ILendingPoolToken(_pool).balanceOf(address(this))
        );
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    //Returns staked value
    function balanceOfStake() public view returns (uint256 total) {
        for (uint256 i = 0; i < alloc.length; i++) {
            total = total.add(balanceInPool(alloc[i].pool));
        }
    }

    function pendingInterest() public view returns (uint256) {
        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 lendBal = balanceOfStake();
        if (debt < lendBal) {
            //This will add to profit
            return lendBal.sub(debt);
        }
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        //Add the want balance and staked balance
        return balanceOfWant().add(balanceOfStake());
    }

    function tendTrigger(uint256 callCostInWei)
        public
        view
        virtual
        override
        returns (bool)
    {
        return balanceOfWant() > minCredit;
    }

    function harvestTrigger(uint256 callCostInWei)
        public
        view
        virtual
        override
        returns (bool)
    {
        return
            pendingInterest() > minProfit ||
            vault.creditAvailable() > minCredit;
    }

    function checkAllocTotal(PoolAlloc[] memory _alloc)
        internal
        pure
        returns (bool)
    {
        uint256 total = 0;
        for (uint256 i = 0; i < _alloc.length; i++) {
            total += _alloc[i].alloc;
        }
        return total <= BASIS_PRECISION;
    }

    function depositToPool(address _pool, uint256 _amount) internal {
        if (_amount > 0) {
            want.safeTransfer(_pool, _amount);
            require(
                ILendingPoolToken(_pool).mint(address(this)) >= 0,
                "No lend tokens minted"
            );
        }
    }

    function updateExchangeRates() internal {
        //Update all the rates before harvest
        for (uint256 i = 0; i < alloc.length; i++) {
            ILendingPool(alloc[i].pool).exchangeRate();
        }
    }

    function calculatePTAmount(address _pool, uint256 _amount)
        internal
        returns (uint256 pAmount)
    {
        uint256 pBal = ILendingPoolToken(_pool).balanceOf(address(this));
        pAmount = wantTobToken(_pool, _amount);
        if (pAmount > pBal) pAmount = pBal;
    }

    function _withdrawFrom(address _pool) internal {
        uint256 pAmount = ILendingPoolToken(_pool).balanceOf(address(this));
        ILendingPoolToken(_pool).safeTransfer(_pool, pAmount);
        require(
            ILendingPoolToken(_pool).redeem(address(this)) > 0,
            "Not enough returned"
        );
    }

    function withdrawFromPool(address _pool, uint256 _amount) internal {
        uint256 liqAvail = want.balanceOf(_pool);
        _amount = Math.min(_amount, liqAvail);
        uint256 pAmount = calculatePTAmount(_pool, _amount);
        uint256 returnedAmount;
        if (pAmount > 0) {
            //Extra addition on liquidate position to cover edge cases of a few wei defecit
            ILendingPoolToken(_pool).safeTransfer(_pool, pAmount);
            returnedAmount = ILendingPoolToken(_pool).redeem(address(this));
        }
        if (returnedAmount < _amount) {
            //Withdraw all and reinvest remaining
            uint256 toCover = _amount.sub(returnedAmount);
            pAmount = calculatePTAmount(_pool, _amount);
            if (pAmount > 0) {
                ILendingPoolToken(_pool).safeTransfer(_pool, pAmount);
                require(
                    ILendingPoolToken(_pool).redeem(address(this)) >= toCover,
                    "Not enough returned"
                );
            }
        }
    }

    function _deposit(uint256 _depositAmount) internal {
        for (uint256 i = 0; i < alloc.length; i++) {
            depositToPool(
                alloc[i].pool,
                calculateAllocFromBal(_depositAmount, alloc[i].alloc)
            );
        }
    }

    function _withdrawAll() internal {
        for (uint256 i = 0; i < alloc.length; i++) {
            _withdrawFrom(alloc[i].pool);
        }
    }

    function _withdraw(uint256 _withdrawAmount) internal {
        //Update before trying to withdraw
        updateExchangeRates();
        for (uint256 i = 0; i < alloc.length; i++) {
            withdrawFromPool(
                alloc[i].pool,
                calculateAllocFromBal(_withdrawAmount, alloc[i].alloc)
            );
        }
    }

    function revokeApprovals() internal {
        for (uint256 i = 0; i < alloc.length; i++) {
            want.approve(alloc[i].pool, 0);
        }
    }

    function addApprovals() internal {
        for (uint256 i = 0; i < alloc.length; i++) {
            if (want.allowance(address(this), alloc[i].pool) == 0)
                want.approve(alloc[i].pool, type(uint256).max);
        }
    }

    function updateMinProfit(uint256 _minProfit) external onlyStrategist {
        minProfit = _minProfit;
    }

    function updateMinCredit(uint256 _minCredit) external onlyStrategist {
        minCredit = _minCredit;
    }

    function changeAllocs(PoolAlloc[] memory _newAlloc)
        external
        onlyGovernance
    {
        // Withdraw from all positions currently allocated
        if (balanceOfStake() > 0) {
            _withdrawAll();
            revokeApprovals();
        }
        require(
            checkAllocTotal(_newAlloc),
            "Alloc total shouldnt be more than 10000"
        );

        _setAlloc(_newAlloc);
        addApprovals();
        _deposit(balanceOfWant());
    }

    function _setAlloc(PoolAlloc[] memory _newAlloc) internal {
        //Delete old entries
        delete alloc;
        for (uint256 i = 0; i < _newAlloc.length; i++) {
            alloc.push(
                PoolAlloc({pool: _newAlloc[i].pool, alloc: _newAlloc[i].alloc})
            );
        }
    }

    function calculateAllocFromBal(uint256 _bal, uint256 _allocPoints)
        internal
        pure
        returns (uint256)
    {
        return _bal.mul(_allocPoints).div(BASIS_PRECISION);
    }

    function returnDebtOutstanding(uint256 _debtOutstanding)
        internal
        returns (uint256 _debtPayment, uint256 _loss)
    {
        // We might need to return want to the vault
        if (_debtOutstanding > 0) {
            uint256 _amountFreed = 0;
            (_amountFreed, _loss) = liquidatePosition(_debtOutstanding);
            _debtPayment = Math.min(_amountFreed, _debtOutstanding);
        }
    }

    function handleProfit() internal returns (uint256 _profit) {
        uint256 balanceOfWantBefore = balanceOfWant();
        updateExchangeRates();
        _profit = balanceOfWant().sub(balanceOfWantBefore);
        _profit += pendingInterest();
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
        (_debtPayment, _loss) = returnDebtOutstanding(_debtOutstanding);
        _profit = handleProfit();
        uint256 balanceAfter = balanceOfWant();
        uint256 requiredWantBal = _profit + _debtPayment;
        if (balanceAfter < requiredWantBal) {
            //Withdraw enough to satisfy profit check
            _withdraw(requiredWantBal.sub(balanceAfter));
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _wantAvailable = balanceOfWant();

        if (_debtOutstanding >= _wantAvailable) {
            return;
        }

        uint256 toInvest = _wantAvailable.sub(_debtOutstanding);

        if (toInvest > 0) {
            _deposit(toInvest);
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
        uint256 balanceStaked = balanceOfStake();
        if (_amountNeeded > balanceWant) {
            uint256 amountToWithdraw =
                (Math.min(balanceStaked, _amountNeeded - balanceWant));
            _withdraw(amountToWithdraw);
        }
        // Since we might free more than needed, let's send back the min
        _liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded);
        _loss = _amountNeeded > _liquidatedAmount
            ? _amountNeeded.sub(_liquidatedAmount)
            : 0;
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

    function quote(
        address _in,
        address _out,
        uint256 _amtIn
    ) internal view returns (uint256) {
        address[] memory path = getTokenOutPath(_in, _out);
        return router.getAmountsOut(_amtIn, path)[path.length - 1];
    }

    function prepareMigration(address _newStrategy) internal override {
        _withdrawAll();
    }

    function liquidateAllPositions()
        internal
        virtual
        override
        returns (uint256 _amountFreed)
    {
        _withdrawAll();
        _amountFreed = balanceOfWant();
    }

    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return
            address(want) == address(weth)
                ? _amtInWei
                : quote(weth, address(want), _amtInWei);
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}
}
