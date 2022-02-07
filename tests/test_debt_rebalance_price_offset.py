from _pytest.fixtures import fixture
import brownie
from brownie import Contract, interface, accounts
import pytest

COMPTROLLER = '0x260E596DAbE3AFc463e75B6CC05d8c46aCAcFB09'
cTokenLend = '0x5AA53f03197E08C4851CAD8C92c7922DA5857E5d' # WFTM
cTokenBorrow = '0xE45Ac34E528907d0A0239ab5Db507688070B20bf' # USDC

def set_all_prices(comp, old_oracle, new_oracle):
    cTokens = comp.getAllMarkets()
    for ctoken in cTokens:
        new_oracle.setUnderlyingPrice(ctoken, old_oracle.getUnderlyingPrice(ctoken))


def want_short_price(token, lp_token):
    lp = interface.IUniswapV2Pair(lp_token)
    reserves = lp.getReserves()
    price = 0
    if (token.address == lp.token0()):
        price = reserves[0] / reserves[1]
    else:
        price = reserves[1] / reserves[0]
    return price


@pytest.fixture
def test_strategy(strategist, keeper, vault, TestCoreStrategy, StrategyInsurance, gov):
    strategy = strategist.deploy(TestCoreStrategy, vault)
    insurance = strategist.deploy(StrategyInsurance, strategy)
    strategy.setKeeper(keeper)
    strategy.setInsurance(insurance, {'from': gov})
    vault.addStrategy(strategy, 10_000, 0, 2 ** 256 - 1, 1_000, {"from": gov})
    yield strategy


@pytest.fixture
def deployed_test_vault(chain, accounts, gov, token, vault, test_strategy, user, amount, RELATIVE_APPROX):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount

    chain.sleep(1)
    test_strategy.approveContracts({'from':gov})
    # test_strategy.harvest()
    # assert pytest.approx(test_strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount
    yield vault  


def farmWithdraw(lp_farm, pid, strategy, amount):
    auth = accounts.at(strategy, True)
    if (lp_farm.address == '0x6e2ad6527901c9664f016466b8DA1357a004db0f'):
        lp_farm.withdraw(pid, amount, strategy, {'from': auth}) 
    else:
        lp_farm.withdraw(pid, amount, {'from': auth})


@pytest.fixture
def short(strategy):
    assert Contract(strategy.short())


