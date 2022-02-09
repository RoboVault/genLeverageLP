import brownie
from brownie import Contract, interface, accounts
import pytest


def farmWithdraw(lp_farm, pid, strategy, amount):
    auth = accounts.at(strategy, True)
    if (lp_farm.address == '0x6e2ad6527901c9664f016466b8DA1357a004db0f'):
        lp_farm.withdraw(pid, amount, strategy, {'from': auth}) 
    else:
        lp_farm.withdraw(pid, amount, {'from': auth})

@pytest.fixture
def short(strategy):
    assert Contract(strategy.short())

def test_debt_rebalance(chain, accounts, token, deployed_vault, strategy, user, conf, gov, lp_token, lp_whale, lp_farm, lp_price, pid, Contract):
    ###################################################################
    # Test Debt Rebalance
    ###################################################################
    # Change the debt ratio to ~95% and rebalance

    # USE SPIRIT LP 
    shortAWhale = '0xd061c6586670792331E14a80f3b3Bb267189C681'
    shortBWhale = '0xd061c6586670792331E14a80f3b3Bb267189C681'
    spookyRouter = Contract("0xF491e7B69E4244ad4002BC14e878a34207E38c29")

    shortA = Contract(strategy.shortA())
    shortB = Contract(strategy.shortB())
    swapAmt = shortA.balanceOf(lp_token)*0.05

    print("Force Large Swap - to offset debt ratios")

    shortA.approve(spookyRouter, 2**256-1, {"from": shortAWhale})
    spookyRouter.swapExactTokensForTokens(swapAmt, 0, [shortA, shortB], shortAWhale, 2**256-1, {"from": shortAWhale})

    print('debt Ratio A :  {0}'.format(strategy.calcDebtRatioA()))
    print('debt Ratio B :  {0}'.format(strategy.calcDebtRatioB()))

    print("Complete Rebalance")

    # Rebalance Debt  and check it's back to the target
    strategy.rebalanceDebt()
    print('debt Ratio A :  {0}'.format(strategy.calcDebtRatioA()))
    print('debt Ratio B :  {0}'.format(strategy.calcDebtRatioB()))

    assert pytest.approx(10000, rel=1e-2) == strategy.calcDebtRatioA()
    assert pytest.approx(10000, rel=1e-2) == strategy.calcDebtRatioB()


    swapAmt = shortB.balanceOf(lp_token)*0.05

    print("Force Large Swap - to offset debt ratios Other Direction")

    shortB.approve(spookyRouter, 2**256-1, {"from": shortBWhale})
    spookyRouter.swapExactTokensForTokens(swapAmt, 0, [shortB, shortA], shortAWhale, 2**256-1, {"from": shortAWhale})

    print('debt Ratio A :  {0}'.format(strategy.calcDebtRatioA()))
    print('debt Ratio B :  {0}'.format(strategy.calcDebtRatioB()))


    print("Complete Rebalance")

    # Rebalance Debt  and check it's back to the target
    strategy.rebalanceDebt()
    print('debt Ratio A :  {0}'.format(strategy.calcDebtRatioA()))
    print('debt Ratio B :  {0}'.format(strategy.calcDebtRatioB()))

    assert pytest.approx(10000, rel=1e-2) == strategy.calcDebtRatioA()
    assert pytest.approx(10000, rel=1e-2) == strategy.calcDebtRatioB()