def test_debt_rebalance(chain, accounts, token, deployed_test_vault, test_strategy, user, conf, gov, lp_token, lp_whale, lp_farm, lp_price, pid, MockPriceOracle):
    strategy = test_strategy

    # Edit the comp price oracle prices
    oracle = MockPriceOracle.deploy({'from': accounts[0]})
    comp = Contract(COMPTROLLER)
    old_oracle = Contract(comp.oracle())

    # Set the mock price oracle
    admin = accounts.at(comp.admin(), True)
    comp._setPriceOracle(oracle, {'from': admin})
    set_all_prices(comp, old_oracle, oracle)

    # Set the new one
    new_price = int(old_oracle.getUnderlyingPrice(cTokenLend) * 0.9)
    oracle.setUnderlyingPrice(cTokenLend, new_price)
    # assert Contract(comp.oracle()).getUnderlyingPrice(cTokenLend) == new_price

    test_strategy.harvest()

    # Change the debt ratio to ~95% and rebalance
    sendAmount = round(strategy.balanceLp() * (1/.95 - 1) / lp_price)
    lp_token.transfer(strategy, sendAmount, {'from': lp_whale})
    print('Send amount: {0}'.format(sendAmount))
    print('debt Ratio:  {0}'.format(strategy.calcDebtRatio()))

    debtRatio = strategy.calcDebtRatio()
    collatRatioBefore = strategy.calcCollateral()
    print('debtRatio:   {0}'.format(debtRatio))
    print('collatRatio: {0}'.format(collatRatioBefore))
    assert pytest.approx(9500, rel=1e-3) == debtRatio
    assert pytest.approx(6000, rel=2e-2) == collatRatioBefore

    # Rebalance Debt  and check it's back to the target
    strategy.rebalanceDebt()
    debtRatio = strategy.calcDebtRatio()
    print('debtRatio:   {0}'.format(debtRatio))
    assert pytest.approx(10000, rel=1e-3) == debtRatio
    assert pytest.approx(6000, rel=1e-2) == strategy.calcCollateral()

    # Change the debt ratio to ~40% and rebalance
    # sendAmount = round(strategy.balanceLpInShort() * (1/.4 - 1))
    sendAmount = round(strategy.balanceLp() * (1/.4 - 1) / lp_price)
    lp_token.transfer(strategy, sendAmount, {'from': lp_whale})
    print('Send amount: {0}'.format(sendAmount))
    print('debt Ratio:  {0}'.format(strategy.calcDebtRatio()))

    debtRatio = strategy.calcDebtRatio()
    collatRatioBefore = strategy.calcCollateral()
    print('debtRatio:   {0}'.format(debtRatio))
    print('collatRatio: {0}'.format(collatRatioBefore))
    assert pytest.approx(4000, rel=1e-3) == debtRatio
    assert pytest.approx(6000, rel=2e-2) == collatRatioBefore

    # Rebalance Debt  and check it's back to the target
    strategy.rebalanceDebt()
    debtRatio = strategy.calcDebtRatio()
    print('debtRatio:   {0}'.format(debtRatio))
    assert pytest.approx(10000, rel=1e-3) == debtRatio 
    assert pytest.approx(6000, rel=1e-2) == strategy.calcCollateral()

    # Change the debt ratio to ~105% and rebalance - steal some lp from the strat
    sendAmount = round(strategy.balanceLp() * 0.05/1.05 / lp_price)
    auth = accounts.at(strategy, True)
    farmWithdraw(lp_farm, pid, strategy, sendAmount)
    lp_token.transfer(user, sendAmount, {'from': auth})

    print('Send amount: {0}'.format(sendAmount))
    print('debt Ratio:  {0}'.format(strategy.calcDebtRatio()))

    debtRatio = strategy.calcDebtRatio()
    collatRatioBefore = strategy.calcCollateral()
    print('debtRatio:   {0}'.format(debtRatio))
    print('collatRatio: {0}'.format(collatRatioBefore))
    assert pytest.approx(10500, rel=2e-3) == debtRatio
    assert pytest.approx(6000, rel=2e-2) == collatRatioBefore

    # Rebalance Debt  and check it's back to the target
    strategy.rebalanceDebt()
    debtRatio = strategy.calcDebtRatio()
    print('debtRatio:   {0}'.format(debtRatio))
    assert pytest.approx(10000, rel=2e-3) == debtRatio
    assert pytest.approx(6000, rel=1e-2) == strategy.calcCollateral()

    # Change the debt ratio to ~150% and rebalance - steal some lp from the strat
    # sendAmount = round(strategy.balanceLpInShort()*(1 - 1/1.50))
    sendAmount = round(strategy.balanceLp() * 0.5/1.50 / lp_price)
    auth = accounts.at(strategy, True)
    farmWithdraw(lp_farm, pid, strategy, sendAmount)
    lp_token.transfer(user, sendAmount, {'from': auth})

    print('Send amount: {0}'.format(sendAmount))
    print('debt Ratio:  {0}'.format(strategy.calcDebtRatio()))

    debtRatio = strategy.calcDebtRatio()
    collatRatioBefore = strategy.calcCollateral()
    print('debtRatio:   {0}'.format(debtRatio))
    print('collatRatio: {0}'.format(collatRatioBefore))
    assert pytest.approx(15000, rel=2e-3) == debtRatio
    assert pytest.approx(6000, rel=2e-2) == collatRatioBefore

    # Rebalance Debt  and check it's back to the target
    strategy.rebalanceDebt()
    debtRatio = strategy.calcDebtRatio()
    print('debtRatio:   {0}'.format(debtRatio))
    assert pytest.approx(10000, rel=2e-3) == debtRatio
    assert pytest.approx(6000, rel=1e-2) == strategy.calcCollateral()


# def test_debt_rebalance_partial(chain, accounts, token, deployed_test_vault, test_strategy, user, strategist, gov, lp_token, lp_whale, lp_farm, lp_price, pid, MockPriceOracle):
#     strategy = test_strategy
#     strategy.setDebtThresholds(9800, 10200, 5000)

#     # Edit the comp price oracle prices
#     oracle = MockPriceOracle.deploy({'from': accounts[0]})
#     comp = Contract(COMPTROLLER)
#     old_oracle = Contract(comp.oracle())

#     # Set the mock price oracle
#     admin = accounts.at(comp.admin(), True)
#     comp._setPriceOracle(oracle, {'from': admin})
#     set_all_prices(comp, old_oracle, oracle)

#     # Set the new one
#     oracle.setUnderlyingPrice(cTokenLend, int(old_oracle.getUnderlyingPrice(cTokenLend) * 0.9))

#     test_strategy.harvest()

#     # Change the debt ratio to ~95% and rebalance
#     sendAmount = round(strategy.balanceLpInShort()*(1/.95 - 1))
#     lp_token.transfer(strategy, sendAmount, {'from': lp_whale})
#     print('Send amount: {0}'.format(sendAmount))
#     print('debt Ratio:  {0}'.format(strategy.calcDebtRatio()))

#     debtRatio = strategy.calcDebtRatio()
#     collatRatioBefore = strategy.calcCollateral()
#     print('debtRatio:   {0}'.format(debtRatio))
#     print('collatRatio: {0}'.format(collatRatioBefore))
#     assert pytest.approx(9500, rel=1e-3) == debtRatio
#     assert pytest.approx(6000, rel=2e-2) == collatRatioBefore

#     # Rebalance Debt  and check it's back to the target
#     strategy.rebalanceDebt()
#     debtRatio = strategy.calcDebtRatio()
#     print('debtRatio:   {0}'.format(debtRatio))
#     assert pytest.approx(9750, rel=1e-3) == debtRatio
#     assert pytest.approx(collatRatioBefore, rel=1e-2) == strategy.calcCollateral()

#     # assert False
#     # rebalance the whole way now
#     strategy.setDebtThresholds(9800, 10200, 10000)
#     strategy.rebalanceDebt()
#     assert pytest.approx(10000, rel=1e-3) == strategy.calcDebtRatio()

#     strategy.setDebtThresholds(9800, 10200, 5000)
#     # Change the debt ratio to ~105% and rebalance - steal some lp from the strat
#     sendAmount = round(strategy.balanceLp() * 0.05/1.05 / lp_price)
#     auth = accounts.at(strategy, True)
#     farmWithdraw(lp_farm, pid, strategy, sendAmount)
#     lp_token.transfer(user, sendAmount, {'from': auth})

#     print('Send amount: {0}'.format(sendAmount))
#     print('debt Ratio:  {0}'.format(strategy.calcDebtRatio()))
#     debtRatio = strategy.calcDebtRatio()
#     collatRatioBefore = strategy.calcCollateral()
#     print('debtRatio:   {0}'.format(debtRatio))
#     print('CollatRatio: {0}'.format(collatRatioBefore))
#     assert pytest.approx(10500, rel=1e-3) == debtRatio
#     assert pytest.approx(6000, rel=2e-2) == collatRatioBefore

#     # Rebalance Debt  and check it's back to the target
#     strategy.rebalanceDebt()
#     collatRatio = strategy.calcCollateral()
#     debtRatio = strategy.calcDebtRatio()
#     print('debtRatio:   {0}'.format(debtRatio))
#     print('CollatRatio: {0}'.format(collatRatio))
#     assert pytest.approx(10250, rel=1e-3) == debtRatio
#     assert pytest.approx(collatRatioBefore, rel=1e-2) == collatRatio
